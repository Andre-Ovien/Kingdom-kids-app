# Kingdom Kids milestone chest — Blender source and runtime asset

A manufactured, child-friendly treasure chest with teal enamel, coral lock,
brushed brass edges, a real hollow body and a rigid curved lid on a fixed rear
hinge. The lid never detaches. The whole chest shakes briefly before the seam
brightens and the lid springs open into a stable pose.

The camera is locked. Portrait stage stills show the lighting and actual 3D
shadows. Runtime frames are the same chest cropped to a square transparent
canvas, leaving the full-screen stage and earned reward to Flutter.

## Deliverables

- `source/kingdom_kids_milestone_chest.blend` — editable Blender 4.5 source.
- `source/create_chest.py` — deterministic geometry, materials, lighting, rig,
  keyframes and renderer; uses no downloaded assets.
- `source/package_assets.py` — packs the transparent images with bundled Pillow.
- `review/closed.png`, `hero-open.png`, `seam-glow.png` — portrait proof stills.
- `review/timeline-contact-sheet.jpg` — first stage review, eight key moments.
- `review/runtime-contact-sheet.jpg` — final transparent-animation review on navy.
- `review/chest-motion-proof.mp4` — four-second box motion proof.
- `runtime/box_reveal_atlas.webp`, `box_reveal_poster.webp`, `box_reveal.json` —
  files intended for the app.
- `runtime/chest-000.png` through `chest-079.png` — full transparent frame masters.
- `runtime/verification.json` — dimensions, memory and transparency checks.

## Runtime contract

The one lossless WebP atlas is **3520 × 2816** pixels: **10 columns × 8 rows**,
80 sequential row-major frames, each **352 × 352**. At **20 fps** this is a
four-second animation. An RGBA decoded atlas occupies **37.8125 MiB**. The final
352-square poster adds 0.473 MiB, keeping the image total below 40 MiB. Decode
once per visible celebration, draw the current cell, and dispose the decoded
image on exit. Reduced motion loads the final poster without decoding the atlas.
Playback holds frame 79 after four seconds; this is a one-shot reveal, not a loop.

App paths in the JSON are `assets/images/milestones/box_reveal_atlas.webp` and
`assets/images/milestones/box_reveal_poster.webp`. Copy the JSON as
`assets/images/milestones/box_reveal.json`.

| Time | Chest motion / Flutter cue |
| --- | --- |
| 0.00–0.60 s | Chest still; Flutter introduces a full dark stage and spotlight. |
| 0.60–1.60 s | The chest shakes with increasing energy; seam warms. |
| 1.60–2.10 s | Seam flashes softly, rear-hinged lid opens and settles. |
| 2.10–2.80 s | Dynamic earned badge rises from the mouth; confetti releases. |
| 2.80–4.00 s | Chest holds open while Flutter settles confetti and reveals copy. |

Coordinates are normalized to the square frame, with x increasing rightward and
y downward. `boxAnchor` / badge emergence is **[0.50, 0.54]**. The floor contact
anchor is **[0.50, 0.925]**. `badgeAnchor` is **[0.46, 0.10]**, with the foreground
badge allowed to extend above the sprite canvas; reserve at least 64 logical
pixels of space above the sprite. The open lid remains behind the badge.

Flutter owns the stage, spotlight, floor shadow, badge artwork, earned number,
rank, confetti, copy, Keep exploring button, lifecycle and reduced-motion path.
None of those are baked into the atlas. The rendered chest is silent.

## Rebuild

From the repository root, with no other Blender job running:

```sh
/Applications/Blender.app/Contents/MacOS/Blender -b -t 4 --python Motion/level-milestone-box-v1/source/create_chest.py -- --review
/Applications/Blender.app/Contents/MacOS/Blender -b -t 4 --python Motion/level-milestone-box-v1/source/create_chest.py -- --runtime
/Users/macbook/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 Motion/level-milestone-box-v1/source/package_assets.py --runtime
/opt/homebrew/bin/ffmpeg -y -framerate 20 -i Motion/level-milestone-box-v1/review/motion-%03d.jpg -c:v libx264 -crf 18 -pix_fmt yuv420p -movflags +faststart Motion/level-milestone-box-v1/review/chest-motion-proof.mp4
```

Initial reviews render only three larger stills plus eight small timeline frames.
The final 80-frame Eevee render uses four CPU threads and 32 samples; on the
current Mac it needs roughly one minute, with Blender process memory below 0.5 GB.
