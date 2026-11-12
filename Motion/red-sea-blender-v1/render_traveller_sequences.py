"""Export native keyed traveller poses at explicit Blender frame numbers."""
import bpy,json,math
from pathlib import Path
from mathutils import Vector
from bpy_extras.object_utils import world_to_camera_view
ROOT=Path(__file__).resolve().parent
bpy.ops.wm.open_mainfile(filepath=str(ROOT/'red-sea-characters.blend'))
scene=bpy.context.scene;scene.render.resolution_x=128;scene.render.resolution_y=192
metadata=json.loads((ROOT/'character-source-manifest.json').read_text())
for idx in range(3):
    rig=bpy.data.objects[f'Traveller {idx} armature']
    H=rig.data.bones['head'].tail_local.z
    cam=scene.camera;cam.data.ortho_scale=H*1.24
    target=Vector((0,0,H*.535));cam.location=(3.7,-6,1.9+H*.48)
    cam.rotation_euler=(target-cam.location).to_track_quat('-Z','Y').to_euler()
    for obj in bpy.data.objects:
        if obj.type not in ('LIGHT','CAMERA'):
            obj.hide_render=obj.get('character_role','')!=f'traveller_{idx}'
    bpy.context.view_layer.update()
    foot=world_to_camera_view(scene,cam,Vector((0,0,.015)))
    head=world_to_camera_view(scene,cam,Vector((0,0,H)))
    anchor=[round(foot.x*128,3),round((1-foot.y)*192,3)]
    height=round((head.y-foot.y)*192,3)
    for frame in (1,9,15,21,27):
        scene.frame_set(frame)
        print('NATIVE_POSE',idx,frame,tuple(rig.rotation_euler),tuple(rig.pose.bones['calf_l'].tail),flush=True)
        expected=0 if frame==1 else math.pi
        if abs(rig.rotation_euler.z-expected)>.01:
            raise RuntimeError(f'Native traveller {idx} pose {frame} has wrong orientation')
    for label,frame in [('idle',1),('walk',15)]:
        scene.frame_set(frame)
        scene.render.filepath=str(ROOT/f'review/traveller-{idx}-{label}-checkpoint.png')
        bpy.ops.render.render(write_still=True)
    for clip,count,duration,loop in [('idle',1,1.0,False),('turn',8,.38,False),('walk',24,.9,True),('back',1,1.0,False)]:
        name=f'traveller_{idx}_{clip}';out=ROOT/f'frames/{name}';out.mkdir(parents=True,exist_ok=True)
        metadata['clips'][name]={'frames':f'frames/{name}/*.png','frameCount':count,'durationSeconds':duration,'loop':loop,'footAnchor':anchor,'bodyHeight':height}
        for i in range(count):
            frame=i+1 if clip=='turn' else i+9 if clip=='walk' else 9 if clip=='back' else 1
            scene.frame_set(frame)
            scene.render.filepath=str(out/f'{i:03}.png')
            bpy.ops.render.render(write_still=True)
    print('TRAVELLER_EXPORTED',idx,anchor,height,flush=True)
for name,count in [('moses_ready',1),('moses_action',63)]:metadata['clips'][name]['frameCount']=count
(ROOT/'character-source-manifest.json').write_text(json.dumps(metadata,indent=2)+'\n')
print('NATIVE_TRAVELLER_EXPORT_COMPLETE',flush=True)
