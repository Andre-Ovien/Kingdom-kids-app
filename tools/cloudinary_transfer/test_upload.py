"""Adapter safety tests with synthetic credentials and mocked transports ONLY."""

import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock

import prepare
import upload


ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / 'output/cloudinary-transfer-prep-20261111/manifest.json'
FAKE = upload.Credentials('synthetic-test-cloud', '12345678', 'TEST_ONLY_FAKE_API_SECRET')


def qualification():
    return {'schema_version': 1, 'cloud_name': FAKE.cloud_name,
            'approved_manifest_sha256': prepare.digest(MANIFEST, ROOT),
            'api_host': upload.API_HOST, 'private_authenticated_upload_confirmed': True,
            'staging_upload_authorized': True, 'stage': 'canary_only',
            'delivery_strategy': 'expiring_api_download_canary',
            'max_file_bytes': {'image': 40_000_000, 'raw': 40_000_000, 'video': 100_000_000}}


class FakeTransport:
    def __init__(self, change=None, failure=False):
        self.calls = []
        self.change = change or {}
        self.failure = failure

    def post(self, item, source, credentials, parameters):
        self.calls.append((item['public_id'], dict(parameters)))
        if self.failure:
            raise OSError('SYNTHETIC transport failure with sensitive-looking body')
        result = {'public_id': item['public_id'], 'resource_type': item['resource_type'],
                  'type': 'authenticated', 'bytes': item['bytes'], 'version': 1234,
                  'asset_id': 'synthetic_asset_1234', 'secure_url': 'https://not-persisted.invalid/?signature=synthetic',
                  'api_key': credentials.api_key}
        result['signature'] = upload.signature({'public_id': item['public_id'], 'version': 1234}, credentials.api_secret)
        result.update(self.change)
        return result


