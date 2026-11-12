"""Native mesh/armature scene from CC0 MakeHuman assets; no image warping."""
import bpy,sys,math,random,json
from pathlib import Path
from mathutils import Vector,Matrix
ROOT=Path(__file__).resolve().parent
sys.path.insert(0,str(ROOT/'source-assets/mpfb2/src'))
old_extension_path=bpy.utils.extension_path_user
def extension_path(package,*,path='',create=False):
    if package=='mpfb':
        dest=ROOT/'source-assets/mpfb-user'/path
        if create:dest.mkdir(parents=True,exist_ok=True)
        return str(dest)
    return old_extension_path(package,path=path,create=create)
bpy.utils.extension_path_user=extension_path
import addon_utils
addon_utils.enable('mpfb',default_set=True)
from mpfb.services.humanservice import HumanService
from mpfb.services.targetservice import TargetService

def mat(name,color,rough=.65):
    m=bpy.data.materials.new(name);m.use_nodes=True
    s=m.node_tree.nodes.get('Principled BSDF');s.inputs['Base Color'].default_value=(*color,1);s.inputs['Roughness'].default_value=rough
    return m
def fabric(name,color):
    m=mat(name,color,.9);n=m.node_tree.nodes;l=m.node_tree.links
    tex=n.new('ShaderNodeTexNoise');tex.inputs['Scale'].default_value=180;tex.inputs['Detail'].default_value=2
    bump=n.new('ShaderNodeBump');bump.inputs['Strength'].default_value=.22;bump.inputs['Distance'].default_value=.003
    l.new(tex.outputs['Fac'],bump.inputs['Height']);l.new(bump.outputs['Normal'],n.get('Principled BSDF').inputs['Normal'])
    return m
def mesh(name,vertices,faces,material):
    me=bpy.data.meshes.new(name);me.from_pydata(vertices,[],faces);me.update()
    ob=bpy.data.objects.new(name,me);bpy.context.collection.objects.link(ob);ob.data.materials.append(material)
    for p in me.polygons:p.use_smooth=True
    return ob
def rigid_bind(ob,rig,bone):
    ob.parent=rig;g=ob.vertex_groups.new(name=bone);g.add(list(range(len(ob.data.vertices))),1,'REPLACE')
    mod=ob.modifiers.new('Skeletal deformation','ARMATURE');mod.object=rig
def curve(name,coords,bevel,material):
    cu=bpy.data.curves.new(name,'CURVE');cu.dimensions='3D';cu.resolution_u=8;cu.bevel_depth=bevel;cu.bevel_resolution=3
    sp=cu.splines.new('BEZIER');sp.bezier_points.add(len(coords)-1)
    for p,co in zip(sp.bezier_points,coords):p.co=co;p.handle_left_type='AUTO';p.handle_right_type='AUTO'
    ob=bpy.data.objects.new(name,cu);bpy.context.collection.objects.link(ob);cu.materials.append(material)
    return ob
def bone_curve(name,coords,bevel,material,rig,bone):
    ob=curve(name,coords,bevel,material)
    bpy.context.view_layer.objects.active=ob;ob.select_set(True);bpy.ops.object.convert(target='MESH');ob.select_set(False)
    rigid_bind(ob,rig,bone);return ob
def bone_direction(rig,name,head,tail):
    pb=rig.pose.bones[name];rest=pb.bone.matrix_local
    q=(rest.to_3x3()@Vector((0,1,0))).rotation_difference(Vector(tail)-Vector(head))
    pb.matrix=Matrix.Translation(Vector(head))@q.to_matrix().to_4x4()@rest.to_3x3().to_4x4()
    bpy.context.view_layer.update()
def arm(rig,side,hand,elbow):
    shoulder=rig.data.bones['upperarm_'+side].head_local.copy();hand=Vector(hand)
    upper=rig.data.bones['upperarm_'+side].length;lower=rig.data.bones['lowerarm_'+side].length
    axis=(hand-shoulder);distance=min(axis.length,upper+lower-.002);axis.normalize();hand=shoulder+axis*distance
    pole=Vector(elbow)-shoulder;pole-=axis*pole.dot(axis);pole.normalize()
    along=(upper*upper-lower*lower+distance*distance)/(2*distance)
    elbow=shoulder+axis*along+pole*math.sqrt(max(0,upper*upper-along*along))
    bone_direction(rig,'upperarm_'+side,shoulder,elbow)
    bone_direction(rig,'lowerarm_'+side,elbow,hand)
    return hand
