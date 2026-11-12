#!/usr/bin/env python3
"""Opt-in private staging adapter; default is a credential-free local dry-run.

No catalogue cutover, public delivery, deletion, remote byte verification or
existing-object reconciliation is implemented. An uncertain outcome stops.
"""

import argparse
from contextlib import contextmanager
from dataclasses import dataclass, field
from datetime import datetime, timezone
import fcntl
import hashlib
import hmac
import http.client
import json
import os
from pathlib import Path
import re
import secrets
import ssl
import socket
import tempfile
import threading
import time

import prepare


API_HOST = 'api.cloudinary.com'
CHUNK_BYTES = 64 * 1024
RESPONSE_LIMIT = 256 * 1024
CONNECT_TIMEOUT = 10
IO_TIMEOUT = 30
REQUEST_DEADLINE = 120


class UploadSafetyError(ValueError):
    pass


class ReconciliationRequired(UploadSafetyError):
    pass


@dataclass(repr=False)
class Credentials:
    cloud_name: str = field(repr=False)
    api_key: str = field(repr=False)
    api_secret: str = field(repr=False)


def load_private_credentials():
    """Called only after explicit execute, local verification and qualification."""
    return Credentials(os.environ.get('CLOUDINARY_CLOUD_NAME', ''),
                       os.environ.get('CLOUDINARY_API_KEY', ''),
                       os.environ.get('CLOUDINARY_API_SECRET', ''))


def signature(parameters, secret, algorithm='sha256'):
    # Official SDK signature-v2 escaping. Current bounded fields contain no
    # ampersands, but retain the separator-smuggling guard explicitly.
    text = '&'.join((key + '=' + str(parameters[key])).replace('&', '%26')
                    for key in sorted(parameters))
    return hashlib.new(algorithm, (text + secret).encode('utf-8')).hexdigest()


def qualify(qualification, uploads, manifest_sha, limit):
    if not isinstance(qualification, dict) or qualification.get('schema_version') != 1:
        raise UploadSafetyError('account_qualification_required')
    if qualification.get('approved_manifest_sha256') != manifest_sha:
        raise UploadSafetyError('qualification_does_not_match_manifest')
    cloud = qualification.get('cloud_name')
    if not isinstance(cloud, str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,80}', cloud):
        raise UploadSafetyError('qualified_cloud_required')
    if qualification.get('api_host') != API_HOST:
        raise UploadSafetyError('unsupported_api_region_or_host')
    if qualification.get('private_authenticated_upload_confirmed') is not True:
        raise UploadSafetyError('authenticated_upload_not_qualified')
    if qualification.get('staging_upload_authorized') is not True:
        raise UploadSafetyError('staging_upload_not_authorized')
    stage = qualification.get('stage')
    if stage not in {'canary_only', 'full_private_staging'} or (stage == 'canary_only' and limit != 1):
        raise UploadSafetyError('canary_requires_exactly_one_asset')
    if qualification.get('delivery_strategy') not in {'expiring_api_download_canary', 'eligible_timed_CDN_token'}:
        raise UploadSafetyError('paid_delivery_strategy_not_qualified')
    if qualification.get('delivery_strategy') == 'eligible_timed_CDN_token' and qualification.get('timed_token_feature_confirmed') is not True:
        raise UploadSafetyError('timed_token_feature_not_confirmed')
    if stage == 'full_private_staging' and qualification.get('canary_response_and_original_hash_verified') is not True:
        raise UploadSafetyError('complete_canary_qualification_first')
    limits = qualification.get('max_file_bytes')
    if not isinstance(limits, dict):
        raise UploadSafetyError('account_limits_required')
    for item in uploads:
        maximum = limits.get(item['resource_type'])
        if type(maximum) is not int or maximum < item['bytes']:
            raise UploadSafetyError('asset_exceeds_qualified_account_limit')
        if item['bytes'] > 100_000_000:
            raise UploadSafetyError('chunked_upload_not_supported_by_this_adapter')
    return cloud


