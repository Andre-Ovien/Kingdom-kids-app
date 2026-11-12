"""Pose the connected MakeHuman skeleton and render anchored Moses sprites."""
import bpy,math,json,sys
from pathlib import Path
from mathutils import Vector,Matrix
from bpy_extras.object_utils import world_to_camera_view
ROOT=Path(__file__).resolve().parent
bpy.ops.wm.open_mainfile(filepath=str(ROOT/'red-sea-characters.blend'))
scene=bpy.context.scene;rig=bpy.data.objects['Moses armature'];staff=bpy.data.objects['Moses wooden staff']
for obj in bpy.data.objects:
    if obj.type not in ('LIGHT','CAMERA'):
        obj.hide_render=str(obj.get('character_role','')).startswith('traveller_')
# Face the separated lane in three-quarter rear view, with a profile of the face.
rig.rotation_euler[2]=math.radians(-145)
staff.data.splines[0].bezier_points[0].co.z=-1.38
def bone_direction(name,head,tail):
    pb=rig.pose.bones[name];rest=pb.bone.matrix_local
    q=(rest.to_3x3()@Vector((0,1,0))).rotation_difference(Vector(tail)-Vector(head))
    pb.matrix=Matrix.Translation(Vector(head))@q.to_matrix().to_4x4()@rest.to_3x3().to_4x4();bpy.context.view_layer.update()
def arm(side,hand,pole):
    shoulder=rig.pose.bones['upperarm_'+side].head.copy();hand=Vector(hand)
    upper=rig.data.bones['upperarm_'+side].length;lower=rig.data.bones['lowerarm_'+side].length
    axis=hand-shoulder;distance=min(axis.length,upper+lower-.002);axis.normalize();hand=shoulder+axis*distance
    p=Vector(pole)-shoulder;p-=axis*p.dot(axis);p.normalize()
    a=(upper*upper-lower*lower+distance*distance)/(2*distance)
    elbow=shoulder+axis*a+p*math.sqrt(max(0,upper*upper-a*a))
    bone_direction('upperarm_'+side,shoulder,elbow);bone_direction('lowerarm_'+side,elbow,hand)
    return hand
def smooth(v):return v*v*v*(v*(v*6-15)+10)
KEYS=[
    (0.0,(-.32,-.22,1.47),(0,0,1),.0),
    (.70,(-.245,-.17,1.755),(0,.05,.999),-.045),
    (1.00,(-.315,-.35,1.29),(0,.60,.80),.062),
    (1.36,(-.33,-.355,1.31),(0,.57,.82),.015),
    (2.10,(-.32,-.36,1.34),(0,.58,.815),.015),
    (2.60,(-.32,-.36,1.34),(0,.58,.815),.015),
]
def pose(t):
    for i in range(len(KEYS)-1):
        if t<=KEYS[i+1][0]:break
    a,b=KEYS[i],KEYS[i+1];f=smooth(max(0,min(1,(t-a[0])/(b[0]-a[0]))))
    hand=Vector(a[1]).lerp(Vector(b[1]),f);direction=Vector(a[2]).lerp(Vector(b[2]),f).normalized();lean=a[3]*(1-f)+b[3]*f
    # Reset each solved pose before applying it, avoiding incremental drift.
    for pb in rig.pose.bones:pb.matrix_basis=Matrix.Identity(4)
    sp=rig.pose.bones['spine_02'];sp.rotation_mode='XYZ';sp.rotation_euler=(lean,0,0)
    head=rig.pose.bones['head'];head.rotation_mode='XYZ';head.rotation_euler=(.014*f,-1.28,0)
    bpy.context.view_layer.update()
    wrist=arm('r',hand,(-.46,.055,1.41))
    bone_direction('hand_r',wrist,wrist-direction*.03)
    arm('l',(.355,-.115-lean*.15,1.035),(.47,.005,1.26))
    for side in ('r','l'):
        for finger in ('index','middle','ring','pinky'):
            for seg in ('01','02','03'):
                pb=rig.pose.bones[f'{finger}_{seg}_{side}'];pb.rotation_mode='XYZ';pb.rotation_euler[0]=.95 if side=='r' else .12
        thumb=rig.pose.bones['thumb_01_'+side];thumb.rotation_mode='XYZ';thumb.rotation_euler[2]=-.6 if side=='r' else 0
    bpy.context.view_layer.update()
    grip=sum((rig.pose.bones[f'{f}_{s}_r'].head for f in ('index','middle','ring') for s in ('01','03')),Vector())/6
    staff.location=grip;staff.rotation_mode='QUATERNION';staff.rotation_quaternion=Vector((0,0,1)).rotation_difference(direction)
    bpy.context.view_layer.update()

