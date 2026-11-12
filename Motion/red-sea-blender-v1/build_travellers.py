"""Three coherent dark-skinned travellers, authored cloth and anatomical gait."""
import bpy,math,sys,json,ast
from pathlib import Path
from mathutils import Vector,Matrix
from bpy_extras.object_utils import world_to_camera_view
ROOT=Path(__file__).resolve().parent
# Reuse the original modelling helpers and initialize MPFB without rerunning Moses.
tree=ast.parse((ROOT/'build_characters.py').read_text())
prefix=[]
for node in tree.body:
    if isinstance(node,ast.Expr) and isinstance(node.value,ast.Call) and getattr(node.value.func,'attr',None)=='select_all':break
    prefix.append(node)
exec(compile(ast.Module(body=prefix,type_ignores=[]),'character_helpers','exec'))
bpy.ops.wm.open_mainfile(filepath=str(ROOT/'red-sea-characters.blend'))
scene=bpy.context.scene;system=ROOT/'source-assets/system';scene.render.resolution_x=128;scene.render.resolution_y=192
for obj in list(bpy.data.objects):
    if str(obj.get('character_role','')).startswith('traveller_'):
        bpy.data.objects.remove(obj,do_unlink=True)
known=set(bpy.data.objects);characters=[]
for idx,(gender,age,color,hairname) in enumerate([(1.0,.48,(.28,.12,.026),'afro01'),(0.0,.47,(.025,.20,.19),'afro01'),(1.0,.20,(.26,.06,.09),'short02')]):
    macro=TargetService.get_default_macro_info_dict();macro.update(gender=gender,age=age,muscle=.38,weight=.43)
    macro['race']={'african':1.0,'asian':0.0,'caucasian':0.0}
    human=HumanService.create_human(macro_detail_dict=macro);human.name=f'Traveller {idx} anatomical body'
    rig=HumanService.add_builtin_rig(human,'game_engine');rig.name=f'Traveller {idx} armature'
    sex='male' if gender>.5 else 'female'
    HumanService.set_character_skin(str(system/f'skins/young_african_{sex}/young_african_{sex}.mhmat'),human,skin_type='MAKESKIN')
    for p in human.data.polygons:p.use_smooth=True
    mod=human.modifiers.new('Continuous anatomical surface','SUBSURF');mod.levels=1;mod.render_levels=1
    eyes=HumanService.add_mhclo_asset(str(system/'eyes/low-poly/low-poly.mhclo'),human,asset_type='Eyes',subdiv_levels=1)
    robe=HumanService.add_mhclo_asset(str(ROOT/'source-assets/dress01/clothes/mindfront_kimono/mindfront_kimono.mhclo'),human,asset_type='Clothes',subdiv_levels=1);robe.name=f'Traveller {idx} woven robe'
    hair=HumanService.add_mhclo_asset(str(system/f'hair/{hairname}/{hairname}.mhclo'),human,asset_type='Hair',subdiv_levels=1)
    H=rig.data.bones['head'].tail_local.z;scale=H/1.80
    # Native continuous cloth, cropped above ankles to allow visible strides.
    for v in robe.data.vertices:
        if v.co.z<.24*scale:v.co.z=.24*scale+(v.co.z-.24*scale)*.18
    garment=fabric(f'Traveller {idx} woven cloth',color);robe.data.materials.clear();robe.data.materials.append(garment)
    att=robe.data.attributes.new('cloth_rest_position','FLOAT_VECTOR','POINT')
    for i,v in enumerate(robe.data.vertices):att.data[i].vector=v.co
    n=garment.node_tree.nodes;l=garment.node_tree.links;attn=n.new('ShaderNodeAttribute');attn.attribute_name='cloth_rest_position';sep=n.new('ShaderNodeSeparateXYZ');l.new(attn.outputs['Vector'],sep.inputs['Vector'])
    low=n.new('ShaderNodeMath');low.operation='GREATER_THAN';low.inputs[1].default_value=1.025*scale;l.new(sep.outputs['Z'],low.inputs[0])
    high=n.new('ShaderNodeMath');high.operation='LESS_THAN';high.inputs[1].default_value=1.12*scale;l.new(sep.outputs['Z'],high.inputs[0])
    combine=n.new('ShaderNodeMath');combine.operation='MULTIPLY';l.new(low.outputs[0],combine.inputs[0]);l.new(high.outputs[0],combine.inputs[1])
    absx=n.new('ShaderNodeMath');absx.operation='ABSOLUTE';l.new(sep.outputs['X'],absx.inputs[0])
    beltwidth=n.new('ShaderNodeMath');beltwidth.operation='LESS_THAN';beltwidth.inputs[1].default_value=.265*scale;l.new(absx.outputs[0],beltwidth.inputs[0])
    beltmask=n.new('ShaderNodeMath');beltmask.operation='MULTIPLY';l.new(combine.outputs[0],beltmask.inputs[0]);l.new(beltwidth.outputs[0],beltmask.inputs[1])
    mix=n.new('ShaderNodeMixRGB');mix.inputs[1].default_value=(*color,1);mix.inputs[2].default_value=(.52,.38,.20,1);l.new(beltmask.outputs[0],mix.inputs[0]);l.new(mix.outputs[0],n.get('Principled BSDF').inputs['Base Color'])
    leather=mat(f'Traveller {idx} sandal leather',(.055,.027,.013),.85)
    for side in ('l','r'):
        foot=rig.data.bones['foot_'+side].head_local;x=foot.x;y=foot.y
        verts=[];faces=[];N=24
        for z in (.005*scale,.023*scale):
            for k in range(N):
                a=2*math.pi*k/N;w=.058*scale*(1+.14*max(0,-math.sin(a)));verts.append((x+w*math.cos(a),y-.080*scale+.125*scale*math.sin(a),z))
        for k in range(N):faces.append((k,(k+1)%N,(k+1)%N+N,k+N))
        faces.append(tuple(range(N,2*N)));sole=mesh(f'Traveller {idx} sandal {side}',verts,faces,leather);rigid_bind(sole,rig,'foot_'+side)
        bone_curve(f'Traveller {idx} sandal strap {side}',[(x-.057*scale,y-.071*scale,.027*scale),(x-.041*scale,y-.078*scale,.067*scale),(x,y-.08*scale,.08*scale),(x+.041*scale,y-.078*scale,.067*scale),(x+.057*scale,y-.071*scale,.027*scale)],.011*scale,leather,rig,'foot_'+side)
    new=set(bpy.data.objects)-known
    for obj in new:obj['character_role']=f'traveller_{idx}'
    known=set(bpy.data.objects)
    characters.append((idx,rig,human,H,scale,new))