def light(name,loc,energy,color,size):
    data=bpy.data.lights.new(name,'AREA');data.energy=energy;data.color=color;data.shape='DISK';data.size=size
    ob=bpy.data.objects.new(name,data);bpy.context.collection.objects.link(ob);ob.location=loc;ob.rotation_euler=(Vector((0,0,1))-ob.location).to_track_quat('-Z','Y').to_euler()
def camera(loc,target,ortho,res):
    data=bpy.data.cameras.new('Character camera');data.type='ORTHO';data.ortho_scale=ortho
    ob=bpy.data.objects.new('Character camera',data);bpy.context.collection.objects.link(ob);ob.location=loc;ob.rotation_euler=(Vector(target)-ob.location).to_track_quat('-Z','Y').to_euler();bpy.context.scene.camera=ob
    bpy.context.scene.render.resolution_x=res[0];bpy.context.scene.render.resolution_y=res[1]
    return ob

bpy.ops.object.select_all(action='SELECT');bpy.ops.object.delete(use_global=False)
scene=bpy.context.scene;scene.render.engine='BLENDER_EEVEE_NEXT';scene.render.image_settings.file_format='PNG';scene.render.image_settings.color_mode='RGBA';scene.render.film_transparent=True
scene.render.resolution_percentage=100;scene.render.fps=24;scene.world.color=(.08,.1,.14)
scene.view_settings.view_transform='AgX';scene.view_settings.look='AgX - Medium High Contrast'
scene.eevee.taa_render_samples=48

macro=TargetService.get_default_macro_info_dict();macro.update(gender=1.0,age=.91,muscle=.42,weight=.47)
macro['race']={'african':1.0,'asian':0.0,'caucasian':0.0}
human=HumanService.create_human(macro_detail_dict=macro);human.name='Moses anatomical body'
rig=HumanService.add_builtin_rig(human,'game_engine');rig.name='Moses armature'
system=ROOT/'source-assets/system'
skinpath=system/'skins/old_african_male/old_african_male.mhmat'
if skinpath.exists():
    HumanService.set_character_skin(str(skinpath),human,skin_type='MAKESKIN')
else:
    skin=mat('Warm dark brown skin',(.16,.06,.028),.5);skin.node_tree.nodes.get('Principled BSDF').inputs['Subsurface Weight'].default_value=.07
    human.data.materials.clear();human.data.materials.append(skin)
for p in human.data.polygons:p.use_smooth=True
sub=human.modifiers.new('Anatomical surface','SUBSURF');sub.levels=1;sub.render_levels=1

eyepath=system/'eyes/low-poly/low-poly.mhclo'
if not eyepath.exists():eyepath=ROOT/'source-assets/eyes-low-poly/low-poly.mhclo'
eyes=HumanService.add_mhclo_asset(str(eyepath),human,asset_type='Eyes',subdiv_levels=1)
if not eyes.data.materials:
    eyes.data.materials.append(mat('Warm eye sclera',(.52,.42,.31),.32))

