# Kai: first 3D motion study

This is an exploratory model and animation made in Blender 4.5.9 LTS. It has
not been integrated into the Flutter app. The original Kai illustration remains
the appearance reference.

The procedural model is an approximation. Its facial proportions, hair,
hands, clothing construction and material detail differ from the illustration.
This is a motion review asset, not a finished production character or a faithful
reconstruction of the original artwork.

The six-second study raises one arm, waves, lowers it, and blinks. The arms use
continuous mesh geometry with an armature modifier and blended vertex weights.
Eyelid surfaces close over unchanged eyeballs. It does not rotate raster cutouts.

## Files

- `kai-motion-study.blend`: editable model, skeleton, animation and lighting.
- `kai-motion-study.mp4`: rendered review movie, 144 frames at 24 fps.
- `kai-motion-study.gif`: smaller looping chat preview.
- `kai-review.png`: Cycles still render of the raised-hand pose.
- `create_kai_study.py`: reproducible scene/model/animation construction.
- `render_preview.py`: EEVEE animation rendering from the saved scene.

## Rebuild on this Mac

```sh
/Applications/Blender.app/Contents/MacOS/Blender --background --python Motion/character-spotlights/blender-kai/create_kai_study.py
/Applications/Blender.app/Contents/MacOS/Blender --background --python Motion/character-spotlights/blender-kai/render_preview.py
ffmpeg -framerate 24 -i Motion/character-spotlights/blender-kai/frames/kai-%04d.png -c:v libx264 -crf 18 -pix_fmt yuv420p -movflags +faststart Motion/character-spotlights/blender-kai/kai-motion-study.mp4
```

Review likeness and motion before commissioning or refining the production
model, making the other two characters, or choosing a mobile playback format.
This preview is a rendered movie; it does not establish interactive 3D support
or mobile performance in the Flutter app.
