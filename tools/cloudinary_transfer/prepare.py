#!/usr/bin/env python3
"""Local-only canonical media inventory and dry-run plan. Never uploads.

No network modules, credentials, environment reads, Django imports or DB access.
The approved narration release is an allowlist, not a scan of MEDIA_ROOT.
"""

import argparse
import ast
from collections import defaultdict
from datetime import datetime, timezone
import hashlib
import json
import mimetypes
from pathlib import Path, PurePosixPath
import re
import struct


MEDIA_SUFFIXES = {'.png', '.jpg', '.jpeg', '.webp', '.gif', '.avif', '.svg',
                  '.mp3', '.wav', '.m4a', '.aac', '.flac', '.ogg', '.mp4',
                  '.mov', '.webm', '.glb', '.gltf', '.bin'}
AUDIO_VIDEO = {'.mp3', '.wav', '.m4a', '.aac', '.flac', '.ogg', '.mp4', '.mov', '.webm'}
RAW = {'.glb', '.gltf', '.bin', '.json'}
NARRATION = 'Backend/content/releases/character_narration_v1_manifest.json'
MATCHING = 'Backend/Core/apps/games/content/published_matching_release_v1.json'
MOBILE = 'Frontend/mobile/'
NAMESPACE = 'kingdom-kids/media-v1/sha256-'
LEGACY = {'assets/images/david_and_goliath.png', 'assets/images/jonah.jpg',
          'assets/images/crossing_red_sea.webp', 'assets/images/noahs_ark.png',
          'assets/images/creation_week.jpg', 'assets/images/daniel.jpeg',
          'assets/images/moses2.jpeg', 'assets/images/esther.jpeg'}
INACTIVE_ONBOARDING = {
    'assets/images/onboarding/story-explorer-v2.png',
    'assets/images/onboarding/noahs-ark-v2.png',
    'assets/images/onboarding/story-celebration-v2.png',
}


def contained_source(root, path):
    path = path if path.is_absolute() else root / path
    relative = path.relative_to(root)
    cursor = root
    for part in relative.parts:
        cursor /= part
        if cursor.is_symlink():
            raise ValueError('Symlink source is not permitted')
    path.resolve().relative_to(root)
    return path


def contained_file(root, path):
    path = contained_source(root, path)
    if not path.is_file():
        raise ValueError('Expected a contained source file')
    return path


def digest(path, root):
    path = contained_file(root, path)
    value = hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b''):
            value.update(chunk)
    return value.hexdigest()


def safe_path(root, relative):
    if not isinstance(relative, str) or '\\' in relative:
        raise ValueError('Unsafe media path')
    rel = PurePosixPath(relative)
    if rel.is_absolute() or any(p in {'', '.', '..'} for p in relative.split('/')):
        raise ValueError('Unsafe media path')
    if not (relative.startswith(MOBILE + 'assets/') or relative.startswith('Backend/media/')):
        raise ValueError('Media must be beneath an approved asset root')
    return contained_file(root, root / relative)


def resource_type(path):
    suffix = Path(path).suffix.lower()
    return 'video' if suffix in AUDIO_VIDEO else 'raw' if suffix in RAW else 'image'


def public_id(sha, kind, suffix):
    return NAMESPACE + sha + (suffix.lower() if kind == 'raw' else '')


def strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for child in value.values():
            yield from strings(child)
    elif isinstance(value, list):
        for child in value:
            yield from strings(child)


def declared_assets(root):
    """Flutter asset-directory entries include immediate files, not descendants."""
    text = contained_file(root, root / MOBILE / 'pubspec.yaml').read_text()
    block = text.split('\n  assets:\n', 1)[1].split('\n  #', 1)[0]
    result = set()
    for item in re.findall(r'^    - (assets/[^\s#]+)', block, re.M):
        path = contained_source(root, root / MOBILE / item)
        if item.endswith('/'):
            for p in path.iterdir():
                if p.is_symlink():
                    raise ValueError('Symlink asset is not permitted')
                if p.is_file():
                    contained_file(root, p)
                    result.add(p.relative_to(root / MOBILE).as_posix())
        elif path.is_file():
            result.add(item)
    return result


