# Ark rescue: Blender source and interactive replay

`ark-traffic-source.blend` contains the four original animal meshes, anatomical
armatures, eight-pose coordinated walk actions, three authored map scenes and
the cedar gate hinge rig. `author_ark_traffic.py` is the reproducible source.
Every runtime animal, gate and environment pixel is rendered in Blender.

The phone runs the path drawing and traffic simulation in Flutter. It moves
animals over the authored map, samples the directional Blender atlases, and
records route/wait/resume/gate commands. It does not play a movie of gameplay.
The backend independently replays the bounded commands to score the rescue.

The original three matching catalogue/level identities and their saved progress
remain in place. The new `ark_traffic` mode changes those three rounds to a
bridge/rocky shortcut rescue, a gated rescue, and a mud/two-gate rescue.

```sh
/Applications/Blender.app/Contents/MacOS/Blender --background --threads 4 \
  --python Motion/ark-traffic-blender-v1/author_ark_traffic.py -- \
  --build --render-animals --render-world --render-gate
```

Run `pack_assets.py` with the bundled Python runtime/Pillow to arrange existing
Blender frames into WebP atlases. Default output is `review/runtime`; the
`--runtime` option writes the same reviewed pixels into the mobile asset folder.
The fixed 160px cells have eight heading rows and nine columns: one resting
pose and eight walk poses. Foot anchors are the actual Blender projection of
the ground origin. Only the current map is decoded; the complete scene uses
33.59 MiB decoded image memory and stays below the 48 MiB loader limit.

`traffic-levels.json` is the exported public topology used to author the map.
`review/mobile-replay-proof.json` records solutions for all three real rounds;
Dart and Python agree on their positions, boarding and jam counts. The pure
Dart check is `Frontend/mobile/tool/check_ark_traffic.dart`. The focused native
widget tests are `ark_traffic_model_test.dart` and `ark_traffic_engine_test.dart`.

Native gameplay recording uses the actual Flutter engine widget and real input:

```sh
cd Frontend/mobile
flutter test --no-pub --concurrency=1 \
  --dart-define=RUN_ARK_TRAFFIC_VISUAL_REVIEW=true \
  test/ark_traffic_engine_test.dart
```

Review files include the accepted model still, the elephant/goat walk strip,
all directional views, three map renders, source hashes, frame bounds, and a
native draw-route/wait/boarding recording. These are off-device checks; no live
database migration, backend restart, phone build or phone install is performed.
