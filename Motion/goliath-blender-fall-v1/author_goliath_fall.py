"""Author and bake a constrained fall on the app's faithful native UV rig.
Run: Blender --background --python author_goliath_fall.py [-- --render]
The source character, skin weights, UVs and material ownership come verbatim
from native-rig.json. There is no replacement character or free ragdoll.
"""
import bpy, json, math, pathlib, sys
from mathutils import Vector, Quaternion
OUT=pathlib.Path(__file__).resolve().parent
ROOT=OUT.parents[1]
DATA=json.loads((OUT/'native-rig.json').read_text())
ASPECT=DATA['aspect']; GROUND=DATA['ground']; FPS=120; END=2.4
REST={k:Vector((v[0]*ASPECT,0,1-v[1])) for k,v in DATA['joints'].items()}
bpy.ops.object.select_all(action='SELECT'); bpy.ops.object.delete(use_global=False)
scene=bpy.context.scene; scene.render.fps=FPS; scene.frame_start=1; scene.frame_end=round(END*FPS)+1
scene.render.engine='BLENDER_EEVEE_NEXT'; scene.render.resolution_x=480; scene.render.resolution_y=480; scene.render.resolution_percentage=100
scene.render.image_settings.file_format='PNG'; scene.render.film_transparent=True
scene.view_settings.view_transform='Standard'; scene.view_settings.look='None'; scene.view_settings.exposure=0; scene.view_settings.gamma=1
scene.world.color=(.8,.8,.8)
arm=bpy.data.armatures.new('FaithfulNativeGoliathArmature'); rig=bpy.data.objects.new('Goliath_parented_artwork_rig',arm); scene.collection.objects.link(rig)
bpy.context.view_layer.objects.active=rig; rig.select_set(True); bpy.ops.object.mode_set(mode='EDIT')
parents={'pelvis_control':None,'chest_control':'pelvis_control','pelvis':'pelvis_control','chest':'chest_control','neck':'chest_control','head':'neck','leftUpperArm':'chest_control','leftForearm':'leftUpperArm','leftHand':'leftForearm','rightUpperArm':'chest_control','rightForearm':'rightUpperArm','leftThigh':'pelvis_control','leftShin':'leftThigh','leftFoot':'leftShin','rightThigh':'pelvis_control','rightShin':'rightThigh','rightFoot':'rightShin'}
pairs={'pelvis_control':('pelvis','lumbar'),'chest_control':('lumbar','chest')}
pairs.update({b['name']:(b['from'],b['to']) for b in DATA['bones']})
for name,pair in pairs.items():
    bone=arm.edit_bones.new(name); bone.head=REST[pair[0]]; bone.tail=REST[pair[1]]; bone.align_roll(Vector((0,1,0)))
for name,parent in parents.items():
    if parent: arm.edit_bones[name].parent=arm.edit_bones[parent]
    arm.edit_bones[name].use_connect=name in ['leftForearm','leftHand','rightForearm','leftShin','leftFoot','rightShin','rightFoot']
bpy.ops.object.mode_set(mode='OBJECT'); rig.show_in_front=True
for pb in rig.pose.bones:
    pb.rotation_mode='QUATERNION'
    # One planar hinge axis; no lateral hip/leg translations are authored.
    limit=pb.constraints.new('LIMIT_ROTATION'); limit.name='Anatomical planar hinge'; limit.owner_space='LOCAL'; limit.use_limit_x=True; limit.min_x=limit.max_x=0; limit.use_limit_y=True; limit.min_y=limit.max_y=0
    if 'Thigh' in pb.name: limit.use_limit_z=True; limit.min_z=-.24; limit.max_z=.24
    if 'Shin' in pb.name: limit.use_limit_z=True; limit.min_z=-1.10; limit.max_z=1.10
    if 'Foot' in pb.name: limit.use_limit_z=True; limit.min_z=-.25; limit.max_z=.25
    if 'UpperArm' in pb.name: limit.use_limit_z=True; limit.min_z=-.50; limit.max_z=.50
    if pb.name=='neck': limit.use_limit_z=True; limit.min_z=-.42; limit.max_z=.42
    if pb.name=='head': limit.use_limit_z=True; limit.min_z=-.20; limit.max_z=.20
    if pb.name=='chest_control': limit.use_limit_z=True; limit.min_z=-.12; limit.max_z=.12