def glb_dependencies(path):
    with path.open('rb') as handle:
        magic, version, size = struct.unpack('<III', handle.read(12))
        length, kind = struct.unpack('<II', handle.read(8))
        if magic != 0x46546C67 or version != 2 or kind != 0x4E4F534A or length > size:
            raise ValueError('Invalid GLB container')
        doc = json.loads(handle.read(length).decode('utf-8').rstrip(' \x00'))
    uris = [o['uri'] for key in ('buffers', 'images') for o in doc.get(key, []) if 'uri' in o]
    return {'external_uris': [u for u in uris if not u.startswith('data:')],
            'embedded_image_count': sum('bufferView' in o or o.get('uri', '').startswith('data:')
                                        for o in doc.get('images', [])),
            'binary_buffers': sum('uri' not in o for o in doc.get('buffers', []))}


def inventory(root):
    evidence = defaultdict(set)
    metadata = defaultdict(dict)
    sidecars = []
    declarations = declared_assets(root)

    def add(asset, source, reason, **extra):
        if asset in LEGACY or asset in INACTIVE_ONBOARDING:
            return
        if '$' in asset or Path(asset).suffix.lower() not in MEDIA_SUFFIXES | {'.json'}:
            return
        evidence[asset].add((source, reason))
        metadata[asset].update(extra)

    # Direct literals in shipping Dart; old alias keys and retained inactive
    # onboarding illustrations are explicitly excluded above.
    for source in sorted(contained_source(root, root / MOBILE / 'lib').rglob('*.dart')):
        if source.name == 'ark_garden_assets.dart':
            continue  # Its assets/... entries are relative to the game origin.
        text = contained_file(root, source).read_text()
        for match in re.finditer(r"['\"](assets/[^'\"\n]+)['\"]", text):
            add(match.group(1), source.relative_to(root).as_posix() + ':' + str(text.count('\n', 0, match.start()) + 1), 'Dart asset reference')

    # Resolve bounded dynamic asset families; never include arbitrary directory
    # contents merely because pubspec declares them.
    dynamic = {
        'assets/images/games/creation_world/': 'Frontend/mobile/lib/features/games/presentation/creation_world_graphics.dart',
        'assets/images/games/wise_builders/': 'Frontend/mobile/lib/features/games/presentation/wise_builders_engine.dart',
    }
    for prefix, source in dynamic.items():
        for p in sorted((root / MOBILE / prefix).glob('*.png')):
            if p.name != 'cover.png':
                add(p.relative_to(root / MOBILE).as_posix(), source, 'Bounded dynamic graphics family', catalogue_state='retired_game_assets_still_bundled')
    for name in ['ruth_field', 'grain_barley', 'grain_oats', 'grain_wheat']:
        add('assets/images/games/matching/' + name + '.png', 'Frontend/mobile/lib/features/games/presentation/ruth_harvest_engine.dart', 'Bounded grain/field interpolation')
    for name in ['app_theme', 'tap', 'select', 'success', 'streak']:
        add('assets/audio/app/' + name + '.wav', 'Frontend/mobile/lib/shared/audio/app_sound_cue.dart', 'Declared app sound selection')

    # Current game graphics manifests have transitive local asset references.
    for asset in ['assets/images/games/ark_traffic/manifest.json', 'assets/images/games/red-sea-graphics-v1.json']:
        add(asset, 'Frontend/mobile/lib/features/games/presentation/', 'Runtime graphics manifest', catalogue_state='retired_game_assets_still_bundled')
        path = safe_path(root, MOBILE + asset)
        for value in strings(json.loads(path.read_text())):
            if value.startswith('assets/'):
                add(value, MOBILE + asset, 'Graphics-manifest dependency', catalogue_state='retired_game_assets_still_bundled')

    # Canonical current story covers: initial refreshed8 + replacement5. The
    # unavailable two story covers still serve available picture-puzzle games.
    story_slugs = ['david-and-goliath', 'jonah-and-the-big-fish', 'crossing-the-red-sea',
                   'noah-builds-the-ark', 'creation-week', 'daniel-in-the-lions-den',
                   'moses-follows-god', 'esther-speaks-up']
    for slug in story_slugs:
        add('assets/images/stories/' + slug + '-v2.webp', 'Backend/Core/apps/stories/migrations/0003_refresh_story_cover_art.py', 'Canonical refreshed story/game cover')
    for slug in ['lost-sheep', 'joseph-colorful-coat', 'good-samaritan', 'walls-of-jericho', 'ruth-and-naomi']:
        add('assets/images/stories/' + slug + '-storybook-v1.webp', 'Backend/Core/apps/stories/migrations/0010_storybook_cover_artwork.py', 'Canonical replacement story/puzzle cover', story_hidden=(slug in {'lost-sheep', 'good-samaritan'}), still_used_by_game=True)
    for value in strings(json.loads(contained_file(root, root / MATCHING).read_text())):
        if value.startswith('assets/'):
            add(value, MATCHING, 'Published matching release dependency')
    # Retained picture-puzzle content concatenates Python string literals.
    source = root / 'Backend/Core/apps/games/migrations/0008_puzzle_quest.py'
    for node in ast.walk(ast.parse(contained_file(root, source).read_text())):
        if isinstance(node, ast.Constant) and isinstance(node.value, str) and node.value.startswith('assets/'):
            add(node.value, source.relative_to(root).as_posix(), 'Retained picture-puzzle content', catalogue_state='retired_game_assets_still_bundled')
    add('assets/images/games/wise_builders/cover.png', 'Backend/Core/apps/games/migrations/0016_wise_builders.py', 'Retained game cover', catalogue_state='retired_game_assets_still_bundled')

    # Canonical mobile 3D model allowlist; review suffixes are production
    # filenames in this paused game, not permission to scan output previews.
    ark_source = root / MOBILE / 'lib/features/games/data/ark_garden_assets.dart'
    ark_text = contained_file(root, ark_source).read_text().split('static const files = <String>{', 1)[1].split('};', 1)[0]
    for filename in re.findall(r"'([^']+)'", ark_text):
        asset = 'assets/games/ark_garden/' + filename
        if Path(filename).suffix.lower() in MEDIA_SUFFIXES | {'.json'}:
            add(asset, ark_source.relative_to(root).as_posix(), 'Explicit native game allowlist', catalogue_state='paused_game_assets_still_bundled')
    for p in sorted((root / MOBILE / 'assets/games/ark_garden').rglob('*')):
        if p.is_file() and p.suffix in {'.js', '.mjs', '.css', '.html'}:
            sidecars.append({'path': p.relative_to(root).as_posix(), 'sha256': digest(p, root), 'upload': False, 'reason': 'Executable local game-engine dependency; not a media upload or approved remote-code migration'})
    add('assets/images/branding/kingdom-kids-car-icon-v1.png', 'Frontend/mobile/pubspec.yaml:flutter_launcher_icons', 'Shipping app-icon build input', build_only=True)

    # EXACT36 approved narration files; no MEDIA_ROOT directory scan.
    narration = json.loads(contained_file(root, root / NARRATION).read_text())
    assert len(narration['tracks']) == 33 and len(narration['auditions']) == 3
    backend_rows = []
    for kind, records in [('story_narration', narration['tracks']), ('narrator_sample', narration['auditions'])]:
        for record in records:
            rel = 'Backend/media/' + record['file']
            p = safe_path(root, rel)
            if digest(p, root) != record['sha256']:
                raise ValueError('Approved narration hash mismatch: ' + rel)
            backend_rows.append((rel, {'kind': kind, 'character': record['character'], 'story_slug': record.get('story_slug'), 'duration_seconds': record['duration_seconds'], 'release_sha256': record['sha256'], 'source': NARRATION}))
    sidecars.append({'path': NARRATION, 'sha256': digest(root / NARRATION, root), 'upload': False, 'reason': 'Canonical release metadata, story text hashes and word/segment timings remain backend-owned; not a recording or Cloudinary media object'})

    rows = []
    exclusions = []
    for p in sorted(contained_source(root, root / MOBILE / 'assets').rglob('*')):
        if p.is_symlink():
            raise ValueError('Symlink asset is not permitted')
        if not p.is_file():
            continue
        contained_file(root, p)
        asset = p.relative_to(root / MOBILE).as_posix()
        if p.suffix.lower() not in MEDIA_SUFFIXES | {'.json'}:
            continue
        if asset in LEGACY:
            why = 'Superseded legacy alias; current resolver points to refreshed cover'
        elif asset in INACTIVE_ONBOARDING:
            why = 'Retained illustration implementation is explicitly inactive in current photographic onboarding'
        elif asset not in evidence:
            why = 'No canonical current runtime/build reference found; working variant or unreferenced asset'
        elif asset not in declarations and not metadata[asset].get('build_only'):
            why = 'Not declared in current Flutter asset bundle; not shipping runtime media'
        else:
            why = None
        if why:
            exclusions.append({'path': p.relative_to(root).as_posix(), 'bytes': p.stat().st_size, 'sha256': digest(p, root), 'reason': why})
            continue
        rows.append({'path': p.relative_to(root).as_posix(), 'references': [{'source': s, 'reason': r} for s, r in sorted(evidence[asset])], **metadata[asset]})
    missing = []
    for asset, refs in sorted(evidence.items()):
        p = root / MOBILE / asset
        if not p.exists():
            missing.append({'path': MOBILE + asset, 'references': sorted(refs)})
    # Direct policy JSON is a local policy document, not media for migration.
    policy = MOBILE + 'assets/policies/privacy-policy.json'
    rows = [r for r in rows if r['path'] != policy]
    sidecars.append({'path': policy, 'sha256': digest(root / policy, root), 'upload': False,
                     'reason': 'Bundled canonical policy document; outside media transfer scope'})
    for rel, meta in backend_rows:
        rows.append({'path': rel, 'references': [{'source': NARRATION, 'reason': 'Approved release recording allowlist'}], **meta})

    for row in rows:
        path = safe_path(root, row['path'])
        row.update(bytes=path.stat().st_size, sha256=digest(path, root), mime_type=mimetypes.guess_type(path.name)[0] or 'application/octet-stream', resource_type=resource_type(path))
        if row['path'].startswith(MOBILE + 'assets/audio/david/') or any(name in path.name for name in ['goliath', 'david-valley']):
            row['catalogue_state'] = 'paused_game_assets_still_bundled'
        row.setdefault('catalogue_state', 'current_runtime_or_build_reference')
        row['delivery_type'] = 'authenticated'
        row['public_id'] = public_id(row['sha256'], row['resource_type'], path.suffix)
        if path.suffix == '.glb':
            row['mime_type'] = 'model/gltf-binary'
            row['model_dependencies'] = glb_dependencies(path)
            if row['model_dependencies']['external_uris']:
                raise ValueError('External GLB dependency requires explicit mapping: ' + row['path'])
        if row.get('kind') in {'story_narration', 'narrator_sample'}:
            row['within_current_flutter_32MiB_download_limit'] = row['bytes'] <= 32 * 1024 * 1024
        row['requires_chunked_upload_over_100MB'] = row['bytes'] > 100_000_000
        row['over_current_public_free_tier_file_limit'] = row['bytes'] > (100_000_000 if row['resource_type'] == 'video' else 10_000_000)
    groups = defaultdict(list)
    for row in rows:
        groups[(row['resource_type'], row['public_id'])].append(row)
    uploads = []
    for (kind, pid), aliases in sorted(groups.items()):
        first = aliases[0]
        uploads.append({'public_id': pid, 'resource_type': kind, 'type': 'authenticated', 'sha256': first['sha256'], 'bytes': first['bytes'], 'source_path': first['path'], 'aliases': [r['path'] for r in aliases], 'upload_options': {'overwrite': False, 'use_filename': False, 'unique_filename': False}, 'transformation': None, 'remote_receipt': None, 'remote_verified': False})
    return {'schema_version': 1, 'generated_at_utc': datetime.now(timezone.utc).isoformat(),
            'status': 'PREPARATION_ONLY_NO_NETWORK_OR_UPLOAD',
            'selection_policy': 'Canonical current Dart/build references + bounded dynamic families + transitive manifests + exact approved36 narration files. Paused/retired canonical bundled game assets are identified, not republished. No database or private upload scan.',
            'repository_root': str(root), 'source_release': {'path': NARRATION, 'sha256': digest(root / NARRATION, root)},
            'asset_aliases': sorted(rows, key=lambda r: r['path']), 'unique_uploads': uploads,
            'excluded_mobile_files': exclusions, 'non_media_dependencies_not_uploaded': sidecars,
            'missing_references': missing,
            'global_exclusions': ['output/**', 'docs/design-archive/**', 'Motion/** source/working variants', '.env/secrets/credentials', 'tests/private uploads', 'Backend/media/** except exact approved release recordings', 'source code/vendor scripts/fonts/policy documents', 'hidden-story narration outside approved release', 'local:// video placeholders'],
            'summary': {'selected_paths': len(rows), 'unique_uploads': len(uploads), 'source_bytes': sum(r['bytes'] for r in rows), 'deduplicated_upload_bytes': sum(r['bytes'] for r in uploads), 'excluded_mobile_paths': len(exclusions), 'narration_tracks': len(narration['tracks']), 'narrator_samples': len(narration['auditions']), 'recording_bytes': sum(safe_path(root, r).stat().st_size for r, _ in backend_rows), 'GLBs': sum(r['path'].endswith('.glb') for r in rows), 'actual_video_files': sum(Path(r['path']).suffix in {'.mp4', '.mov', '.webm'} for r in rows), 'over_free_file_limit': [r['path'] for r in rows if r['over_current_public_free_tier_file_limit']]}}


