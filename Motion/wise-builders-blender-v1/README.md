# Wise and Foolish Builders source

`wise-builders-source.blend` preserves the editable house architecture, window and door openings, terracotta roof courses, wall braces, rock and sand foundations, keyed rain and wind, and a safe toy-house collapse. The houses contain no people.

Children choose foundations for two houses, place four walls, then a roof and optional storm brace. A storm test compares a rock foundation with sand. The server replays construction dependencies, every reset, and the test before deciding completion and rewards. The foundation choices can be swapped between houses.

`review-storm-01.png`, `review-storm-06.png`, and `review-storm-12.png` show the native Blender experiment. `review-storm-motion.gif` combines unchanged Blender house, collapse, and weather frames. `preview.html` is an interactive local construction review; its JavaScript syntax has been checked, but it has not been browser-verified.

```sh
Blender --background --threads 4 --python Motion/wise-builders-blender-v1/author_wise_builders.py -- --render
python Motion/wise-builders-blender-v1/pack_assets.py
```

The mobile loader caps decoded textures at 36 MiB. All assembly parts use one camera and registration rectangle; collapse has twelve 256-pixel poses, and each rain/wind combination has eight weather poses. Sources and authoring scripts stay here, while only packed PNGs ship in the mobile bundle.