def bone_dir(rig,name,head,tail):
    pb=rig.pose.bones[name];rest=pb.bone.matrix_local;q=(rest.to_3x3()@Vector((0,1,0))).rotation_difference(Vector(tail)-Vector(head))
    pb.matrix=Matrix.Translation(Vector(head))@q.to_matrix().to_4x4()@rest.to_3x3().to_4x4();bpy.context.view_layer.update()
def leg(rig,side,ankle,pole):
    s=rig.pose.bones['thigh_'+side].head.copy();h=Vector(ankle);L=rig.data.bones['thigh_'+side].length;M=rig.data.bones['calf_'+side].length
    d=h-s;dist=min(d.length,L+M-.0005);d.normalize();h=s+d*dist;p=Vector(pole)-s;p-=d*p.dot(d);p.normalize();a=(L*L-M*M+dist*dist)/(2*dist);k=s+d*a+p*math.sqrt(max(0,L*L-a*a))
    bone_dir(rig,'thigh_'+side,s,k);bone_dir(rig,'calf_'+side,k,h)
    rest=rig.data.bones['foot_'+side];bone_dir(rig,'foot_'+side,h,h+(rest.tail_local-rest.head_local))
def gait(rig,scale,phase):
    for pb in rig.pose.bones:pb.matrix_basis=Matrix.Identity(4)
    wave=math.sin(phase*2*math.pi)
    root=rig.pose.bones['Root'];root.location=(.008*scale*wave,0,.009*scale*abs(math.sin(phase*4*math.pi)))
    pelvis=rig.pose.bones['pelvis'];pelvis.rotation_mode='XYZ';pelvis.rotation_euler=(0,0,.025*wave)
    spine=rig.pose.bones['spine_02'];spine.rotation_mode='XYZ';spine.rotation_euler=(.025,0,-.017*wave)
    bpy.context.view_layer.update()
    for side,sgn in [('l',1),('r',-1)]:
        swing=wave*sgn;rest=rig.data.bones['calf_'+side].tail_local
        ankle=rest+Vector((0,-.105*scale*swing,.046*scale*max(0,swing)))
        leg(rig,side,ankle,(sgn*.16*scale,-.32*scale,.56*scale))
        shoulder=rig.pose.bones['upperarm_'+side].head
        h=(sgn*.285*scale,-.10*scale+.036*scale*swing,shoulder.z-.515*scale)
        wrist=arm(rig,side,h,(sgn*.39*scale,.01*scale,shoulder.z-.26*scale))
        forearm=rig.pose.bones['lowerarm_'+side]
        down=(wrist-forearm.head).normalized()
        bone_dir(rig,'hand_'+side,wrist,wrist+down*.035*scale)
        for finger in ('index','middle','ring','pinky'):
            for seg in ('01','02','03'):
                pb=rig.pose.bones[f'{finger}_{seg}_{side}'];pb.rotation_mode='XYZ';pb.rotation_euler[0]=.16
    bpy.context.view_layer.update()
