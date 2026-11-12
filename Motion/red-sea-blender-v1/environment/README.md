# Red Sea native Blender environment

Native Blender 4.5 LTS sea/environment assets for Make a Way. The accepted
portrait camera and complete six-point drop polygon remain unchanged. Moses and
travellers are separate character layers; this folder contains no people.

`build_environment.py` recreates the editable `red_sea_environment.blend` and
renders opaque PNG sequences. `liquid-review-v3.png` and
`fluid-studies-v3/motion/` retain the reviewed unified-water checkpoint. Earlier
review stills and `build_environment_v2_reference.py` retain rejected versions
for comparison; they are not runtime assets.

## Native water

A real Blender Ocean modifier supplies a wind-driven Phillips spectrum, choppy
wave elevations and generated whitecap density. Its evaluated height/foam
fields deform a single closed external liquid mesh. The hidden native Ocean
modifier stays editable in the saved scene. There are no internal submerged
refracting faces between side water and the withdrawing centre.

The ocean mean stays at zero through every state, with a 24-unit-deep bed.
Wind waves pre-exist the opening and fade smoothly at Moses' fixed dry shore.
A continuous sand ramp descends into the exposed channel. Withdrawal spreads
from the near shoreline towards the horizon after staff contact; C1 easing and
delayed central drainage avoid an abrupt full-depth crease. Irregular liquid
bulges, FFT-correlated foam, native spray and low-density mist move with the sea.
The ocean top and exposed faces share absorption/scattering parameters; exposed
faces use an art-directed blue response to remain readable at phone size.

The FFT is not itself periodic. Two forward-moving simulation windows are
crossfaded with cosine easing to create a two-second C1 height/foam loop with
identical endpoint fields and velocity. Native geometry/procedural shading is
used throughout; no flat image projection, external bitmap or paid service.

## Runtime contract

Cells are 300 × 650. There are 64 opening frames over 2.6 seconds and 48 idle
frames over two seconds. The ready folder retains one fallback PNG; the packer
aliases the first 24 opening cells as a one-second closed-sea loop without an
additional decoded atlas. Opening cell 24 repeats phase zero at one-second
staff contact. The final opening cell is byte-identical to idle cell zero.

113 source RGBA cells total 88,140,000 bytes (84.06 MiB) before atlas padding.
The runtime atlas packer is owned separately by the app integration.

`alignment.json` includes the actual native camera/geometry projection samples
at 24 wave phases. `verify_projection.py` consumes those samples instead of
reconstructing guessed shader or floor equations. `source-manifest.json` is
written after all frames finish; `verify_frames.py` checks counts, dimensions,
opaque alpha and exact intro/idle/ready endpoint equality.

## Reproduce

From the project root:

```sh
/Applications/Blender.app/Contents/MacOS/Blender -b \
  --python Motion/red-sea-blender-v1/environment/build_environment.py -- fluid_motion
/Applications/Blender.app/Contents/MacOS/Blender -b \
  --python Motion/red-sea-blender-v1/environment/build_environment.py -- deep_clips
python3 Motion/red-sea-blender-v1/environment/verify_projection.py
python3 Motion/red-sea-blender-v1/environment/verify_frames.py
```

Rendering uses the available Metal device. Runtime frames use Cycles denoising;
review studies are separate, larger images. Scene clocks and drag/game rules
remain controlled by the existing game engine.
