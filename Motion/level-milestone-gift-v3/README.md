# White/red reference present

This editable Blender scene follows the MAIN selected white/red gift video at
https://www.pinterest.com/pin/326651779251041743/ . The local clip and decoded
contact sheet are analysis references only. They are never copied into the app.
The scene is authored with native meshes, satin ribbon meshes, a connected
lattice deformation, eased object curves, and fabric follow-through shape keys.
No logo, jewellery, rank text, or earned level is baked into the render.

The active source is `source/build_reference_gift.py` and its saved scene is
`source/reference-white-red-present.blend`. `source/build_gift.py` and the
earlier `lively-square-present.blend` preserve the retired coral/mint prototype;
its hopping/fragments animation is not replayed by the reference scene. Only
its mesh/material/ribbon construction helpers are reused.

## Observed motion and authored checkpoints

| Seconds | Action |
| --- | --- |
| 0–0.48 | Gift enters from above and settles small |
| 0.48–1.35 | Small settling turn over circular pink floor glow |
| 1.35–2.32 | Grow toward the viewer while turning |
| 2.32–4.00 | Large box turns and rocks between front and three-quarter |
| 4.00–4.55 | Retract/spring smaller |
| 4.55–5.48 | Whole box stretches then compresses, bow follows through |
| 5.48–5.94 | Deep cap and attached bow shoot straight upward |
| 5.67–6.62 | Four thin white carton sides unfold into a flat cross |
| 5.58–6.72 | White vertical light streaks rise |
| 6.22–8.00 | White/pink flare and radiating sparkles; earned badge overlays |

The portrait review includes a seamless saturated magenta radial background,
soft circular floor glow, contact shadow, white drifting sparkles and white/pink
burst effects. Flutter will reproduce the field and effects around the dynamic
earned badge. Its badge emergence should begin near 6.3 seconds and finish near
7.1 seconds for this reference timing.

## Review commands

```sh
/Applications/Blender.app/Contents/MacOS/Blender -b -t 4 --python-exit-code 1 --python Motion/level-milestone-gift-v3/source/build_reference_gift.py -- --checkpoints
/Applications/Blender.app/Contents/MacOS/Blender -b -t 4 --python-exit-code 1 --python Motion/level-milestone-gift-v3/source/build_reference_gift.py -- --study
```

Checkpoints use 360×640 pixels and 48 EEVEE samples. The full review preserves
24 fps across all 192 frames at 256×456 pixels and 16 samples so design and
timing can be reviewed quickly before production render expense.

## Runtime promotion remains held

Do not overwrite the existing milestone assets until the full motion review is
approved. The planned production contract is version 1, 192 frames over eight
seconds at 24 fps, 304×304 cells, split into two 12-column × 8-row WebP pages.
Each page is 3648×2432, below the 4096 dimension limit; both decoded pages total
67.69 MiB. A small final poster supports reduced motion without loading atlases.
The production render must exclude review background/effects and retain alpha.
Camera crop and normalized badge/floor anchors must be measured from those
transparent frames before recording the final manifest.

Root owns runtime effect fields, dynamic earned badge/copy, lifecycle and reduced
motion handling, source asset promotion and phone installation.
