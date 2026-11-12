"""Render the saved motion study at preview resolution, without rebuilding it."""
from pathlib import Path
import sys
import bpy

out = Path(__file__).resolve().parent
bpy.ops.wm.open_mainfile(filepath=str(out / 'kai-motion-study.blend'))
scene = bpy.context.scene
scene.render.engine = 'BLENDER_EEVEE_NEXT'
scene.eevee.taa_render_samples = 32
scene.render.resolution_x = 540
scene.render.resolution_y = 720
scene.render.resolution_percentage = 100
scene.render.image_settings.file_format = 'PNG'
for obj in bpy.data.objects:
    if obj.name.startswith('Eye highlight'):
        obj.location.y = -.568
if '--repair-blinks' in sys.argv:
    bpy.ops.wm.save_as_mainfile(filepath=str(out / 'kai-motion-study.blend'))
    lids = [obj for obj in bpy.data.objects if obj.name.startswith('Upper eyelid')]
    for frame in range(scene.frame_start, scene.frame_end + 1):
        scene.frame_set(frame)
        if max(obj.data.shape_keys.key_blocks['Blink'].value for obj in lids) > .8:
            scene.render.filepath = str(out / 'frames' / f'kai-{frame:04d}.png')
            bpy.ops.render.render(write_still=True)
elif '--still' in sys.argv:
    scene.frame_set(58)
    scene.render.filepath = str(out / 'kai-eevee-review.png')
    bpy.ops.render.render(write_still=True)
else:
    (out / 'frames').mkdir(exist_ok=True)
    scene.render.filepath = str(out / 'frames' / 'kai-')
    bpy.ops.render.render(animation=True)
