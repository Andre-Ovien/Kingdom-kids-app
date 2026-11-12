"""Build deployment metadata from completed original-byte verification, locally.

No provider calls, credentials, signed URLs, DB access, upload or activation.
Proof is an operator-reviewed artifact, not provider cryptographic attestation.
The final map must be reviewed and pinned by SHA256 in server configuration.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
SHA = re.compile(r'[a-f0-9]{64}\Z')
MAX_INPUT_BYTES = 8_388_608


class MapError(ValueError):
    pass


def read_json(path):
    if path.is_symlink():
        raise MapError('Input symlinks are not accepted.')
    with path.open('rb') as source:
        payload = source.read(MAX_INPUT_BYTES + 1)
    if len(payload) > MAX_INPUT_BYTES:
        raise MapError('Input metadata exceeds its bound.')
    return json.loads(payload), hashlib.sha256(payload).hexdigest()


def build_map(manifest, selection, proof, bindings, *, hashes, expected_count):
    """Reject partial/forged-scope metadata; never infer remote success."""
    objects = proof.get('objects', [])
    selected = selection.get('included', [])
    summary = proof.get('summary', {})
    if (selection.get('scope') != 'first_release_only'
            or proof.get('complete') is not True
            or summary.get('expected_count') != expected_count
            or summary.get('verified_count') != expected_count
            or summary.get('failed_count') != 0
            or len(objects) != expected_count or len(selected) != expected_count
            or proof.get('manifest_sha256') != hashes['manifest']
            or proof.get('selection_sha256') != hashes['selection']
            or not re.fullmatch(r'[a-z0-9][a-z0-9_-]{0,62}', proof.get('cloud_name', ''))):
        raise MapError('Complete exact first-release original-byte verification is required.')
    if bindings.get('schema_version') != 1 or bindings.get('scope') != 'first_release_only':
        raise MapError('Owner bindings are not an approved first-release schema.')
    uploads = {entry['public_id']: entry for entry in manifest['unique_uploads']}
    remote = {entry['public_id']: entry for entry in objects}
    chosen = {entry['public_id']: entry for entry in selected}
    if len(remote) != expected_count or len(chosen) != expected_count or remote.keys() != chosen.keys():
        raise MapError('Verification must bind every unique selected object exactly once.')
    for public_id, actual in remote.items():
        local = uploads.get(public_id)
        selected_item = chosen[public_id]
        if (local is None or actual.get('remote_original_verified') is not True
                or actual.get('type') != 'authenticated' or local.get('type') != 'authenticated'
                or actual.get('resource_type') != local.get('resource_type')
                or actual.get('sha256') != local.get('sha256')
                or actual.get('bytes') != local.get('bytes')
                or selected_item.get('bytes') != local.get('bytes')
                or selected_item.get('source_path') != local.get('source_path')
                or not isinstance(actual.get('asset_id'), str) or not actual['asset_id']
                or type(actual.get('version')) is not int or actual['version'] <= 0
                or not SHA.fullmatch(local.get('sha256', ''))
                or public_id != 'kingdom-kids/media-v1/sha256-' + local['sha256']
                   + (Path(local['source_path']).suffix.lower() if local['resource_type'] == 'raw' else '')):
            raise MapError('Verified original identity does not match the immutable selected source.')
    assets = {}
    aliases = {item['path']: item for item in manifest['asset_aliases']}
    for alias, uses in sorted(bindings['bindings'].items()):
        if (not isinstance(alias, str) or not alias.startswith(('Frontend/mobile/assets/', 'Backend/media/'))
                or any(c in alias for c in ('%', '\\', '?', '#'))
                or any(part in {'', '.', '..'} for part in alias.split('/'))
                or not isinstance(uses, list) or not uses
                or not all(isinstance(use, str) and len(use) <= 300 for use in uses)):
            raise MapError('Invalid canonical owner binding.')
        item = aliases.get(alias)
        if item is None or item['public_id'] not in remote:
            raise MapError('A runtime owner binding is absent from verified first-release objects.')
        verified = remote[item['public_id']]
        uploaded = uploads[item['public_id']]
        if (item['sha256'] != verified['sha256'] or item['bytes'] != verified['bytes']
                or item.get('resource_type') != verified['resource_type']
                or item.get('delivery_type') != verified['type']
                or alias not in uploaded.get('aliases', [])):
            raise MapError('Alias byte identity differs from verified original.')
        assets[alias] = {
            'public_id': item['public_id'], 'resource_type': item['resource_type'],
            'type': 'authenticated', 'sha256': item['sha256'], 'bytes': item['bytes'],
            'format': Path(uploaded['source_path']).suffix.lower().lstrip('.'),
            'uses': sorted(set(uses)),
        }
    return {
        'schema_version': 1, 'scope': 'first_release_only',
        'remote_originals_verified': True,
        'cloud_name': proof['cloud_name'],
        'source_sha256': hashes, 'verified_selected_objects': expected_count,
        'assets': assets,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', type=Path, default=ROOT / 'output/cloudinary-transfer-prep-20261111/manifest.json')
    parser.add_argument('--selection', type=Path, default=ROOT / 'output/cloudinary-transfer-prep-20261111/first-release-selection.json')
    parser.add_argument('--proof', type=Path, default=ROOT / 'output/cloudinary-transfer-prep-20261111/verified-private-objects.json')
    parser.add_argument('--bindings', type=Path, default=ROOT / 'Backend/content/releases/cloudinary_delivery_bindings_v1.json')
    parser.add_argument('--output', type=Path, default=ROOT / 'Backend/content/releases/cloudinary_first_release_v1.json')
    parser.add_argument('--expected-count', type=int, default=101)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    try:
        names = ('manifest', 'selection', 'proof', 'bindings')
        loaded = {name: read_json(getattr(args, name)) for name in names}
        data = build_map(*(loaded[name][0] for name in names),
                         hashes={name: loaded[name][1] for name in names}, expected_count=args.expected_count)
        payload = (json.dumps(data, ensure_ascii=False, sort_keys=True, indent=2) + '\n').encode()
        if args.output.is_symlink():
            raise MapError('Output symlinks are not accepted.')
        if args.check:
            if not args.output.is_file() or args.output.read_bytes() != payload:
                raise MapError('Frozen delivery map is missing or stale.')
        else:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_bytes(payload)
        print(json.dumps({'status': 'checked' if args.check else 'generated', 'map_sha256': hashlib.sha256(payload).hexdigest(), 'bound_aliases': len(data['assets']), 'verified_objects': args.expected_count, 'runtime_enabled': False}))
    except (OSError, ValueError, KeyError, TypeError):
        print('Delivery map refused: metadata is incomplete, invalid or outside its approved exact scope.', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