def material(name,path):
    mat=bpy.data.materials.new(name); mat.use_nodes=True; n=mat.node_tree.nodes; n.clear()
    output=n.new('ShaderNodeOutputMaterial'); mix=n.new('ShaderNodeMixShader'); clear=n.new('ShaderNodeBsdfTransparent'); emission=n.new('ShaderNodeEmission'); tex=n.new('ShaderNodeTexImage'); tex.image=bpy.data.images.load(str(ROOT/path)); tex.interpolation='Linear'
    links=mat.node_tree.links; links.new(tex.outputs['Color'],emission.inputs['Color']); links.new(tex.outputs['Alpha'],mix.inputs[0]); links.new(clear.outputs[0],mix.inputs[1]); links.new(emission.outputs[0],mix.inputs[2]); links.new(mix.outputs[0],output.inputs['Surface'])
    mat.surface_render_method='DITHERED'; mat.use_transparency_overlap=False
    return mat
original=material('Original angry Goliath artwork',DATA['artwork']); recon=material('Existing hidden-body artwork reconstruction',DATA['reconstruction'])
meshes=[]
for si,section in enumerate(DATA['sections']):
    for kind in ['original','reconstructed']:
        flat=section[kind]
        if not flat or (kind=='reconstructed' and section['shield']): continue
        used=sorted(set(flat)); ids={old:i for i,old in enumerate(used)}
        verts=[(DATA['vertices'][i][0]*ASPECT,-si*.00008,1-DATA['vertices'][i][1]) for i in used]
        triangles=[tuple(ids[i] for i in flat[t:t+3]) for t in range(0,len(flat),3)]
        mesh=bpy.data.meshes.new(f'NativeUV_section_{si}_{kind}'); mesh.from_pydata(verts,[],triangles); mesh.update()
        obj=bpy.data.objects.new(mesh.name,mesh); scene.collection.objects.link(obj); meshes.append(obj)
        uv=mesh.uv_layers.new(name='OriginalArtworkFixedUV')
        for poly in mesh.polygons:
            for li in poly.loop_indices:
                v=DATA['vertices'][used[mesh.loops[li].vertex_index]]; uv.data[li].uv=(v[0],1-v[1])
        obj.data.materials.append(original if kind=='original' else recon)
        for bi,b in enumerate(DATA['bones']):
            group=obj.vertex_groups.new(name=b['name'])
            for vi,old in enumerate(used):
                for idx,weight in DATA['weights'][old]:
                    if idx==bi: group.add([vi],weight,'REPLACE')
        mod=obj.modifiers.new('Exact native linear skin weights','ARMATURE'); mod.object=rig; mod.use_deform_preserve_volume=False
        obj.parent=rig