robe=HumanService.add_mhclo_asset(str(ROOT/'source-assets/dress01/clothes/mindfront_kimono/mindfront_kimono.mhclo'),human,asset_type='Clothes',subdiv_levels=1)
robe.name='Moses continuous woven robe'
purple=fabric('Deep grape woven outer robe',(.18,.07,.27));cream=fabric('Warm ivory tunic panels',(.62,.48,.28));red=fabric('Terracotta sash',(.29,.025,.020));leather=mat('Weathered leather',(.055,.025,.012),.85)
robe.data.materials.clear();robe.data.materials.append(purple);robe.data.materials.append(cream)
# Define the tunic/coat edge with an interpolated rest-position attribute. This
# retains cloth folds and a clean seam independent of the imported polygon grid.
att=robe.data.attributes.new('cloth_rest_position','FLOAT_VECTOR','POINT')
for i,v in enumerate(robe.data.vertices):att.data[i].vector=v.co
nodes=purple.node_tree.nodes;links=purple.node_tree.links
attribute=nodes.new('ShaderNodeAttribute');attribute.attribute_name='cloth_rest_position'
sep=nodes.new('ShaderNodeSeparateXYZ');links.new(attribute.outputs['Vector'],sep.inputs['Vector'])
absolute=nodes.new('ShaderNodeMath');absolute.operation='ABSOLUTE';links.new(sep.outputs['X'],absolute.inputs[0])
xmask=nodes.new('ShaderNodeMath');xmask.operation='LESS_THAN';xmask.inputs[1].default_value=.113;links.new(absolute.outputs[0],xmask.inputs[0])
ymask=nodes.new('ShaderNodeMath');ymask.operation='LESS_THAN';ymask.inputs[1].default_value=-.06;links.new(sep.outputs['Y'],ymask.inputs[0])
mixmask=nodes.new('ShaderNodeMath');mixmask.operation='MULTIPLY';links.new(xmask.outputs[0],mixmask.inputs[0]);links.new(ymask.outputs[0],mixmask.inputs[1])
mix=nodes.new('ShaderNodeMixRGB');mix.blend_type='MIX';mix.inputs[1].default_value=(.18,.07,.27,1);mix.inputs[2].default_value=(.62,.48,.28,1)
links.new(mixmask.outputs[0],mix.inputs[0]);links.new(mix.outputs[0],nodes.get('Principled BSDF').inputs['Base Color'])
# Tint the original cloth belt and knot red, excluding the wide sleeves.
zlow=nodes.new('ShaderNodeMath');zlow.operation='GREATER_THAN';zlow.inputs[1].default_value=1.025;links.new(sep.outputs['Z'],zlow.inputs[0])
zhi=nodes.new('ShaderNodeMath');zhi.operation='LESS_THAN';zhi.inputs[1].default_value=1.12;links.new(sep.outputs['Z'],zhi.inputs[0])
central=nodes.new('ShaderNodeMath');central.operation='LESS_THAN';central.inputs[1].default_value=.27;links.new(absolute.outputs[0],central.inputs[0])
zb=nodes.new('ShaderNodeMath');zb.operation='MULTIPLY';links.new(zlow.outputs[0],zb.inputs[0]);links.new(zhi.outputs[0],zb.inputs[1])
zb2=nodes.new('ShaderNodeMath');zb2.operation='MULTIPLY';links.new(zb.outputs[0],zb2.inputs[0]);links.new(central.outputs[0],zb2.inputs[1])
redmix=nodes.new('ShaderNodeMixRGB');redmix.inputs[2].default_value=(.29,.025,.020,1);links.new(zb2.outputs[0],redmix.inputs[0]);links.new(mix.outputs[0],redmix.inputs[1]);links.new(redmix.outputs[0],nodes.get('Principled BSDF').inputs['Base Color'])
for p in robe.data.polygons:p.material_index=0
for v in robe.data.vertices:
    if v.co.z<.25:v.co.z=.25+(v.co.z-.25)*.22
# A continuous inset with an actual smooth boundary, rather than polygon paint.
verts=[];faces=[];N=16;R=26
for j in range(R+1):
    f=j/R;z=1.51-.28*f;w=.079+.018*math.sin(math.pi*f/2)
    front=-.100-.052*math.sin(math.pi*f/2)
    for i in range(N+1):
        u=-1+2*i/N
        verts.append((w*u,front+.027*u*u-.0035*math.sin(u*math.pi*5)*(f+.2),z+.005*math.sin(i*.8)*f))
for j in range(R):
    for i in range(N):faces.append((j*(N+1)+i,j*(N+1)+i+1,(j+1)*(N+1)+i+1,(j+1)*(N+1)+i))
panel=mesh('Continuous cream tunic inset',verts,faces,cream)
rigid_bind(panel,rig,'spine_01');panel.modifiers.new('Tunic smooth cloth','SUBSURF').levels=1
panel.modifiers.new('Cloth thickness','SOLIDIFY').thickness=.006

