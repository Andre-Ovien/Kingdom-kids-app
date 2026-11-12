"""Prepare a clean editable native scene after the complete frame export."""
import bpy,json
from pathlib import Path
from mathutils import Vector
ROOT=Path(__file__).resolve().parent
bpy.ops.wm.open_mainfile(filepath=str(ROOT/'red-sea-characters.blend'))
scene=bpy.context.scene;scene.frame_set(1)
for obj in bpy.data.objects:
    if obj.type not in ('LIGHT','CAMERA'):
        is_traveller=str(obj.get('character_role','')).startswith('traveller_')
        obj.hide_render=is_traveller
        obj.hide_set(is_traveller or obj.type=='ARMATURE')
cam=scene.camera;cam.data.ortho_scale=2.95;cam.location=(3.7,-6,3.34)
cam.rotation_euler=(Vector((0,-.04,1.29))-cam.location).to_track_quat('-Z','Y').to_euler()
scene.render.resolution_x=320;scene.render.resolution_y=384
bpy.ops.file.pack_all()
bpy.ops.wm.save_as_mainfile(filepath=str(ROOT/'red-sea-characters.blend'))
meta=json.loads((ROOT/'character-source-manifest.json').read_text())
for name,clip in meta['clips'].items():
    clip['frameCount']=len(list(ROOT.glob(clip['frames'])))
    if name.endswith('_ready') or name.endswith('_idle') or name.endswith('_back'):
        clip['durationSeconds']=1.0
(ROOT/'character-source-manifest.json').write_text(json.dumps(meta,indent=2)+'\n')
print('CHARACTER_SOURCE_FINALIZED',len(meta['clips']))