# Local hinge channels: head leads; knees lose support; hips/chest descend;
# arms remain close to the chest; both thighs remain parented to the pelvis.
# Columns: time, pelvis, chest, neck, head, leftThigh,rightThigh,leftShin,rightShin,leftArm,leftForearm,rightArm,rightForearm,leftFoot,rightFoot.
KEYS=[
(0,0,0,0,0,0,0,0,0,0,0,0,0,0,0),
(.05,0,.006,.018,.075,0,0,0,0,-.006,.015,0,0,0,0),
(.10,.005,.030,.020,.10,.005,-.005,-.01,.01,-.015,.035,.008,-.012,0,0),
(.18,.025,.05,.018,.075,.015,-.015,-.045,.055,-.03,.07,.015,-.025,.01,-.01),
(.35,.13,.065,.008,.045,.09,-.06,-.30,.27,-.08,.16,.03,-.06,.04,-.04),
(.55,.32,.085,.008,.055,.14,-.14,-.50,.40,-.12,.22,.04,-.08,.08,-.06),
(.75,.65,.10,.006,.025,.12,-.10,-.42,.34,-.14,.25,.04,-.10,.08,-.06),
(.95,1.05,.070,.004,.050,.07,-.08,-.46,.46,-.18,-.10,.13,.13,.07,-.05),
(1.14,1.35,.045,.20,.08,.015,-.06,-.55,.78,-.20,-.60,.33,.72,.055,-.05),
(1.28,1.49,.035,.42,.17,0,-.03,-.68,1.02,-.22,-.85,.45,1.40,.045,-.045),
(1.36,1.465,.031,.38,.14,.005,-.032,-.64,.97,-.22,-.85,.45,1.40,.045,-.045),
(1.50,1.50,.024,.40,.16,0,-.025,-.65,1.0,-.20,-.80,.43,1.35,.04,-.04),
(1.72,1.495,.020,.40,.16,0,-.025,-.65,1.0,-.20,-.80,.43,1.35,.04,-.04),
(2.05,1.495,.020,.40,.16,0,-.025,-.65,1.0,-.20,-.80,.43,1.35,.04,-.04),
(2.4,1.495,.020,.40,.16,0,-.025,-.65,1.0,-.20,-.80,.43,1.35,.04,-.04),
]
CHANNELS=['pelvis_control','chest_control','neck','head','leftThigh','rightThigh','leftShin','rightShin','leftUpperArm','leftForearm','rightUpperArm','rightForearm','leftFoot','rightFoot']
# Anatomical knee and elbow hinge signs stay the same on both screen fall sides.
DIRECTIONAL={'pelvis_control','chest_control','neck','head'}
ROOT_BASIS=arm.bones['pelvis_control'].matrix_local.to_3x3().inverted()

def from_source(point): return Vector((point[0]*ASPECT,0,1-point[1]))
def point_on_bone(name,source):
    pb=rig.pose.bones[name]; return pb.matrix @ pb.bone.matrix_local.inverted() @ from_source(source)
def joints_now():
    p=rig.pose.bones
    out={'pelvis':p['pelvis_control'].head.copy(),'lumbar':p['chest_control'].head.copy(),'chest':p['neck'].head.copy(),'neck':p['head'].head.copy(),'head':p['head'].tail.copy(),'leftShoulder':p['chest'].head.copy(),'rightShoulder':p['chest'].tail.copy(),'leftHip':p['pelvis'].head.copy(),'rightHip':p['pelvis'].tail.copy()}
    for side in ['left','right']:
        out[side+'Elbow']=p[side+'UpperArm'].tail.copy(); out[side+'Wrist']=p[side+'Forearm'].tail.copy(); out[side+'Knee']=p[side+'Thigh'].tail.copy(); out[side+'Ankle']=p[side+'Shin'].tail.copy(); out[side+'Toe']=p[side+'Foot'].tail.copy()
    out['leftPalm']=p['leftHand'].tail.copy()
    out['forehead']=point_on_bone('head',DATA['joints']['forehead']); out['shield']=point_on_bone('rightForearm',DATA['joints']['shield'])
    return out

def floor_support():
    joints=joints_now(); overrides={'head','chest','pelvis','shield','leftAnkle','rightAnkle','leftPalm'}
    lowest=min(p.z-DATA['radii'][name] for name,p in joints.items() if name not in overrides)
    for name,outline in DATA['outlines'].items():
        lowest=min(lowest,min(point_on_bone(name,v).z for v in outline))
    return lowest