def checked_credentials(credentials, cloud):
    if (not isinstance(credentials, Credentials) or credentials.cloud_name != cloud or
            not re.fullmatch(r'[0-9]{8,32}', credentials.api_key) or
            not 8 <= len(credentials.api_secret) <= 256 or
            any(ord(c) < 33 or ord(c) > 126 for c in credentials.api_secret)):
        raise UploadSafetyError('private_credentials_missing_or_mismatched')


def receipt_path(directory, item):
    key = hashlib.sha256((item['resource_type'] + ':' + item['public_id']).encode()).hexdigest()
    return directory / (key + '.json')


def validate_receipt_directory(root, directory):
    path = directory if directory.is_absolute() else root / directory
    if '..' in path.parts:
        raise UploadSafetyError('unsafe_receipt_directory')
    # Restrict new artifacts to output, never app assets/source/media roots.
    prepare.contained_source(root, path)
    path.resolve().relative_to((root / 'output').resolve())
    return path


def write_receipt(path, record):
    encoded = (json.dumps(record, indent=2) + '\n').encode()
    descriptor, temporary = tempfile.mkstemp(prefix='.receipt-', dir=path.parent)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, 'wb') as handle:
            handle.write(encoded)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        directory_fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


@contextmanager
def receipt_lock(directory):
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    lock = directory / '.staging-upload.lock'
    if lock.is_symlink():
        raise UploadSafetyError('unsafe_receipt_lock')
    descriptor = os.open(lock, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise UploadSafetyError('another_staging_process_holds_lock') from None
        yield
    finally:
        os.close(descriptor)


class CloudinaryTransport:
    """Fixed TLS origin; no HTTP redirects, implicit requests or POST retries."""

    def __init__(self, connect_retries=0, connection_factory=None):
        if connect_retries not in {0, 1}:
            raise UploadSafetyError('at_most_one_explicit_presend_connect_retry')
        self.connect_retries = connect_retries
        self.factory = connection_factory or (lambda: http.client.HTTPSConnection(
            API_HOST, timeout=CONNECT_TIMEOUT, context=ssl.create_default_context()))

    def post(self, item, source, credentials, parameters):
        expected = {'timestamp': parameters.get('timestamp'), 'public_id': item['public_id'],
                    'type': 'authenticated', 'overwrite': 'false',
                    'use_filename': 'false', 'unique_filename': 'false'}
        if parameters != expected or type(expected['timestamp']) is not int:
            raise UploadSafetyError('unsafe_signed_upload_parameters')
        connection = None
        abort_timer = None
        for attempt in range(self.connect_retries + 1):
            connection = self.factory()
            try:
                connection.connect()
                break
            except OSError:
                connection.close()
                if attempt == self.connect_retries:
                    raise UploadSafetyError('presend_connection_failed') from None
        try:
            if connection.sock:
                connection.sock.settimeout(IO_TIMEOUT)
            def abort_request():
                try:
                    if connection.sock:
                        connection.sock.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                connection.close()
            abort_timer = threading.Timer(REQUEST_DEADLINE, abort_request)
            abort_timer.daemon = True
            abort_timer.start()
            boundary = 'kk-' + secrets.token_hex(16)
            fields = dict(parameters)
            fields['api_key'] = credentials.api_key
            fields['signature'] = signature(parameters, credentials.api_secret)
            parts = []
            for key, value in sorted(fields.items()):
                parts.append(('--' + boundary + '\r\nContent-Disposition: form-data; name="' + key + '"\r\n\r\n' + str(value) + '\r\n').encode())
            suffix = source.suffix.lower()
            if not re.fullmatch(r'\.[a-z0-9]{1,8}', suffix):
                raise UploadSafetyError('unsupported_file_suffix')
            parts.append(('--' + boundary + '\r\nContent-Disposition: form-data; name="file"; filename="asset' + suffix + '"\r\nContent-Type: application/octet-stream\r\n\r\n').encode())
            prefix = b''.join(parts)
            ending = ('\r\n--' + boundary + '--\r\n').encode()
            with source.open('rb') as handle:
                before = os.fstat(handle.fileno())
                check = hashlib.sha256()
                for chunk in iter(lambda: handle.read(CHUNK_BYTES), b''):
                    check.update(chunk)
                if before.st_size != item['bytes'] or check.hexdigest() != item['sha256']:
                    raise UploadSafetyError('source_changed_before_post')
                handle.seek(0)
                # Match the official Python SDK: upload action with the
                # authenticated delivery type included in the signed form.
                connection.putrequest('POST', '/v1_1/' + credentials.cloud_name + '/' + item['resource_type'] + '/upload', skip_accept_encoding=True)
                connection.putheader('Content-Type', 'multipart/form-data; boundary=' + boundary)
                connection.putheader('Content-Length', str(len(prefix) + item['bytes'] + len(ending)))
                connection.endheaders()
                connection.send(prefix)
                sent_hash = hashlib.sha256()
                sent_bytes = 0
                for chunk in iter(lambda: handle.read(CHUNK_BYTES), b''):
                    sent_hash.update(chunk)
                    sent_bytes += len(chunk)
                    connection.send(chunk)
                connection.send(ending)
                after = os.fstat(handle.fileno())
                if (sent_bytes != item['bytes'] or sent_hash.hexdigest() != item['sha256'] or
                        (before.st_size, before.st_mtime_ns, before.st_ino) != (after.st_size, after.st_mtime_ns, after.st_ino)):
                    raise ReconciliationRequired('source_changed_during_post')
            response = connection.getresponse()
            payload = response.read(RESPONSE_LIMIT + 1)
            if len(payload) > RESPONSE_LIMIT:
                raise ReconciliationRequired('oversized_provider_response')
            if response.status not in {200, 201}:
                # A redirect is never followed, and no response body is logged.
                raise ReconciliationRequired('provider_status_requires_reconciliation')
            try:
                result = json.loads(payload)
            except (ValueError, UnicodeError):
                raise ReconciliationRequired('invalid_provider_response') from None
            if not isinstance(result, dict):
                raise ReconciliationRequired('invalid_provider_response')
            return result
        except (OSError, http.client.HTTPException):
            raise ReconciliationRequired('uncertain_post_outcome') from None
        finally:
            if abort_timer:
                abort_timer.cancel()
            if connection:
                connection.close()


def verified_response(item, response, credentials):
    if response.get('existing') is True or response.get('overwritten') is True:
        raise ReconciliationRequired('existing_or_overwritten_requires_independent_reconciliation')
    if (response.get('public_id') != item['public_id'] or
            response.get('resource_type') != item['resource_type'] or
            response.get('type') != 'authenticated' or
            type(response.get('bytes')) is not int or response['bytes'] != item['bytes'] or
            type(response.get('version')) is not int or response['version'] <= 0 or
            not isinstance(response.get('asset_id'), str) or
            not re.fullmatch(r'[A-Za-z0-9_-]{8,128}', response['asset_id'])):
        raise ReconciliationRequired('provider_identity_or_size_mismatch')
    returned_signature = response.get('signature')
    signed_fields = {'public_id': item['public_id'], 'version': response['version']}
    if not isinstance(returned_signature, str) or not any(
            hmac.compare_digest(returned_signature, signature(signed_fields, credentials.api_secret, algorithm))
            for algorithm in ['sha256', 'sha1']):
        raise ReconciliationRequired('provider_response_signature_invalid')
    return {key: response[key] for key in ['asset_id', 'public_id', 'version', 'resource_type', 'type', 'bytes']}


def run(root, manifest_path, execute=False, qualification=None, receipts=None,
        limit=1, transport=None, credentials_loader=None, connect_retries=0,
        start_index=0):
    manifest_path = prepare.contained_file(root, manifest_path)
    manifest = json.loads(manifest_path.read_text())
    result = prepare.verify(root, manifest)
    if (type(start_index) is not int or not 0 <= start_index < len(manifest['unique_uploads']) or
            type(limit) is not int or not 1 <= limit <= len(manifest['unique_uploads']) - start_index):
        raise UploadSafetyError('invalid_asset_limit')
    if not execute:
        return {**result, 'adapter_mode': 'DRY_RUN', 'adapter_posts': 0,
                'selected_objects': limit, 'selection_start_index': start_index,
                'note': 'No credentials read or network connections; execute/account qualification required.'}
    items = manifest['unique_uploads'][start_index:start_index + limit]
    cloud = qualify(qualification, items, prepare.digest(manifest_path, root), limit)
    if receipts is None:
        raise UploadSafetyError('explicit_receipt_directory_required')
    directory = validate_receipt_directory(root, receipts)
    completed = []
    with receipt_lock(directory):
        # Editable local receipts never count as proof; resumption requires
        # independent provider reconciliation, not trusting an uploaded flag.
        if any(receipt_path(directory, item).exists() for item in items):
            raise ReconciliationRequired('existing_local_receipt_requires_reconciliation')
        credentials = (credentials_loader or load_private_credentials)()
        checked_credentials(credentials, cloud)
        sender = transport or CloudinaryTransport(connect_retries=connect_retries)
        for item in items:
            path = receipt_path(directory, item)
            record = {'schema_version': 1, 'state': 'in_flight',
                      'public_id': item['public_id'], 'resource_type': item['resource_type'],
                      'type': 'authenticated', 'source_sha256': item['sha256'],
                      'source_bytes': item['bytes'], 'remote_bytes_verified': False,
                      'remote_delivery_verified': False, 'cloud_name': cloud,
                      'updated_at_utc': datetime.now(timezone.utc).isoformat()}
            write_receipt(path, record)
            params = {'timestamp': int(time.time()), 'public_id': item['public_id'],
                      'type': 'authenticated', 'overwrite': 'false',
                      'use_filename': 'false', 'unique_filename': 'false'}
            try:
                source = prepare.safe_path(root, item['source_path'])
                response = sender.post(item, source, credentials, params)
                receipt = verified_response(item, response, credentials)
                record.update(state='upload_response_verified_original_bytes_pending',
                              provider_response=receipt, response_signature_verified=True)
                write_receipt(path, record)
                completed.append(item['public_id'])
            except Exception:
                record.update(state='requires_reconciliation', failure_code='staging_outcome_not_accepted')
                write_receipt(path, record)
                raise ReconciliationRequired('staging_stopped_requires_reconciliation') from None
    return {'adapter_mode': 'PRIVATE_STAGING_RESPONSES_ONLY', 'response_receipts': len(completed),
            'remote_bytes_verified': False, 'production_delivery_verified': False,
            'public_delivery_enabled': False, 'catalogue_or_source_cutover': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo-root', type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument('--manifest', required=True, type=Path)
    parser.add_argument('--execute', action='store_true')
    parser.add_argument('--qualification', type=Path)
    parser.add_argument('--receipts', type=Path)
    parser.add_argument('--limit', type=int, default=1)
    parser.add_argument('--start-index', type=int, default=0)
    parser.add_argument('--connect-retries', type=int, choices=[0, 1], default=0)
    args = parser.parse_args()
    root = args.repo_root.resolve()
    try:
        qualification = None
        if args.execute and args.qualification:
            qualification = json.loads(prepare.contained_file(root, args.qualification).read_text())
        result = run(root, args.manifest, execute=args.execute,
                     qualification=qualification, receipts=args.receipts,
                     limit=args.limit, connect_retries=args.connect_retries,
                     start_index=args.start_index)
        print(json.dumps(result))
    except (ValueError, OSError, http.client.HTTPException):
        # Never serialize provider bodies, local exception messages or secrets.
        print(json.dumps({'status': 'STOPPED_FAIL_CLOSED',
                          'action': 'Review sanitized receipts/qualification; reconcile any uncertain outcome before retry.'}))
        raise SystemExit(1)


if __name__ == '__main__':
    main()
