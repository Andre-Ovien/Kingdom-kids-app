"""Lively square present: elastic anticipation, two hops, lagged bow, paper pop.

Blender 4.5. Review the 48-frame motion study before any production atlas.
"""
import bpy, math, random, sys, json
from pathlib import Path
from mathutils import Vector

ROOT=Path(__file__).resolve().parent.parent
ARGS=sys.argv[sys.argv.index('--')+1:] if '--' in sys.argv else []
random.seed(914)
bpy.ops.object.select_all(action='SELECT');bpy.ops.object.delete(use_global=False)
scene=bpy.context.scene;scene.render.engine='BLENDER_EEVEE_NEXT'
scene.eevee.taa_render_samples=48
scene.render.image_settings.file_format='PNG';scene.render.image_settings.color_mode='RGBA'
scene.render.resolution_percentage=100;scene.render.fps=24;scene.frame_start=1;scene.frame_end=96
scene.view_settings.view_transform='AgX';scene.view_settings.look='AgX - Medium High Contrast'
scene.world.color=(.035,.055,.08)
def material(name,color,rough=.45,metal=0):
    m=bpy.data.materials.new(name);m.use_nodes=True
    b=m.node_tree.nodes.get('Principled BSDF');b.inputs['Base Color'].default_value=(*color,1);b.inputs['Roughness'].default_value=rough;b.inputs['Metallic'].default_value=metal
    return m
coral=material('Paper / joyous coral',(.86,.17,.085),.57)
mint=material('Paper / contrasting mint',(.045,.47,.31),.52)
gold=material('Ribbon / soft gold fabric',(.93,.53,.10),.30,.46)
gold_back=material('Ribbon / gold reverse',(.65,.34,.04),.47,.25)
cream=material('Paper / ivory cut edges',(.84,.75,.56),.86)
navy=material('Review / midnight stage',(.008,.02,.03),.7)
for mat in [coral,mint,gold]:
    n=mat.node_tree.nodes;l=mat.node_tree.links
    noise=n.new('ShaderNodeTexNoise');noise.inputs['Scale'].default_value=180;noise.inputs['Detail'].default_value=1
    bump=n.new('ShaderNodeBump');bump.inputs['Strength'].default_value=.10;bump.inputs['Distance'].default_value=.0018
    l.new(noise.outputs['Fac'],bump.inputs['Height']);l.new(bump.outputs['Normal'],n.get('Principled BSDF').inputs['Normal'])
def empty(name,loc=(0,0,0),parent=None):
    o=bpy.data.objects.new(name,None);scene.collection.objects.link(o);o.location=loc;o.parent=parent;return o
root=empty('Present / airborne root, foot stays at zero on contact')
def cube(name,loc,dims,mat,bevel=.04,parent=None):
    bpy.ops.mesh.primitive_cube_add(size=1,location=loc);o=bpy.context.object;o.name=name;o.dimensions=dims
    bpy.ops.object.transform_apply(location=False,rotation=False,scale=True)
    o.data.materials.append(mat);o.parent=parent
    if bevel:
        m=o.modifiers.new('Rounded wrapped paper corners','BEVEL');m.width=bevel;m.segments=6
        o.modifiers.new('Clean weighted normals','WEIGHTED_NORMAL')
    return o

# A true cube, with broad soft paper corners and thick contrasting wrapped tape.
body=cube('Present / rounded square wrapped body',(0,0,1.02),(2.04,2.04,2.04),coral,.13,root)
lid=cube('Present / mint top paper',(0,0,2.025),(2.07,2.07,.11),mint,.055,root)
wrap=[]
for side in [-1,1]:
    wrap.append(cube('Ribbon / broad front-back wrap',(0,side*1.045,1.02),(.32,.045,2.02),gold,.017,root))
    wrap.append(cube('Ribbon / broad side wrap',(side*1.045,0,1.02),(.045,.32,2.02),gold,.017,root))
wrap.append(cube('Ribbon / crossing top X',(0,0,2.094),(2.075,.32,.045),gold,.017,root))
wrap.append(cube('Ribbon / crossing top Y',(0,0,2.119),(.32,2.075,.045),gold,.017,root))

