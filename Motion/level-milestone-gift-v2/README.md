# Kingdom Kids wrapped-gift milestone — v2

The approved correction replaces the treasure chest with an original wrapped
package. Coral paper walls, a mint lid, and a soft gold ribbon/bow form a clear
gift silhouette. The ribbon is actual thin tape geometry with curved loops,
thickness and a reverse material. There is no safe, chest hardware, hinge or
humanoid character in this scene.

`source/gift-package.blend` contains the native geometry, independent paper panel
objects, lights, locked camera and keyed motion. `source/build_gift.py` rebuilds
it deterministically in Blender 4.5. Prior chest source is preserved separately
in `Motion/level-milestone-box-v1`; it is no longer the approved visual concept.

The package waits, shakes, then releases six separate thin cardboard/paper
panels. The lid and attached bow take a controlled outward arc. Wall sheets
separate, rotate and settle with different floor angles and visible gaps. The
base also shifts, so the result reads as loose gift pieces. Nothing remains as
an intact open container. The pieces make room for a dynamic foreground medal.

## Runtime contract

The one lossless, exact-RGBA WebP atlas uses 80 row-major 352-square frames,
10 columns × 8 rows: 3520 × 2816 pixels, 20 fps, four seconds. Decoded RGBA memory
is 37.8125 MiB; the final poster adds 0.473 MiB. `runtime/verification.json`
records bounds/transparency checks and exact decoded pixel comparison against
all Blender masters before copying into the app.

Approved app filenames remain:

- `Frontend/mobile/assets/images/milestones/box_reveal_atlas.webp`
- `Frontend/mobile/assets/images/milestones/box_reveal_poster.webp`
- `Frontend/mobile/assets/images/milestones/box_reveal.json`

The app draws a full dark stage and spotlight while the gift holds and shakes.
At about two seconds, the separated panels release the dynamic medal, and the
app brightens the stage. The app owns the medal artwork/earned number/rank,
full-screen saturated confetti, copy and Keep exploring control. Those overlays
are never baked into the atlas. The current app reveal lasts seven seconds:
four seconds of this box track plus three seconds for confetti to settle.

The manifest carries normalized `boxAnchor`, `floorAnchor`, and `badgeAnchor`
in the square frame, plus `timings`. Playback ends on frame 79; reduced motion
loads only the same loose-pieces final poster. Lifecycle handling, stage shadow,
reduced-motion transitions and runtime cleanup remain Flutter responsibilities.

## Render and review

From the repository root, while the coordinator reserves the Blender lane:

```sh
/Applications/Blender.app/Contents/MacOS/Blender -b -t 4 --python Motion/level-milestone-gift-v2/source/build_gift.py -- --review
/Applications/Blender.app/Contents/MacOS/Blender -b -t 4 --python Motion/level-milestone-gift-v2/source/build_gift.py -- --runtime
/Users/macbook/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 Motion/level-milestone-gift-v2/source/package_gift.py
/opt/homebrew/bin/ffmpeg -y -framerate 20 -i Motion/level-milestone-gift-v2/review/motion-%03d.jpg -c:v libx264 -crf 18 -pix_fmt yuv420p -movflags +faststart Motion/level-milestone-gift-v2/review/gift-motion-proof.mp4
```

`review/gift-closed.png` is the large portrait concept still. The transparent
square stills show uncropped component framing. `review/gift-contact-sheet.jpg`
and `gift-motion-proof.mp4` show the final approved motion. Portrait burst stills
are early lighting studies and crop some outer paper; they are not runtime art.