def author(direction):
    rig.animation_data_clear()
    for pb in rig.pose.bones: pb.rotation_quaternion=Quaternion((1,0,0,0)); pb.location=(0,0,0)
    for row in KEYS:
        frame=1+row[0]*FPS
        for name,angle in zip(CHANNELS,row[1:]):
            pb=rig.pose.bones[name]; pb.rotation_quaternion=Quaternion((0,0,1),angle*(direction if name in DIRECTIONAL else 1)); pb.keyframe_insert(data_path='rotation_quaternion',frame=frame,group=name)
    action=rig.animation_data.action; action.name='Blender_controlled_side_fall_'+('right' if direction>0 else 'left')
    for fc in action.fcurves:
        for key in fc.keyframe_points: key.interpolation='BEZIER'; key.handle_left_type=key.handle_right_type='AUTO_CLAMPED'
    # Contact correction is applied solely to the whole root, never a hip or
    # leg independently. Every pose retains its complete parent hierarchy.
    frames=[]; root=rig.pose.bones['pelvis_control']
    for frame in range(1,scene.frame_end+1):
        scene.frame_set(frame); t=(frame-1)/FPS; root.location=ROOT_BASIS @ Vector((direction*.042*min(1,max(0,(t-.15)/1.13)),0,0)); bpy.context.view_layer.update()
        support=floor_support(); dz=(1-GROUND)-support
        root.location+=ROOT_BASIS @ Vector((0,0,dz)); root.keyframe_insert(data_path='location',frame=frame,group='Whole-body ground support'); bpy.context.view_layer.update()
        j=joints_now(); frames.append([round(value,8) for name in DATA['joints'] for value in (j[name].x/ASPECT,1-j[name].z)])
    for fc in action.fcurves:
        if fc.data_path.endswith('location'):
            for key in fc.keyframe_points: key.interpolation='LINEAR'
    action.use_fake_user=True
    return frames,action

right,right_action=author(1); left,left_action=author(-1)
export={'format':'goliath-blender-baked-joints-v1','blender_version':bpy.app.version_string,'fps':FPS,'duration':END,'settled_at':2.2,'joint_order':list(DATA['joints']),'directions':{'right':right,'left':left},'artwork_unchanged':True,'constraints':'Parented FK armature; limited hinges; whole-root floor support, no independent limb floor displacement'}
(OUT/'blender-fall-joints.json').write_text(json.dumps(export,separators=(',',':')))
# Retain authored controller keys and dense root-support bake in the .blend.
rig.animation_data.action=right_action; scene.frame_set(1)
camdata=bpy.data.cameras.new('NativeArtworkOrthographicCamera'); cam=bpy.data.objects.new('NativeArtworkOrthographicCamera',camdata); scene.collection.objects.link(cam); cam.location=(.36,-4,.51); cam.rotation_euler=(Vector((.36,0,.51))-cam.location).to_track_quat('-Z','Y').to_euler(); camdata.type='ORTHO'; camdata.ortho_scale=1.8; scene.camera=cam
scene['source_rig']='Exact native 2519-vertex artwork mesh, fixed UVs, original weights'; scene['contact_rule']='All collision corrections translate pelvis root; hip/knee/ankle parent chains remain intact'; scene['export_file']='blender-fall-joints.json'; rig['right_action']=right_action.name; rig['left_action']=left_action.name
bpy.ops.wm.save_as_mainfile(filepath=str(OUT/'goliath-controlled-fall.blend'))
print(f'BLENDER_FALL_SAVED {len(right)} samples per direction; {len(meshes)} faithful material islands')
if '--render' in sys.argv:
    scene.render.resolution_x=480; scene.render.resolution_y=480
    for direction,action in [('right',right_action),('left',left_action)]:
        rig.animation_data.action=action
        for time in [0,.35,.75,1.14,1.5,2.2]:
            scene.frame_set(1+round(time*FPS)); scene.render.filepath=str(OUT/f'blender-{direction}-{time:.2f}.png'); bpy.ops.render.render(write_still=True)