def verify(root, manifest):
    if manifest.get('schema_version') != 1 or not isinstance(manifest.get('unique_uploads'), list):
        raise ValueError('Unsupported manifest')
    rows = {r['path']: r for r in manifest['asset_aliases']}
    if any(r.get('remote_verified', False) is not False or r.get('remote_receipt') is not None
           for r in rows.values()):
        raise ValueError('Preparation aliases cannot claim remote verification')
    canonical = inventory(root)
    if (manifest.get('source_release') != canonical['source_release'] or
            set(rows) != {r['path'] for r in canonical['asset_aliases']}):
        raise ValueError('Manifest differs from the canonical allowlist/release')
    if manifest.get('missing_references'):
        raise ValueError('Resolve missing canonical dependencies first')
    seen = set()
    for upload in manifest['unique_uploads']:
        if upload.get('remote_verified') is not False or upload.get('remote_receipt') is not None:
            raise ValueError('Preparation cannot claim a remote receipt or verification')
        if upload['type'] != 'authenticated' or upload['upload_options'] != {'overwrite': False, 'use_filename': False, 'unique_filename': False} or upload.get('transformation') is not None:
            raise ValueError('Unsafe upload options')
        key = (upload['resource_type'], upload['public_id'])
        if key in seen or not upload['aliases']:
            raise ValueError('Duplicate public ID or no sources')
        seen.add(key)
        if upload['source_path'] not in upload['aliases']:
            raise ValueError('Source is not an approved alias')
        for rel in upload['aliases']:
            p = safe_path(root, rel)
            sha = digest(p, root)
            kind = resource_type(p)
            if sha != upload['sha256'] or p.stat().st_size != upload['bytes'] or kind != upload['resource_type'] or public_id(sha, kind, p.suffix) != upload['public_id']:
                raise ValueError('Source changed or wrong object identity: ' + rel)
            if rel not in rows or rows[rel]['sha256'] != sha:
                raise ValueError('Alias not in inventory')
    if set(rows) != {r for u in manifest['unique_uploads'] for r in u['aliases']}:
        raise ValueError('Incomplete upload/alias mapping')
    return {'status': 'LOCAL_DRY_RUN_PASS', 'network_requests': 0, 'uploads': 0,
            'source_files_verified': len(rows), 'unique_objects_verified': len(seen),
            'bytes_if_authorized_later': sum(u['bytes'] for u in manifest['unique_uploads']),
            'credentials_read': False, 'overwrite_enabled': False,
            'note': 'No upload implementation exists in this preparation tool. Account-limit/access-control verification and separate explicit upload authorization remain required.'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['inventory', 'verify', 'plan'])
    parser.add_argument('--repo-root', type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument('--manifest', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    root = args.repo_root.resolve()
    if args.command == 'inventory':
        if args.output is None:
            parser.error('inventory requires --output; no default file mutations')
        data = inventory(root)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(data, indent=2, ensure_ascii=False) + '\n')
        print(json.dumps(data['summary']))
        return
    if args.manifest is None:
        parser.error('--manifest required')
    manifest = json.loads(args.manifest.read_text())
    result = verify(root, manifest)
    if args.command == 'plan':
        result['objects'] = manifest['unique_uploads']
        result['required_configuration_after_handoff'] = {'cloud_name': None, 'api_key': None, 'api_secret': 'SERVER_SECRET_ONLY_NOT_READ_BY_THIS_TOOL', 'account_limits_verified': False, 'expiring_authenticated_delivery_route_verified': False}
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({k: v for k, v in result.items() if k != 'objects'}))


if __name__ == '__main__':
    main()