# Modelled sash with broad cloth tails, fixed to the pelvis/spine rather than loose parts.
verts=[];faces=[];n=64
for z in (1.026,1.102):
    for i in range(n):
        a=2*math.pi*i/n;verts.append((.236*math.cos(a),.199*math.sin(a)+.015,z))
for i in range(n):faces.append((i,(i+1)%n,(i+1)%n+n,i+n))
belt=mesh('Woven red waist sash',verts,faces,red);rigid_bind(belt,rig,'spine_01')
sol=belt.modifiers.new('Cloth thickness','SOLIDIFY');sol.thickness=.009
tail=mesh('Falling sash cloth',[(-.105,-.222,1.06),(-.036,-.226,1.06),(-.031,-.230,.53),(-.100,-.228,.51),(-.104,-.229,.77),(-.033,-.232,.77)],[(0,1,5,4),(4,5,2,3)],red);rigid_bind(tail,rig,'pelvis');s=tail.modifiers.new('Cloth thickness','SOLIDIFY');s.thickness=.01;b=tail.modifiers.new('Soft cloth edges','BEVEL');b.width=.012;b.segments=3

# Grey curls and a contoured beard: native meshes and strands anchored to the head.
hairpath=system/'hair/short02/short02.mhclo'
if hairpath.exists():
    hair=HumanService.add_mhclo_asset(str(hairpath),human,asset_type='Hair',subdiv_levels=1)
    hairmat=fabric('Salt and pepper hair',(.21,.22,.20))
    # Preserve the authored hair-card alpha and use a grey tint on its real strands.
    for material in hair.data.materials:
        n=material.node_tree.nodes;l=material.node_tree.links;bsdf=next((a for a in n if a.type=='BSDF_PRINCIPLED'),None)
        if bsdf:
            links=list(bsdf.inputs['Base Color'].links)
            if links:
                socket=links[0].from_socket;l.remove(links[0]);bw=n.new('ShaderNodeRGBToBW');ramp=n.new('ShaderNodeValToRGB')
                ramp.color_ramp.elements[0].color=(.12,.13,.12,1);ramp.color_ramp.elements[1].color=(.65,.64,.58,1)
                l.new(socket,bw.inputs['Color']);l.new(bw.outputs['Val'],ramp.inputs['Fac']);l.new(ramp.outputs['Color'],bsdf.inputs['Base Color'])
else:
    hairmat=fabric('Salt and pepper hair',(.21,.22,.20))
    verts=[];faces=[];N=40;R=12
    for j in range(R+1):
        t=.03+(math.pi*.66-.03)*j/R
        for i in range(N):
            a=2*math.pi*i/N;rr=1+.025*math.sin(i*1.8+j*3.1)
            verts.append((.111*math.sin(t)*math.cos(a)*rr,.015+.112*math.sin(t)*math.sin(a)*rr,1.693+.118*math.cos(t)*rr))
    for j in range(R):
        for i in range(N):faces.append((j*N+i,j*N+(i+1)%N,(j+1)*N+(i+1)%N,(j+1)*N+i))
    hair=mesh('Sculpted grey curl cap',verts,faces,hairmat);rigid_bind(hair,rig,'head')
beardmat=fabric('Silver beard',(.45,.43,.36))
verts=[];faces=[];N=36;R=16
for j in range(R+1):
    f=j/R
    for i in range(N+1):
        a=-1.66+3.32*i/N
        x=.092*math.sin(a)*(1-.25*f)
        y=-.060-.074*math.cos(a)*(1-.34*f)
        z=1.583-.153*f+.024*math.sin(a)**2*(1-f)+.045*math.sin(a)**2*f
        ripple=.0035*math.sin(i*2.1+j*1.7)
        verts.append((x,y+ripple,z))
for j in range(R):
    for i in range(N):faces.append((j*(N+1)+i,j*(N+1)+i+1,(j+1)*(N+1)+i+1,(j+1)*(N+1)+i))