class UploadAdapterTests(unittest.TestCase):
    def directory(self):
        return tempfile.TemporaryDirectory(dir=ROOT / 'output/cloudinary-transfer-prep-20261111')

    def execute(self, directory, transport, **kwargs):
        return upload.run(ROOT, MANIFEST, execute=True,
                          qualification=kwargs.pop('qualification', qualification()),
                          receipts=Path(directory), transport=transport,
                          credentials_loader=lambda: FAKE, **kwargs)

    def test_default_never_reads_credentials_connects_or_writes_receipts(self):
        loader = Mock(side_effect=AssertionError('credentials accessed'))
        transport = Mock()
        result = upload.run(ROOT, MANIFEST, credentials_loader=loader, transport=transport)
        self.assertEqual(result['adapter_mode'], 'DRY_RUN')
        self.assertEqual(result['adapter_posts'], 0)
        loader.assert_not_called()
        transport.post.assert_not_called()

    def test_invalid_qualification_or_limits_fail_before_secret_read(self):
        cases = [{'private_authenticated_upload_confirmed': False},
                 {'api_host': 'attacker.invalid'}, {'approved_manifest_sha256': '0' * 64},
                 {'max_file_bytes': {'image': 1, 'video': 1, 'raw': 1}}]
        for change in cases:
            with self.subTest(change=change), self.directory() as directory:
                q = qualification(); q.update(change)
                loader = Mock(side_effect=AssertionError('credentials accessed'))
                with self.assertRaises(ValueError):
                    upload.run(ROOT, MANIFEST, execute=True, qualification=q,
                               receipts=Path(directory), credentials_loader=loader)
                loader.assert_not_called()

    def test_signed_response_has_sanitized_durable_receipt_but_no_byte_claim(self):
        with self.directory() as directory:
            transport = FakeTransport()
            result = self.execute(directory, transport)
            self.assertEqual(result['response_receipts'], 1)
            self.assertFalse(result['remote_bytes_verified'])
            files = list(Path(directory).glob('*.json'))
            self.assertEqual(len(files), 1)
            text = files[0].read_text(); record = json.loads(text)
            self.assertEqual(record['state'], 'upload_response_verified_original_bytes_pending')
            self.assertFalse(record['remote_bytes_verified'])
            self.assertTrue(record['response_signature_verified'])
            self.assertNotIn(FAKE.api_key, text)
            self.assertNotIn(FAKE.api_secret, text)
            self.assertNotIn('secure_url', text)
            self.assertEqual(files[0].stat().st_mode & 0o777, 0o600)
            params = transport.calls[0][1]
            self.assertEqual(params['type'], 'authenticated')
            self.assertEqual(params['overwrite'], 'false')
            self.assertEqual(params['unique_filename'], 'false')

    def test_existing_or_unknown_outcome_stops_without_blind_retry(self):
        for transport in [FakeTransport({'existing': True}), FakeTransport(failure=True)]:
            with self.subTest(transport=type(transport).__name__), self.directory() as directory:
                with self.assertRaises(upload.ReconciliationRequired):
                    self.execute(directory, transport)
                self.assertEqual(len(transport.calls), 1)
                with self.assertRaises(upload.ReconciliationRequired):
                    self.execute(directory, transport)
                self.assertEqual(len(transport.calls), 1)
                self.assertEqual(json.loads(next(Path(directory).glob('*.json')).read_text())['state'], 'requires_reconciliation')

    def test_mismatched_identity_public_type_or_bad_signature_is_never_accepted(self):
        for change in [{'type': 'upload'}, {'public_id': 'different'}, {'bytes': 1}, {'signature': '0' * 64}]:
            with self.subTest(change=change), self.directory() as directory:
                with self.assertRaises(upload.ReconciliationRequired):
                    self.execute(directory, FakeTransport(change))

    def test_official_upload_signature_example_and_receipt_path_escape(self):
        self.assertEqual(upload.signature({'timestamp': 1315060510}, 'abcd', 'sha1'),
                         'a21ad0f63beb4de2e5575204b79ab90bffb02c10')
        with self.assertRaises(ValueError):
            upload.validate_receipt_directory(ROOT, Path('output/../Frontend/mobile/assets'))

    def test_rest_transport_uses_authenticated_endpoint_streams_and_never_follows_redirect(self):
        manifest = json.loads(MANIFEST.read_text()); item = manifest['unique_uploads'][0]
        source = prepare.safe_path(ROOT, item['source_path'])
        class Response:
            status = 303
            def read(self, maximum):
                self.maximum = maximum
                return b'synthetic error body not logged'
        class Socket:
            def settimeout(self, value): self.timeout = value
        class Connection:
            def __init__(self): self.sock = Socket(); self.sent = []; self.request = None; self.headers = {}
            def connect(self): pass
            def putrequest(self, method, path, **kwargs): self.request = (method, path)
            def putheader(self, key, value): self.headers[key] = value
            def endheaders(self): pass
            def send(self, data): self.sent.append(data)
            def getresponse(self): return Response()
            def close(self): pass
        connection = Connection(); factory = Mock(return_value=connection)
        transport = upload.CloudinaryTransport(connection_factory=factory)
        params = {'timestamp': 1234, 'public_id': item['public_id'], 'type': 'authenticated', 'overwrite': 'false', 'use_filename': 'false', 'unique_filename': 'false'}
        with self.assertRaises(upload.ReconciliationRequired):
            transport.post(item, source, FAKE, params)
        factory.assert_called_once()
        self.assertEqual(connection.request, ('POST', '/v1_1/' + FAKE.cloud_name + '/image/upload'))
        form = b''.join(connection.sent)
        self.assertIn(b'name="type"\r\n\r\nauthenticated\r\n', form)
        self.assertIn(upload.signature(params, FAKE.api_secret).encode(), form)
        public_params = dict(params); public_params['type'] = 'upload'
        self.assertNotIn(upload.signature(public_params, FAKE.api_secret).encode(), form)
        self.assertTrue(all(len(chunk) <= upload.CHUNK_BYTES for chunk in connection.sent))
        self.assertEqual(sum(map(len, connection.sent)), int(connection.headers['Content-Length']))


if __name__ == '__main__':
    unittest.main()
