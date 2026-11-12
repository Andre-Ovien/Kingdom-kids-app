"""Pack complete Blender renders without changing their appearance or pose.

Source manifests have clips{name:{frames:glob, durationSeconds, loop,
optional footAnchor/bodyHeight}}. Paths are relative to each source manifest.
Use the bundled Python runtime with Pillow. Default output is review-only.
"""
from __future__ import annotations

import argparse
import glob
import hashlib
import json
import math
from pathlib import Path

from PIL import Image

HERE = Path(__file__).resolve().parent
MOBILE = HERE.parents[1] / 'Frontend' / 'mobile'
MAX_DIMENSION = 4096
MAX_BYTES = 128 * 1024 * 1024


def grid(count: int, width: int, height: int) -> tuple[int, int]:
    options = []
    for columns in range(1, MAX_DIMENSION // width + 1):
        rows = math.ceil(count / columns)
        if rows * height <= MAX_DIMENSION:
            options.append((columns * rows, abs(math.log(columns * width / (rows * height))), columns, rows))
    if not options:
        raise ValueError(f'{count} frames of {width}x{height} need smaller cells or multiple pages')
    _, _, columns, rows = min(options)
    return columns, rows


def pack(sources: list[Path], runtime: bool) -> None:
    output = MOBILE / 'assets/images/games' if runtime else HERE / 'review/atlases'
    output.mkdir(parents=True, exist_ok=True)
    (HERE / 'review').mkdir(parents=True, exist_ok=True)
    clips, provenance, allocations = {}, {}, {}
    total = 0
    ready_loop_cells = None
    ready_loop_seconds = None
    for source in sources:
        source_manifest = json.loads(source.read_text())
        definitions = source_manifest['clips']
        if 'readyLoopCellCount' in source_manifest:
            count = source_manifest['readyLoopCellCount']
            if type(count) is not int or count <= 0:
                raise ValueError('The ready loop needs a positive integer cell count')
            seconds = source_manifest.get('readyLoopDurationSeconds', count / 24)
            if not isinstance(seconds, (int, float)) or not math.isfinite(seconds) or seconds <= 0:
                raise ValueError('The ready loop needs a positive finite duration')
            if ready_loop_cells is not None:
                raise ValueError('The ready loop is declared by multiple manifests')
            ready_loop_cells, ready_loop_seconds = count, seconds
        for name, definition in definitions.items():
            if name in clips:
                raise ValueError(f'Duplicate clip: {name}')
            raw_frames = definition['frames']
            frames = ([Path(p) for p in glob.glob(str(source.parent / raw_frames))]
                      if isinstance(raw_frames, str)
                      else [source.parent / p for p in raw_frames])
            frames = sorted(frames)
            if not frames:
                raise ValueError(f'No rendered frames for {name}')
            expected = definition.get('frameCount')
            if expected is not None and expected != len(frames):
                raise ValueError(f'{name} has {len(frames)} frames, expected {expected}')
            duration = definition['durationSeconds']
            if not isinstance(duration, (int, float)) or not math.isfinite(duration) or duration <= 0:
                raise ValueError(f'{name} needs a finite positive duration')
            with Image.open(frames[0]) as first:
                width, height = first.size
            if 'footAnchor' in definition:
                anchor, body_height = definition['footAnchor'], definition['bodyHeight']
                if len(anchor) != 2 or not (0 <= anchor[0] <= width and 0 <= anchor[1] <= height):
                    raise ValueError(f'{name} has a foot anchor outside its cell')
                if not math.isfinite(body_height) or not 0 < body_height <= height:
                    raise ValueError(f'{name} has an invalid body height')
            columns, rows = grid(len(frames), width, height)
            total += columns * width * rows * height * 4
            if total > MAX_BYTES:
                raise ValueError('Decoded graphics exceed 128 MiB; export smaller cells')
            atlas = Image.new('RGBA', (columns * width, rows * height))
            hashes = []
            for index, path in enumerate(frames):
                with Image.open(path) as frame:
                    if frame.size != (width, height):
                        raise ValueError(f'Camera/cell size changed in {path}')
                    rgba = frame.convert('RGBA')
                    atlas.paste(rgba, (index % columns * width, index // columns * height))
                hashes.append(hashlib.sha256(path.read_bytes()).hexdigest())
            character = 'footAnchor' in definition
            path = output / f'red-sea-{name.replace("_", "-")}-v1.webp'
            atlas.save(path, 'WEBP', lossless=character, quality=93, method=6)
            atlas.close()
            asset = str(path.relative_to(MOBILE)) if runtime else str(path)
            allocations[asset] = columns * width * rows * height * 4
            clip = {
                'asset': asset, 'cellWidth': width, 'cellHeight': height,
                'columns': columns, 'frameCount': len(frames),
                'durationSeconds': definition['durationSeconds'],
                'loop': definition['loop'],
            }
            if character:
                clip['footAnchor'] = definition['footAnchor']
                clip['bodyHeight'] = definition['bodyHeight']
            clips[name] = clip
            provenance[name] = {
                'sourceManifest': str(source), 'frames': [str(p) for p in frames],
                'sourceSha256': hashes,
                'atlasSha256': hashlib.sha256(path.read_bytes()).hexdigest(),
                'encodedBytes': path.stat().st_size,
            }
    required = {'moses_ready', 'moses_action', 'sea_ready', 'sea_opening', 'sea_idle'}
    required.update(f'traveller_{i}_{pose}' for i in range(3) for pose in ('idle', 'turn', 'walk', 'back'))
    missing = required.difference(clips)
    if missing:
        raise ValueError(f'Missing scene clips: {sorted(missing)}')
    if ready_loop_cells is not None:
        opening = clips['sea_opening']
        if ready_loop_cells > opening['frameCount']:
            raise ValueError('The ready loop extends beyond the opening sequence')
        # Reuse the closed-water cells already in the opening atlas. Decoding a
        # second ready animation would needlessly consume another large image.
        clips['sea_ready'] = {
            **opening, 'frameCount': ready_loop_cells,
            'durationSeconds': ready_loop_seconds, 'loop': True,
        }
        shared = provenance['sea_opening']
        provenance['sea_ready'] = {
            **shared,
            'frames': shared['frames'][:ready_loop_cells],
            'sourceSha256': shared['sourceSha256'][:ready_loop_cells],
            'sharedAtlasWith': 'sea_opening',
        }
    total = sum(allocations[asset] for asset in {clip['asset'] for clip in clips.values()})
    manifest_path = output / 'red-sea-graphics-v1.json' if runtime else HERE / 'graphics-manifest.json'
    manifest_path.write_text(json.dumps({'version': 1, 'clips': clips}, indent=2))
    (HERE / 'review/asset-provenance.json').write_text(json.dumps({
        'decodedBytes': total, 'runtime': runtime, 'clips': provenance,
    }, indent=2))
    print(json.dumps({'manifest': str(manifest_path), 'clips': len(clips), 'decodedMiB': round(total / 1024**2, 2)}))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('sources', nargs='+', type=Path)
    parser.add_argument('--runtime', action='store_true')
    args = parser.parse_args()
    pack([path.resolve() for path in args.sources], args.runtime)