beard=mesh('Contoured full elder beard',verts,faces,beardmat);rigid_bind(beard,rig,'head');beard.modifiers.new('Beard soft surface','SUBSURF').levels=1
random.seed(16)
for i in range(90):
    a=random.uniform(-1.30,1.30);f=random.uniform(.02,.65);x=.092*math.sin(a)*(1-.25*f);y=-.060-.074*math.cos(a)*(1-.34*f)-.004;z=1.583-.153*f+.024*math.sin(a)**2*(1-f)+.045*math.sin(a)**2*f
    bone_curve('Beard curled strand',[(x,y,z),(x*.94,y-.004,z-.021),(x*.84,y+.003,z-.043)],.0018,beardmat,rig,'head')
for side in (-1,1):
    bone_curve('Silver moustache',[(side*.005,-.151,1.604),(side*.034,-.146,1.602),(side*.059,-.119,1.591)],.012,beardmat,rig,'head')
    bone_curve('Elder eyebrow',[(side*.025,-.108,1.699),(side*.053,-.11,1.706),(side*.079,-.091,1.696)],.005,hairmat,rig,'head')

# Thick crooked staff, held by the anatomical hand. Grip is authored with arm bones.
wood=mat('Carved warm brown wood',(.19,.078,.018),.78)
staff=curve('Moses wooden staff',[(0,0,-1.105),(0,0,.38),(.02,0,.68),(-.02,0,.91),(-.07,0,.93),(-.10,0,.85)],.018,wood)
staff.parent=rig
hand=arm(rig,'r',(-.34,-.26,1.21),(-.44,-.04,1.255))
bone_direction(rig,'hand_r',hand,hand+Vector((0,-.006,-.03)))
staff.location=hand+Vector((-.015,-.073,-.055))
arm(rig,'l',(.355,-.115,1.035),(.47,.005,1.26))
for side in ('r','l'):
    for finger in ('index','middle','ring','pinky'):
        for seg in ('01','02','03'):
            pb=rig.pose.bones[f'{finger}_{seg}_{side}'];pb.rotation_mode='XYZ';pb.rotation_euler[0]=.95 if side=='r' else .12
    thumb=rig.pose.bones['thumb_01_'+side];thumb.rotation_mode='XYZ';thumb.rotation_euler[2]=-.6 if side=='r' else 0
bpy.context.view_layer.update()
grip=sum((rig.pose.bones[f'{f}_{s}_r'].head for f in ('index','middle','ring') for s in ('01','03')),Vector())/6
staff.location=grip

# Sandal soles and broad leather straps conform to each anatomical foot.
leather=mat('Weathered sandal leather',(.055,.025,.012),.85)
for side,sign in (('l',1),('r',-1)):
    foot=rig.data.bones['foot_'+side].head_local;x=foot.x
    verts=[];faces=[];N=36
    for z in (.005,.024):
        for i in range(N):
            a=2*math.pi*i/N;w=.058*(1+.14*max(0,-math.sin(a)));verts.append((x+w*math.cos(a),-.090+.129*math.sin(a),z))
    for i in range(N):faces.append((i,(i+1)%N,(i+1)%N+N,i+N))
    faces.append(tuple(range(N,2*N)))
    sole=mesh('Leather sandal sole '+side,verts,faces,leather);rigid_bind(sole,rig,'foot_'+side)
    b=sole.modifiers.new('Soft leather edge','BEVEL');b.width=.009;b.segments=3
    coords=[(x-.057,-.074,.032),(x-.043,-.082,.068),(x,-.088,.085),(x+.043,-.082,.068),(x+.057,-.074,.032)]
    bone_curve('Broad sandal strap '+side,coords,.013,leather,rig,'foot_'+side)

light('Warm sun key',(3,-4,5),520,(1,.81,.60),4)
light('Sea blue fill',(-4,-1,3),340,(.46,.69,1),4)
light('Golden edge',(1,3,4),750,(1,.78,.5),3)
cam=camera((-3.7,-6.0,3.1),(0,0,1.05),2.6,(640,800))
review=ROOT/'review';review.mkdir(exist_ok=True)
bpy.context.view_layer.update()
bpy.ops.wm.save_as_mainfile(filepath=str(ROOT/'red-sea-characters.blend'))
scene.render.filepath=str(review/'moses-first-detail.png');bpy.ops.render.render(write_still=True)
print('REVIEW_STILL',scene.render.filepath)
