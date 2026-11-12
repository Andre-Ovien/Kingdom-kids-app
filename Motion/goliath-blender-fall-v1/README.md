# Goliath Blender-authored controlled fall

The saved Blender 4.5.9 LTS scene uses the app's existing Goliath illustration, hidden-body reconstruction, exact 2,519-vertex / 3,394-triangle native UV mesh, source ownership and skin weights. The armature parents both hips and their thigh→shin→foot chains to the pelvis; chest, neck, head and arms follow the lumbar hierarchy. Limited hinges and a whole-root ground-support bake produce head reaction, knee buckle, torso descent, contact and a small finite settle. Both shins fold inward into a compact pair of feet. Original character textures and battlefield assets remain unchanged.

`goliath-controlled-fall.blend` retains two authored side-fall actions, their controller keyframes, dense root-contact bake, original textured mesh and orthographic artwork preview camera. `blender-fall-joints.json` contains 120 Hz evaluated Blender joint coordinates. `goliath_blender_fall_track.dart` is the generated 60 Hz mobile track, interpolated with one fraction for the complete skeleton at the existing 120 Hz fixed step. The native model corrects viewport fit and tiny interpolation floor errors by translating the whole body; it never separates a leg from its hip.

The renderer assigns the existing narrow beard/hair rim beside its traced face island to the same rigid head bone. This preserves a few source pixels that previously stayed on the chest when the neck bent; source colors, UVs and artwork are retained.

## Review

- `goliath-blender-native-all-three.mp4`: concise 12-second review, all three real target placements, four seconds per level including landed hold. Original 390×844 native phone frames receive a separate 30-pixel review label below the canvas.
- `all-three-native-contact-sheet.jpg`: standing, knee buckle, contact and landed crops from each actual native level, with original actor size retained.
- `all-three-native-landed.jpg`: full native landed battlefield views, all three levels.
- `native-review/native-review-timings.json`: measured impact, support, settle and completion cues.
- `native-review/level1-*`, `level2-*`, `level3-*`: full unaltered native stills. The real DavidSlingEngine uses the authored production target configurations, real pull/release gestures, production theme and installed Avenir Next font. Completion is recorded by an in-memory callback; this visual capture performs no external writes. Audio is disabled in the capture harness.

## Verification

Final focused Flutter batch: **43 tests passed** across Goliath motion, native mesh and David engine checks. Tests cover fixed-step determinism, pause/resume, exact standing landmarks/colors, finite grounded settling, source-silhouette floor contact, all authored viewport bounds, actual opaque leg/thigh/ankle continuity on both sides, compact landed feet, input/scoring geometry and the existing grounded completion hold. Targeted Dart analysis: **no issues**. The independent 24-run audit covers three authored viewport bounds plus default bounds, both requested sides and three strengths; every case settles with no out-of-bounds joint samples and floor error at floating-point zero. Maximum bone-length interpolation error is about 0.00034 source-image heights.

## Rebuild

Run from the repository root:

```sh
python3 Motion/goliath-blender-fall-v1/export_native_rig.py
/Applications/Blender.app/Contents/MacOS/Blender --background --threads 2 --python Motion/goliath-blender-fall-v1/author_goliath_fall.py -- --render
python3 Motion/goliath-blender-fall-v1/export_dart_track.py
/opt/homebrew/bin/dart format Frontend/mobile/lib/features/games/presentation/goliath_blender_fall_track.dart
/opt/homebrew/bin/dart Motion/goliath-blender-fall-v1/audit_native_motion.dart
```

The review-only Flutter harness is `Frontend/mobile/test/goliath_blender_review_test.dart`; enable it with `GOLIATH_RENDER_REVIEW=true`. Run Flutter commands serially with the other ongoing app work. `package_native_review.py` uses the workspace Python/Pillow runtime and installed FFmpeg to package captured native frames.