def show(new):
    for o in bpy.data.objects:
        if o.type not in ('LIGHT','CAMERA'):o.hide_render=o not in new
def setup_cam(H):
    cam=scene.camera;cam.data.ortho_scale=H*1.24;target=Vector((0,0,H*.535));cam.location=(3.7,-6,1.9+H*.48);cam.rotation_euler=(target-cam.location).to_track_quat('-Z','Y').to_euler()
    bpy.context.view_layer.update()
    foot=world_to_camera_view(scene,cam,Vector((0,0,.015)));head=world_to_camera_view(scene,cam,Vector((0,0,H)))
    return [round(foot.x*128,3),round((1-foot.y)*192,3)],round((head.y-foot.y)*192,3)
def keys(rig,frame):
    rig.keyframe_insert(data_path='rotation_euler',frame=frame)
    for pb in rig.pose.bones:
        pb.keyframe_insert(data_path='location',frame=frame);pb.keyframe_insert(data_path='rotation_euler' if pb.rotation_mode=='XYZ' else 'rotation_quaternion',frame=frame);pb.keyframe_insert(data_path='scale',frame=frame)
metadata=json.loads((ROOT/'character-source-manifest.json').read_text());review=ROOT/'review'
for idx,rig,human,H,scale,objects in characters:
    show(objects);rig.rotation_euler[2]=0;gait(rig,scale,0);anchor,height=setup_cam(H)
    scene.render.filepath=str(review/f'traveller-{idx}-idle-checkpoint.png');bpy.ops.render.render(write_still=True)
    rig.rotation_euler[2]=math.pi;gait(rig,scale,.25);scene.render.filepath=str(review/f'traveller-{idx}-walk-checkpoint.png');bpy.ops.render.render(write_still=True)
    for clip,count,duration,loop in [('idle',1,1.0,False),('turn',8,.38,False),('walk',24,.9,True),('back',1,1.0,False)]:
        name=f'traveller_{idx}_{clip}';metadata['clips'][name]={'frames':f'frames/{name}/*.png','frameCount':count,'durationSeconds':duration,'loop':loop,'footAnchor':anchor,'bodyHeight':height}
    for i in range(8):
        rig.rotation_euler[2]=math.pi*(i/7)**2*(3-2*i/7);gait(rig,scale,0);keys(rig,i+1)
    for i in range(25):
        rig.rotation_euler[2]=math.pi;gait(rig,scale,(i%24)/24);keys(rig,i+9)
    if rig.animation_data and rig.animation_data.action:rig.animation_data.action.name=f'Traveller {idx} turn then connected walking cycle'
    if '--render-sequence' in sys.argv:
        for clip,count in [('idle',1),('turn',8),('walk',24),('back',1)]:
            out=ROOT/f'frames/traveller_{idx}_{clip}';out.mkdir(parents=True,exist_ok=True)
            for i in range(count):
                scene.frame_set(i+1 if clip=='turn' else i+9 if clip=='walk' else 9 if clip=='back' else 1)
                if clip=='idle':rig.rotation_euler[2]=0;gait(rig,scale,0)
                elif clip=='turn':rig.rotation_euler[2]=math.pi*(i/7)**2*(3-2*i/7);gait(rig,scale,0)
                else:rig.rotation_euler[2]=math.pi;gait(rig,scale,i/24 if clip=='walk' else 0)
                scene.render.filepath=str(out/f'{i:03}.png');bpy.ops.render.render(write_still=True)
    print('TRAVELLER_COMPLETE',idx,anchor,height,flush=True)
metadata_path=ROOT/'character-source-manifest.json';metadata_path.write_text(json.dumps(metadata,indent=2))
scene.frame_end=63;scene.frame_set(1)
for obj in bpy.data.objects:
    if obj.type not in ('LIGHT','CAMERA'):
        is_traveller=str(obj.get('character_role','')).startswith('traveller_')
        obj.hide_render=is_traveller;obj.hide_set(is_traveller or obj.type=='ARMATURE')
cam=scene.camera;cam.data.ortho_scale=2.95;cam.location=(3.7,-6,3.34)
cam.rotation_euler=(Vector((0,-.04,1.29))-cam.location).to_track_quat('-Z','Y').to_euler()
scene.render.resolution_x=320;scene.render.resolution_y=384
bpy.ops.file.pack_all()
bpy.ops.wm.save_as_mainfile(filepath=str(ROOT/'red-sea-characters.blend'))
print('TRAVELLERS_COMPLETE',flush=True)
