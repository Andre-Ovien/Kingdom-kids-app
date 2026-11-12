"""Bundle reviewed native exports and the checked course; never publishes a game.

Run only after the visible Blender exports and scene generator are finished.
This is file packaging and deterministic contract verification, not modeling.
"""

from pathlib import Path
import hashlib
import json
import shutil
import sys

MOBILE = Path(__file__).resolve().parents[1]
REPO = MOBILE.parents[1]
SOURCE = MOBILE / 'tool/ark_elephant_preview'
DESTINATION = MOBILE / 'assets/games/ark_garden'
sys.path.insert(0, str(REPO / 'Backend/Core'))
from apps.games.ark_garden import SPECIES, replay_ark_garden, validate_ark_garden_config  # noqa: E402

FILES = [
    'garden.html', 'garden.css', 'preview.css', 'garden_preview.mjs',
    'garden_contract.mjs', 'garden_traffic.mjs', 'garden_asset_integrity.mjs',
    'animal_locomotion.mjs', 'animal_preview_config.mjs',
    'garden_native_assets.json', 'garden_course_v2.json',
    'vendor/LICENSE', 'vendor/three.module.js', 'vendor/three.core.js',
    'vendor/loaders/GLTFLoader.js', 'vendor/utils/BufferGeometryUtils.js',
    'assets/garden.png', 'assets/ark-review.glb', 'assets/noah-review.glb',
    'assets/licenses/ANIMAL_CREDITS.txt', 'assets/licenses/Wildfire-Games.txt',
    *[f'assets/{species}-review.glb' for species in SPECIES],
]


def main():
    config = json.loads((SOURCE / 'garden_course_v2.json').read_text())
    manifest = json.loads((SOURCE / 'garden_native_assets.json').read_text())
    validate_ark_garden_config(config)
    if config['garden']['version'] != 2 or set(manifest['animals']) != set(SPECIES):
        raise ValueError('Packaging requires all ten native exports and the v2 course.')
    for filename, expected in [
        ('ark-review.glb', manifest['ark_sha256']),
        ('noah-review.glb', manifest['noah_sha256']),
        *[(f'{species}-review.glb', manifest['animals'][species]['asset_sha256']) for species in SPECIES],
    ]:
        if hashlib.sha256((SOURCE / 'assets' / filename).read_bytes()).hexdigest() != expected:
            raise ValueError(f'{filename} changed after the course was checked.')
    cases = []
    for name, record in manifest['proof']['traffic']['replays'].items():
        result = {'taps': sorted([
            {'tick': tick, 'animal_id': identifier} for identifier, tick in record['taps'].items()
        ], key=lambda tap: tap['tick']), 'elapsed_ticks': record['completed_tick']}
        replay = replay_ark_garden(config, result)
        if not replay['completed'] or replay['arrival_ticks'] != record['arrivals']:
            raise ValueError(f'JavaScript/Python queue mismatch in {name}.')
        cases.append({'name': name, 'result': result, 'expected': replay})
    # Verify every resource before writing any bundle copies.
    for filename in FILES:
        if not (SOURCE / filename).is_file():
            raise FileNotFoundError(f'The offline resource is missing: {filename}')
    for filename in FILES:
        destination = DESTINATION / filename
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(SOURCE / filename, destination)
    for destination in [
        REPO / 'Backend/Core/apps/games/content/ark_garden_course_v2.json',
        MOBILE / 'test/fixtures/ark_garden_course_v2.json',
    ]:
        destination.write_text(json.dumps(config, indent=2) + '\n')
    golden = {'scenarios': cases}
    for destination in [
        REPO / 'Backend/Core/apps/games/content/ark_garden_replay_v2.json',
        MOBILE / 'test/fixtures/ark_garden_replay_v2.json',
    ]:
        destination.write_text(json.dumps(golden, indent=2) + '\n')
    size = sum((DESTINATION / filename).stat().st_size for filename in FILES)
    print(f'Bundled {len(FILES)} offline resources ({size / 1024 / 1024:.1f} MiB); '
          f'{len(cases)} real ten-animal JS/Python queue replays agree. No catalogue or live data changes.')


if __name__ == '__main__':
    main()