cam=scene.camera;cam.data.ortho_scale=2.95
target=Vector((0,-.04,1.29));cam.location=(3.7,-6,3.34);cam.rotation_euler=(target-cam.location).to_track_quat('-Z','Y').to_euler()
scene.render.resolution_x=320;scene.render.resolution_y=384;scene.render.resolution_percentage=100;scene.render.fps=24
scene.frame_start=1;scene.frame_end=63
for i in range(63):
    pose(2.6*i/62);frame=i+1
    for pb in rig.pose.bones:
        pb.keyframe_insert(data_path='location',frame=frame);pb.keyframe_insert(data_path='rotation_euler' if pb.rotation_mode=='XYZ' else 'rotation_quaternion',frame=frame);pb.keyframe_insert(data_path='scale',frame=frame)
    staff.keyframe_insert(data_path='location',frame=frame);staff.keyframe_insert(data_path='rotation_quaternion',frame=frame)
if rig.animation_data and rig.animation_data.action:rig.animation_data.action.name='Moses staff lift sea strike and settle'
pose(0)
foot=world_to_camera_view(scene,cam,rig.matrix_world@Vector((0,-.09,.015)));head=world_to_camera_view(scene,cam,rig.matrix_world@Vector((0,0,1.81)))
anchor=[round(foot.x*320,3),round((1-foot.y)*384,3)];bodyheight=round((head.y-foot.y)*384,3)
clips=json.loads((ROOT/'character-source-manifest.json').read_text()).get('clips',{}) if (ROOT/'character-source-manifest.json').exists() else {}
clips.update({'moses_ready':{'frames':'frames/moses_ready/*.png','frameCount':1,'durationSeconds':1.0,'loop':False,'footAnchor':anchor,'bodyHeight':bodyheight},'moses_action':{'frames':'frames/moses_action/*.png','frameCount':63,'durationSeconds':2.6,'loop':False,'footAnchor':anchor,'bodyHeight':bodyheight}})
(ROOT/'character-source-manifest.json').write_text(json.dumps({'clips':clips},indent=2))
bpy.ops.wm.save_as_mainfile(filepath=str(ROOT/'red-sea-characters.blend'))
review=ROOT/'review';review.mkdir(exist_ok=True)
for name,t in [('ready',0),('raised',.70),('strike',1.0),('final',2.6)]:
    scene.frame_set(round(t/2.6*62)+1);pose(t);scene.render.filepath=str(review/f'moses-{name}-checkpoint.png');bpy.ops.render.render(write_still=True)
    tip=world_to_camera_view(scene,cam,staff.matrix_world@Vector((0,0,-1.38)))
    print('CONTACT',name,'pixel delta from feet',round(tip.x*320-anchor[0],2),round((1-tip.y)*384-anchor[1],2),'world',tuple(staff.matrix_world@Vector((0,0,-1.38))))
print('MOSES_CHECKPOINTS_COMPLETE',anchor,bodyheight)
if '--render-sequence' in sys.argv:
    ready=ROOT/'frames/moses_ready';action=ROOT/'frames/moses_action';ready.mkdir(parents=True,exist_ok=True);action.mkdir(parents=True,exist_ok=True)
    scene.frame_set(1);pose(0);scene.render.filepath=str(ready/'000.png');bpy.ops.render.render(write_still=True)
    for i in range(63):
        scene.frame_set(i+1);pose(2.6*i/62);scene.render.filepath=str(action/f'{i:03}.png');bpy.ops.render.render(write_still=True)
    print('MOSES_FRAMES_COMPLETE')