# A single lattice deforms connected body/wrap geometry through soft volume
# changes. It does not merely rotate a rigid object to imply anticipation.
ld=bpy.data.lattices.new('Elastic wrapped present cage');ld.points_u=3;ld.points_v=3;ld.points_w=3
cage=bpy.data.objects.new('Elastic wrapped present cage',ld);scene.collection.objects.link(cage)
cage.location=(0,0,1.40);cage.scale=(2.40,2.40,2.80);cage.parent=root
cage.shape_key_add(name='Basis');squash=cage.shape_key_add(name='Soft compression');stretch=cage.shape_key_add(name='Elastic recoil')
for i,p in enumerate(ld.points):
    x,y,z=p.co_deform;h=z+.5
    squash.data[i].co=(x*(1.15-.055*h),y*(1.15-.055*h),h*.78-.5)
    stretch.data[i].co=(x*.955,y*.955,h*1.115-.5)
def deform(obj):
    mod=obj.modifiers.new('Connected elastic paper deformation','LATTICE');mod.object=cage
for obj in [body,lid,*wrap]:deform(obj)

def ribbon(name,points,width,twist=0):
    controls=[Vector(p) for p in points];verts=[];faces=[]
    count=(len(controls)-1)*14
    for k in range(count+1):
        segment=min(len(controls)-2,k//14);t=(k-segment*14)/14
        p0=controls[max(0,segment-1)];p1=controls[segment];p2=controls[segment+1];p3=controls[min(len(controls)-1,segment+2)]
        p=.5*((2*p1)+(-p0+p2)*t+(2*p0-5*p1+4*p2-p3)*t*t+(-p0+3*p1-3*p2+p3)*t*t*t)
        a=twist*math.sin(k/count*math.pi)
        widthvec=Vector((0,math.cos(a),math.sin(a)))*width*.5
        verts.extend([p-widthvec,p+widthvec])
        if k:faces.append((2*k-2,2*k-1,2*k+1,2*k))
    data=bpy.data.meshes.new(name);data.from_pydata(verts,[],faces);data.update()
    obj=bpy.data.objects.new(name,data);scene.collection.objects.link(obj);obj.parent=root
    data.materials.append(gold);data.materials.append(gold_back)
    for p in data.polygons:p.use_smooth=True
    obj.shape_key_add(name='Basis');lag=obj.shape_key_add(name='Fabric lag and flex');lag.slider_min=-1
    for i,point in enumerate(lag.data):
        phase=(i//2)/count
        influence=math.sin(math.pi*phase)**2
        point.co.z-=.20*influence;point.co.y-=.14*influence
    solid=obj.modifiers.new('Soft fabric tape thickness','SOLIDIFY');solid.thickness=.022;solid.material_offset=1
    bevel=obj.modifiers.new('Soft satin hems','BEVEL');bevel.width=.008;bevel.segments=3
    deform(obj)
    return obj,lag
bow=[];lag_keys=[]
for name,points,width,twist in [
    ('Bow / full left loop',[(0,0,2.19),(-.26,.08,2.48),(-.61,.15,2.68),(-.82,.13,2.54),(-.68,-.08,2.29),(-.18,-.055,2.18),(0,0,2.19)],.30,.48),
    ('Bow / full right loop',[(0,.03,2.19),(.28,.13,2.47),(.62,.19,2.65),(.83,.10,2.48),(.62,-.09,2.26),(.17,-.05,2.18),(0,.03,2.19)],.30,-.40),
    ('Bow / left soft tail',[(-.06,-.05,2.22),(-.31,-.20,2.20),(-.64,-.30,2.17),(-.83,-.33,2.10),(-.94,-.39,1.96)],.26,.30),
    ('Bow / right soft tail',[(.05,-.02,2.22),(.27,-.19,2.19),(.61,-.29,2.14),(.85,-.34,2.07),(.98,-.34,1.98)],.26,-.25)]:
    obj,key=ribbon(name,points,width,twist);bow.append(obj);lag_keys.append(key)
knot=cube('Bow / full soft fabric knot',(0,-.016,2.23),(.36,.34,.24),gold,.10,root);deform(knot);bow.append(knot)
intact=[body,lid,*wrap,*bow]

def key(obj,frame,loc=None,rot=None):
    if loc is not None:obj.location=loc;obj.keyframe_insert('location',frame=frame)
    if rot is not None:obj.rotation_euler=rot;obj.keyframe_insert('rotation_euler',frame=frame)
def scalar(socket,frame,value):socket.value=value;socket.keyframe_insert('value',frame=frame)
# Deliberate pose-to-pose timing: compression, visible lift, hang, soft contact,
# second higher hop, recoil, pop. AUTO_CLAMPED prevents unwanted curve overshoot.
poses=[
    (1,0,0,0,0),(14,0,0,0,0),(17,0,-.045,.45,0),(19,0,-.07,1,0),
    (21,.24,-.06,0,.8),(24,.55,.07,0,.22),(26,.24,.04,0,.2),
    (28,0,-.075,.95,0),(30,0,.02,.2,0),
    (32,0,.06,.9,0),(35,.46,.095,0,.75),(38,.80,-.06,0,.20),
    (41,.40,-.09,0,.35),(44,0,.065,1,0),(46,0,-.02,0,.9),(48,0,0,0,0),(96,0,0,0,0)]
for frame,height,lean,compressed,recoil in poses:
    key(root,frame,loc=(lean*.6,0,height),rot=(lean*.5,lean,lean*.55))
    scalar(squash,frame,compressed);scalar(stretch,frame,recoil)
for lag in lag_keys:
    for frame,value in [(1,0),(17,.15),(19,.45),(21,.85),(24,.55),(26,-.18),(28,-.55),(30,.18),
                        (32,.40),(35,.9),(38,.5),(41,-.20),(44,-.65),(46,.35),(48,0),(96,0)]:
        scalar(lag,frame,value)

# Camera-visible contact shadow is a native shader/plane, present in transparent
# frames. It becomes wider/lighter in the air and tight/dark at contact.
shadow_mat=bpy.data.materials.new('Native soft contact shadow');shadow_mat.use_nodes=True
shadow_mat.surface_render_method='BLENDED'
n=shadow_mat.node_tree.nodes;l=shadow_mat.node_tree.links;n.clear()
uv=n.new('ShaderNodeTexCoord');distance=n.new('ShaderNodeVectorMath');distance.operation='DISTANCE';distance.inputs[1].default_value=(.5,.5,0)
l.new(uv.outputs['UV'],distance.inputs[0])
mul=n.new('ShaderNodeMath');mul.operation='MULTIPLY';mul.inputs[1].default_value=2.0;l.new(distance.outputs['Value'],mul.inputs[0])
fade=n.new('ShaderNodeMath');fade.operation='SUBTRACT';fade.inputs[0].default_value=1;fade.use_clamp=True;l.new(mul.outputs[0],fade.inputs[1])
power=n.new('ShaderNodeMath');power.operation='POWER';power.inputs[1].default_value=2;l.new(fade.outputs[0],power.inputs[0])
opacity=n.new('ShaderNodeMath');opacity.operation='MULTIPLY';l.new(power.outputs[0],opacity.inputs[0]);opacity.inputs[1].default_value=.36
transparent=n.new('ShaderNodeBsdfTransparent');dark=n.new('ShaderNodeEmission');dark.inputs['Color'].default_value=(.015,.027,.035,1)
mix=n.new('ShaderNodeMixShader');l.new(opacity.outputs[0],mix.inputs[0]);l.new(transparent.outputs[0],mix.inputs[1]);l.new(dark.outputs[0],mix.inputs[2])
out=n.new('ShaderNodeOutputMaterial');l.new(mix.outputs[0],out.inputs['Surface'])
bpy.ops.mesh.primitive_plane_add(size=2,location=(0,0,.012));shadow=bpy.context.object;shadow.name='Gift / grounded soft contact shadow';shadow.scale=(1.75,1.42,1);shadow.data.materials.append(shadow_mat)
for frame,height,_,compressed,_ in poses:
    shadow.scale=(1.75+height*.65,1.42+height*.55,1);shadow.keyframe_insert('scale',frame=frame)
    opacity.inputs[1].default_value=.36/(1+height*1.7)+compressed*.055;opacity.inputs[1].keyframe_insert('default_value',frame=frame)
for frame,alpha in [(49,.24),(62,.12),(79,.045),(96,.045)]:
    opacity.inputs[1].default_value=alpha;opacity.inputs[1].keyframe_insert('default_value',frame=frame)

# Twenty colorful wrapping/cardboard fragments begin at the package faces.
# Each rotates about its own center on an independent eased arc. No hinges.
fragment_starts=[]
for side in [-1,1]:
    for u in [-.50,.50]:
        for z in [.51,1.53]:
            fragment_starts.append(((u,side*1.025,z),(.99,.035,.99),coral))
            fragment_starts.append(((side*1.025,u,z),(.035,.99,.99),coral if side>0 else mint))
for x in [-.5,.5]:
    for y in [-.5,.5]:fragment_starts.append(((x,y,2.06),(.99,.99,.035),mint))
fragments=[]
for index,(start,dims,color) in enumerate(fragment_starts):
    obj=cube(f'Burst / colorful paper fragment {index+1}',start,dims,color,.016)
    obj.data.materials.append(cream)
    # Paper remains thin: its narrow side faces show a pale cardboard edge.
    axis=min(range(3),key=lambda i:dims[i])
    for face in obj.data.polygons:
        if abs(face.normal[axis])<.9:face.material_index=1
    angle=index*math.tau/len(fragment_starts)+random.uniform(-.17,.17)
    radius=random.uniform(1.65,2.35)
    landing=Vector((math.cos(angle)*radius,math.sin(angle)*radius*.68,.04+.007*(index%4)))
    flat=[0,0,random.uniform(-math.pi,math.pi)]
    if axis==0:flat[1]=math.pi/2
    elif axis==1:flat[0]=math.pi/2
    initial=Vector(start)
    middle=initial.lerp(landing,.52)+Vector((0,0,.75+random.random()*.48))
    key(obj,48,loc=initial,rot=(0,0,0))
    key(obj,55,loc=middle,rot=(flat[0]+random.uniform(-.75,.75),flat[1]+random.uniform(-.7,.7),flat[2]*.5))
    key(obj,65,loc=landing+Vector((0,0,.12)),rot=(flat[0]+.12,flat[1],flat[2]))
    key(obj,72+index%4,loc=landing,rot=flat)
    key(obj,96,loc=landing,rot=flat)
    for frame,hidden in [(1,True),(47,True),(48,False),(96,False)]:obj.hide_render=hidden;obj.keyframe_insert('hide_render',frame=frame)
    fragments.append(obj)
for obj in intact:
    for frame,hidden in [(1,False),(47,False),(48,True),(96,True)]:obj.hide_render=hidden;obj.keyframe_insert('hide_render',frame=frame)

# The actual fabric bow releases as a connected, deformable object and comes
# to rest among the paper. It never simply vanishes at the pop.
released_bow=empty('Burst / released soft fabric bow',(0,0,2.20))
for original in bow:
    obj=original.copy();obj.data=original.data.copy();obj.animation_data_clear()
    scene.collection.objects.link(obj);obj.name='Released '+original.name;obj.parent=released_bow
    for modifier in list(obj.modifiers):
        if modifier.type=='LATTICE':obj.modifiers.remove(modifier)
    if original==knot:obj.location=original.location-Vector((0,0,2.20))
    else:
        for vertex in obj.data.vertices:vertex.co.z-=2.20
        if obj.data.shape_keys:
            for shape in obj.data.shape_keys.key_blocks:
                for point in shape.data:point.co.z-=2.20
            obj.data.shape_keys.animation_data_clear()
            lag=obj.data.shape_keys.key_blocks.get('Fabric lag and flex')
            if lag:
                for frame,value in [(48,0),(55,.8),(66,-.3),(74,1),(96,1)]:scalar(lag,frame,value)
    for frame,hidden in [(1,True),(47,True),(48,False),(96,False)]:obj.hide_render=hidden;obj.keyframe_insert('hide_render',frame=frame)
for frame,loc,rot in [(48,(0,0,2.20),(0,0,0)),(55,(-.9,.25,2.80),(.45,.12,-.65)),
                      (65,(-1.60,.75,.90),(.5,.15,-1.5)),(74,(-1.60,1.05,.23),(.45,0,-1.7)),
                      (80,(-1.60,1.05,.19),(.42,0,-1.7)),(96,(-1.60,1.05,.19),(.42,0,-1.7))]:
    key(released_bow,frame,loc=loc,rot=rot)

def area(name,loc,energy,color,size):
    d=bpy.data.lights.new(name,'AREA');d.energy=energy;d.color=color;d.shape='DISK';d.size=size
    o=bpy.data.objects.new(name,d);scene.collection.objects.link(o);o.location=loc;o.rotation_euler=(Vector((0,0,1))-o.location).to_track_quat('-Z','Y').to_euler()
area('Warm soft gift key',(-3,-4,6),560,(1,.86,.66),4)
area('Readable mint fill',(4,-2,4),360,(.63,.89,1),4)
area('Golden fabric rim',(-1,3,5),750,(1,.65,.30),3)
floor=cube('REVIEW ONLY / stage',(0,0,-.058),(200,200,.10),navy,0)
stage=navy.node_tree.nodes.get('Principled BSDF').inputs['Base Color']
for frame,c in [(1,(.008,.02,.03,1)),(47,(.008,.02,.03,1)),(54,(.70,.78,.74,1)),(96,(.70,.78,.74,1))]:stage.default_value=c;stage.keyframe_insert('default_value',frame=frame)
d=bpy.data.lights.new('Review spotlight','SPOT');d.energy=1100;d.spot_size=math.radians(45);d.spot_blend=.65
o=bpy.data.objects.new('Review spotlight',d);scene.collection.objects.link(o);o.location=(0,-1,7);o.rotation_euler=(Vector((0,0,0))-o.location).to_track_quat('-Z','Y').to_euler()
cd=bpy.data.cameras.new('Locked gift study camera');cd.type='ORTHO';cd.ortho_scale=6.1
cam=bpy.data.objects.new('Locked gift study camera',cd);scene.collection.objects.link(cam);scene.camera=cam;cam.location=(3,-7,5.2)
cam.rotation_euler=(Vector((0,0,1.24))-cam.location).to_track_quat('-Z','Y').to_euler()
for datablock in [root,cage.data.shape_keys,*[o.data.shape_keys for o in bow if o.type=='MESH' and o.data.shape_keys]]:
    if datablock.animation_data and datablock.animation_data.action:
        action=datablock.animation_data.action
        for slot in action.slots:
            for layer in action.layers:
                for strip in layer.strips:
                    bag=strip.channelbag(slot)
                    if bag:
                        for curve in bag.fcurves:
                            for point in curve.keyframe_points:
                                point.handle_left_type='AUTO_CLAMPED';point.handle_right_type='AUTO_CLAMPED'
scene.frame_set(1)
scene['Motion']='Two visible hops with native lattice compression, fabric lag, native contact shadow, independent colorful paper arcs; no face, hinges or intact open box.'
bpy.ops.wm.save_as_mainfile(filepath=str(ROOT/'source/lively-square-present.blend'))
if '--study' in ARGS:
    scene.render.resolution_x=240;scene.render.resolution_y=240;scene.eevee.taa_render_samples=32
    for i in range(48):
        f=1+i*2;scene.frame_set(f);scene.render.filepath=str(ROOT/'review'/f'study-{i:03d}.png');bpy.ops.render.render(write_still=True)
if '--runtime' in ARGS:
    floor.hide_render=True;scene.render.film_transparent=True;scene.render.resolution_x=352;scene.render.resolution_y=352
    for i in range(80):
        f=1+i*1.2;scene.frame_set(math.floor(f),subframe=f-math.floor(f));scene.render.filepath=str(ROOT/'runtime'/f'gift-{i:03d}.png');bpy.ops.render.render(write_still=True)
    (ROOT/'runtime/box_reveal.json').write_text(json.dumps({'version':1,'name':'Lively square gift v3','cellWidth':352,'cellHeight':352,'columns':10,'frameCount':80,'fps':20,'durationSeconds':4.0,
        'atlases':[{'asset':'assets/images/milestones/box_reveal_atlas.webp','firstFrame':0,'frameCount':80}],
        'posterAsset':'assets/images/milestones/box_reveal_poster.webp','boxAnchor':[.5,.54],'floorAnchor':[.5,.70],'badgeAnchor':[.5,.25],
        'timings':{'spotlightHold':.6,'shakeStart':.6,'openingStarts':1.96,'boxOpen':2.12,'badgeStart':2.0,'badgeEnd':2.8,'brightStageStart':2.0,'piecesSettled':3.15},'artworkVersion':'gift-v3'},indent=2)+'\n')
print('GIFT_V3_COMPLETE',flush=True)
