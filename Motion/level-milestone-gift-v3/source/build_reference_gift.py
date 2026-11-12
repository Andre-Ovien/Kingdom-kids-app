"""White/red present geometry for the user's MAIN selected Pinterest reference.

Reference: https://www.pinterest.com/pin/326651779251041743/
Only the observed main-video design and timing are used. Native mesh helpers
are reused, while the retired prototype's hops and colorful burst are excluded.
"""
import ast
import bpy
import math
import random
import json
from pathlib import Path
from mathutils import Vector

ROOT=Path(__file__).resolve().parent.parent
# Reuse native mesh/ribbon construction helpers only, ending BEFORE animation.
tree=ast.parse((ROOT/'source/build_gift.py').read_text())
prefix=[]
for node in tree.body:
    prefix.append(node)
    if isinstance(node,ast.Assign) and any(isinstance(target,ast.Name) and target.id=='intact' for target in node.targets):break
exec(compile(ast.Module(body=prefix,type_ignores=[]),'native_gift_geometry_only','exec'))

# Proportions measured from decoded main-video frames: the lower body is about
# .63 of its face width; the deep lid is about .35 of its width. Together square.
for m in [coral,mint]:
    b=m.node_tree.nodes.get('Principled BSDF')
    b.inputs['Base Color'].default_value=(.90,.90,.88,1)
    b.inputs['Roughness'].default_value=.31
    b.inputs['Coat Weight'].default_value=.12
    m.name='Reference / smooth white gift carton'
for m in [gold,gold_back]:
    b=m.node_tree.nodes.get('Principled BSDF')
    b.inputs['Base Color'].default_value=(.73,.012,.034,1)
    b.inputs['Roughness'].default_value=.22 if m==gold else .34
    b.inputs['Metallic'].default_value=.22
    b.inputs['Coat Weight'].default_value=.28
    m.name='Reference / glossy red ribbon' if m==gold else 'Reference / red ribbon reverse'
for obj in [body,lid,*wrap]:bpy.data.objects.remove(obj,do_unlink=True)
walls=[]
for name,pivot,loc,dims,axis,sign in [
    ('Front',(0,-.990,.023),(0,0,.65),(2,.035,1.30),0,1),
    ('Back',(0,.990,.023),(0,0,.65),(2,.035,1.30),0,-1),
    ('Left',(-.990,0,.023),(0,0,.65),(.035,1.97,1.30),1,-1),
    ('Right',(.990,0,.023),(0,0,.65),(.035,1.97,1.30),1,1)]:
    pivot_obj=empty('Reference / '+name+' paper fold',pivot,root)
    panel=cube('Reference / '+name+' thin white carton',loc,dims,coral,.018,pivot_obj);deform(panel)
    if axis==0:
        band=cube('Reference / '+name+' wide red ribbon',(0,-sign*.033,.65),(.50,.030,1.30),gold,.012,pivot_obj)
    else:
        band=cube('Reference / '+name+' wide red ribbon',(sign*.033,0,.65),(.030,.50,1.30),gold,.012,pivot_obj)
    deform(band);walls.append((pivot_obj,axis,sign))
bottom=cube('Reference / flat white base',(0,0,.026),(2,2,.035),coral,.014,root);deform(bottom)
lid_assembly=empty('Reference / lid and bow shoot straight up',parent=root)
lid=cube('Reference / deep overhanging white lid',(0,0,1.62),(2.16,2.16,.72),mint,.025,lid_assembly);deform(lid)
for side in [-1,1]:
    band=cube('Reference / lid front-back red ribbon',(0,side*1.094,1.62),(.50,.025,.72),gold,.009,lid_assembly);deform(band)
    band=cube('Reference / lid side red ribbon',(side*1.094,0,1.62),(.025,.50,.72),gold,.009,lid_assembly);deform(band)
for dims,z in [((2.17,.50,.025),1.995),((.50,2.17,.025),2.02)]:
    band=cube('Reference / red ribbon crossing lid',(0,0,z),dims,gold,.008,lid_assembly);deform(band)
for obj in bow:
    obj.parent=lid_assembly
    if obj==knot:
        obj.location=(0,-.01,2.09);obj.scale=(.80,.98,.70)
    elif obj.data.shape_keys:
        for shape in obj.data.shape_keys.key_blocks:
            for point in shape.data:
                point.co.x*=.67;point.co.y*=1.35;point.co.z=2.025+(point.co.z-2.19)*.68

magenta=material('Reference / rich magenta studio',(.255,.004,.067),.66)
floor=cube('REVIEW ONLY / magenta studio floor',(0,0,-.06),(100,100,.10),magenta,0)
floor.hide_render=True
scene.world.color=(.11,.016,.046)
def area(name,loc,energy,color,size):
    data=bpy.data.lights.new(name,'AREA');data.energy=energy;data.color=color;data.shape='DISK';data.size=size
    obj=bpy.data.objects.new(name,data);scene.collection.objects.link(obj);obj.location=loc
    obj.rotation_euler=(Vector((0,0,1.25))-obj.location).to_track_quat('-Z','Y').to_euler()
area('Reference / broad neutral key',(-3,-4,6),540,(1,.97,.96),4.5)
area('Reference / soft pink studio fill',(4,-2,4),320,(1,.79,.85),4)
area('Reference / white glossy rim',(-1,3,5),540,(1,.92,.95),3.0)
data=bpy.data.cameras.new('Reference / front-right three-quarter');data.type='ORTHO';data.ortho_scale=9.0
camera=bpy.data.objects.new('Reference / front-right three-quarter',data);scene.collection.objects.link(camera);scene.camera=camera
camera.location=(4.2,-6.6,3.1)
camera.rotation_euler=(Vector((0,0,1.30))-camera.location).to_track_quat('-Z','Y').to_euler()
scene.render.resolution_x=360;scene.render.resolution_y=640
scene.frame_end=192
def frame(seconds):return 1+seconds*24
def pose(obj,seconds,loc=None,rot=None,scale=None):
    f=frame(seconds)
    if loc is not None:obj.location=loc;obj.keyframe_insert('location',frame=f)
    if rot is not None:obj.rotation_euler=rot;obj.keyframe_insert('rotation_euler',frame=f)
    if scale is not None:obj.scale=scale;obj.keyframe_insert('scale',frame=f)
def shape_key(key,seconds,value):key.value=value;key.keyframe_insert('value',frame=frame(seconds))

# The selected clip has a seamless, saturated magenta field with broad radial
# rays, rather than a dark room/horizon. Author that studio field in Blender.
backdrop=bpy.data.materials.new('Review / seamless magenta radial studio field');backdrop.use_nodes=True
n=backdrop.node_tree.nodes;l=backdrop.node_tree.links;n.clear()
uv=n.new('ShaderNodeTexCoord');separate=n.new('ShaderNodeSeparateXYZ');l.new(uv.outputs['UV'],separate.inputs[0])
dx=n.new('ShaderNodeMath');dx.operation='SUBTRACT';dx.inputs[1].default_value=.5;l.new(separate.outputs['X'],dx.inputs[0])
dy=n.new('ShaderNodeMath');dy.operation='SUBTRACT';dy.inputs[1].default_value=.357;l.new(separate.outputs['Y'],dy.inputs[0])
aspect=n.new('ShaderNodeMath');aspect.operation='MULTIPLY';aspect.inputs[1].default_value=640/360;l.new(dy.outputs[0],aspect.inputs[0])
angle=n.new('ShaderNodeMath');angle.operation='ARCTAN2';l.new(aspect.outputs[0],angle.inputs[0]);l.new(dx.outputs[0],angle.inputs[1])
frequency=n.new('ShaderNodeMath');frequency.operation='MULTIPLY';frequency.inputs[1].default_value=11;l.new(angle.outputs[0],frequency.inputs[0])
wave=n.new('ShaderNodeMath');wave.operation='SINE';l.new(frequency.outputs[0],wave.inputs[0])
ray=n.new('ShaderNodeMapRange');ray.inputs['From Min'].default_value=-1;ray.inputs['From Max'].default_value=1;ray.inputs['To Min'].default_value=.12;ray.inputs['To Max'].default_value=.88;l.new(wave.outputs[0],ray.inputs['Value'])
colour=n.new('ShaderNodeMixRGB');colour.blend_type='MIX';colour.inputs[1].default_value=(.215,.008,.061,1);colour.inputs[2].default_value=(.305,.012,.087,1);l.new(ray.outputs['Result'],colour.inputs[0])
emission=n.new('ShaderNodeEmission');emission.inputs['Strength'].default_value=1;l.new(colour.outputs[0],emission.inputs['Color'])
out=n.new('ShaderNodeOutputMaterial');l.new(emission.outputs[0],out.inputs['Surface'])
bpy.ops.mesh.primitive_plane_add(size=2)
field=bpy.context.object;field.name='REVIEW ONLY / seamless magenta radial background';field.rotation_euler=camera.rotation_euler
field.scale=(9*360/640/2,9/2,1)
field.location=Vector((0,0,1.30))+camera.rotation_euler.to_matrix()@Vector((0,0,-9))
field.data.materials.append(backdrop)

def soft_disc(name,colour,radius,alpha,z,power_value=2):
    material_disc=bpy.data.materials.new(name);material_disc.use_nodes=True;material_disc.surface_render_method='BLENDED'
    n=material_disc.node_tree.nodes;l=material_disc.node_tree.links;n.clear()
    uv=n.new('ShaderNodeTexCoord');distance=n.new('ShaderNodeVectorMath');distance.operation='DISTANCE';distance.inputs[1].default_value=(.5,.5,0);l.new(uv.outputs['UV'],distance.inputs[0])
    scale=n.new('ShaderNodeMath');scale.operation='MULTIPLY';scale.inputs[1].default_value=2;l.new(distance.outputs['Value'],scale.inputs[0])
    fade=n.new('ShaderNodeMath');fade.operation='SUBTRACT';fade.inputs[0].default_value=1;fade.use_clamp=True;l.new(scale.outputs[0],fade.inputs[1])
    power=n.new('ShaderNodeMath');power.operation='POWER';power.inputs[1].default_value=power_value;l.new(fade.outputs[0],power.inputs[0])
    opacity=n.new('ShaderNodeMath');opacity.operation='MULTIPLY';opacity.inputs[1].default_value=alpha;l.new(power.outputs[0],opacity.inputs[0])
    transparent=n.new('ShaderNodeBsdfTransparent');emission=n.new('ShaderNodeEmission');emission.inputs['Color'].default_value=(*colour,1)
    blend=n.new('ShaderNodeMixShader');l.new(opacity.outputs[0],blend.inputs[0]);l.new(transparent.outputs[0],blend.inputs[1]);l.new(emission.outputs[0],blend.inputs[2])
    out=n.new('ShaderNodeOutputMaterial');l.new(blend.outputs[0],out.inputs['Surface'])
    bpy.ops.mesh.primitive_plane_add(size=2,location=(0,0,z));obj=bpy.context.object;obj.name=name;obj.scale=(radius,radius,1);obj.data.materials.append(material_disc)
    return obj,opacity.inputs[1]
studio_glow,glow_alpha=soft_disc('REVIEW ONLY / soft circular pink floor glow',(1,.17,.43),2.30,.66,.009,1.7)
shadow,shadow_alpha=soft_disc('REVIEW ONLY / soft moving contact shadow',(.022,.002,.009),1.60,.48,.014,2.5)

# Directly observed rhythm: enter from above, small settling turn, grow, rock
# large, spring smaller, stretch/squash, then lid/bow up and four white folds.
timing=[
    (0,5.0,.48,-1.10,0,0,0),(.18,3.0,.55,-.70,0,0,0),
    (.48,.15,.58,.28,.025,.25,0),(.68,.33,.57,.74,.03,0,.12),
    (1.0,.31,.57,-.14,.04,0,0),(1.35,.20,.65,.40,-.04,0,0),
    (1.70,.12,.86,.10,-.07,0,0),(2.0,.03,1.10,-.04,-.10,0,0),
    (2.32,.04,1.23,.57,-.18,0,.10),(2.65,.06,1.20,.22,-.13,0,0),
    (3.0,.03,1.12,-.15,-.08,0,0),(3.33,.04,1.10,.0,-.11,0,0),
    (3.67,.02,1.17,.38,-.15,0,0),(4.0,.05,1.08,.15,-.10,0,0),
    (4.30,.30,.57,-.05,.05,0,0),(4.55,.31,.57,.10,.02,0,.1),
    (4.88,.31,.57,-.04,-.035,0,1.6),(5.10,.29,.59,.11,.06,1.2,0),
    (5.30,.28,.58,.02,.01,.2,.25),(5.48,.22,.62,.05,-.02,1.15,0),
    (5.66,.25,.60,0,0,0,.45),(6.0,.12,.63,0,0,0,0),
    (6.55,.025,.68,0,0,0,0),(7.2,.025,.68,0,0,0,0),(8.0,.025,.68,0,0,0,0)]
for seconds,z,size,yaw,pitch,compression,recoil in timing:
    pose(root,seconds,loc=(0,0,z),rot=(pitch,0,yaw),scale=(size,)*3)
    shape_key(squash,seconds,compression);shape_key(stretch,seconds,recoil)
    pose(shadow,seconds,scale=(size*1.40+z*.12,size*1.40+z*.12,1))
    shadow_alpha.default_value=.52/(1+z*2);shadow_alpha.keyframe_insert('default_value',frame=frame(seconds))
for lag in lag_keys:
    for t,value in [(0,0),(.45,.45),(.68,-.20),(1.0,.12),(1.7,.10),(2.32,.3),(2.65,-.20),
                    (3.0,.12),(3.67,-.12),(4.3,.55),(4.55,-.2),(4.88,.7),(5.1,-.55),
                    (5.3,.25),(5.48,.5),(5.62,1),(5.83,.35),(6.2,0),(8,0)]:shape_key(lag,t,value)
for t,z in [(0,0),(5.48,0),(5.57,.15),(5.73,4.0),(5.94,14.0),(8,14.0)]:pose(lid_assembly,t,loc=(0,0,z))
for i,(pivot_obj,axis,sign) in enumerate(walls):
    for t,degrees in [(0,0),(5.67,0),(5.89,13),(6.13,42),(6.38,77),(6.57,90),(8,90)]:
        rot=[0,0,0];rot[axis]=math.radians(sign*degrees)
        pose(pivot_obj,t+i*.014 if t not in [0,8] else t,rot=rot)

# The circular floor glow and vertical white streaks are native review effects.
glowmat=material('Review / soft pink floor glow',(.57,.04,.20),.7)
bsdf=glowmat.node_tree.nodes.get('Principled BSDF');bsdf.inputs['Emission Color'].default_value=(1,.11,.36,1)
bpy.ops.mesh.primitive_torus_add(major_segments=96,minor_segments=12,major_radius=1.45,minor_radius=.009,location=(0,0,.022))
ring=bpy.context.object;ring.name='REVIEW ONLY / circular floor glow';ring.data.materials.append(glowmat)
for t,energy,scale in [(0,0,1),(.32,.9,1),(.70,2,1),(1.3,1.4,1.08),(2.0,.18,1.15),
                        (4.25,.8,1.2),(5.60,1.8,1.20),(6.20,2.8,1.55),(6.70,.4,1.7),(8,.18,1.7)]:
    bsdf.inputs['Emission Strength'].default_value=energy;bsdf.inputs['Emission Strength'].keyframe_insert('default_value',frame=frame(t));pose(ring,t,scale=(scale,scale,1))
beam_mat=material('Review / white rising streak',(.96,.88,.92),.25)
b=beam_mat.node_tree.nodes.get('Principled BSDF');b.inputs['Emission Color'].default_value=(1,.88,.94,1);b.inputs['Emission Strength'].default_value=5
for i in range(11):
    x=-.69+i*.138
    beam=cube('REVIEW ONLY / white vertical streak',(x,-.01,3.70),(.008+.003*(i%3),.008,6.8),beam_mat,.002)
    for t,size in [(0,0),(5.58,0),(5.75,.75),(6.05,1),(6.34,1),(6.72,0),(8,0)]:pose(beam,t,scale=(1,1,size))

# Camera-facing star meshes produce the white/pink sparkle field in review.
# Runtime Flutter will render the equivalent field and dynamic earned badge.
white_star=material('Review / white sparkle',(.95,.83,.88),.1)
pink_star=material('Review / pink sparkle',(.95,.20,.48),.1)
for mat in [white_star,pink_star]:
    b=mat.node_tree.nodes.get('Principled BSDF');b.inputs['Emission Color'].default_value=b.inputs['Base Color'].default_value;b.inputs['Emission Strength'].default_value=3.0
right=Vector((1,0,0));up=Vector((0,0,1))
matrix=camera.rotation_euler.to_matrix();right=matrix@Vector((1,0,0));up=matrix@Vector((0,1,0))
center=Vector((0,0,1.30));burst_origin=Vector((0,0,.55))
def star(name,position,size,mat):
    vertices=[position]
    for k in range(8):
        a=k*math.pi/4;r=size if k%2==0 else size*.22
        vertices.append(position+right*(math.sin(a)*r)+up*(math.cos(a)*r))
    data=bpy.data.meshes.new(name);data.from_pydata(vertices,[],[(0,k+1,(k+1)%8+1) for k in range(8)]);data.materials.append(mat)
    obj=bpy.data.objects.new(name,data);scene.collection.objects.link(obj);return obj
random.seed(326651)
for i in range(80):
    position=center+right*random.uniform(-2.50,2.50)+up*random.uniform(-4.3,4.3)+Vector((0,2,0))
    obj=star('REVIEW ONLY / ambient white sparkle',position,random.uniform(.006,.020),white_star)
    for t,y in [(0,.0),(4,.16),(8,.36)]:pose(obj,t,loc=(0,0,y))
for i in range(230):
    target=center+right*random.uniform(-3.2,3.2)+up*random.uniform(-4.8,4.8)
    obj=star('REVIEW ONLY / radiating pink-white sparkle',Vector((0,0,0)),random.uniform(.008,.035),white_star if i%3 else pink_star)
    start=6.22+random.random()*.18
    pose(obj,0,loc=burst_origin,scale=(0,0,0));pose(obj,start,loc=burst_origin,scale=(0,0,0))
    pose(obj,start+.13,loc=burst_origin.lerp(target,.30),scale=(1,1,1))
    pose(obj,start+.65,loc=burst_origin.lerp(target,.72),scale=(1,1,1))
    pose(obj,8.0,loc=target,scale=(.55,.55,.55))

# A brief white/pink origin flare lights the unfolding carton and radiates out.
flashdata=bpy.data.lights.new('REVIEW ONLY / opening white-pink flash','POINT');flashdata.color=(1,.48,.68);flashdata.shadow_soft_size=.65
flash=bpy.data.objects.new('REVIEW ONLY / opening white-pink flash',flashdata);scene.collection.objects.link(flash);flash.location=(0,0,.7)
for t,energy in [(0,0),(6.1,0),(6.30,200),(6.46,1200),(6.72,350),(7.4,70),(8,40)]:
    flashdata.energy=energy;flashdata.keyframe_insert('energy',frame=frame(t))
scene.use_nodes=True;nodes=scene.node_tree.nodes;nodes.clear()
rl=nodes.new('CompositorNodeRLayers');glare=nodes.new('CompositorNodeGlare');glare.glare_type='FOG_GLOW';glare.quality='HIGH';glare.threshold=1.1;glare.size=7;glare.mix=-.35
out=nodes.new('CompositorNodeComposite');scene.node_tree.links.new(rl.outputs['Image'],glare.inputs['Image']);scene.node_tree.links.new(glare.outputs['Image'],out.inputs['Image'])

for obj in [root,lid_assembly,*[item[0] for item in walls]]:
    if obj.animation_data and obj.animation_data.action:
        action=obj.animation_data.action
        for slot in action.slots:
            for layer in action.layers:
                for strip in layer.strips:
                    bag=strip.channelbag(slot)
                    if bag:
                        for curve in bag.fcurves:
                            for point in curve.keyframe_points:
                                point.handle_left_type='AUTO_CLAMPED';point.handle_right_type='AUTO_CLAMPED'
scene.frame_set(1)
scene['Reference URL']='https://www.pinterest.com/pin/326651779251041743/'
scene['Reference scope']='MAIN white/red gift video only; no related purple/coin/Cleo thumbnail variants.'
scene['Motion status']='Verified main-reference timing: drop, grow/turn, retract, stretch/squash, lid straight up, four white folds; no invented hops.'
scene['Overlay contract']='App supplies earned badge/title in place of original jewelry/logo. Reference clip is never an app asset.'
bpy.ops.wm.save_as_mainfile(filepath=str(ROOT/'source/reference-white-red-present.blend'))
if '--checkpoints' in ARGS:
    scene.eevee.taa_render_samples=48
    for label,t in [('reference-small',1.0),('reference-large',3.3),('reference-squash',5.48),('reference-opening',6.13),('reference-flat',7.15)]:
        f=frame(t);scene.frame_set(math.floor(f),subframe=f-math.floor(f));scene.render.filepath=str(ROOT/'review'/f'{label}.png');bpy.ops.render.render(write_still=True)
if '--study' in ARGS:
    scene.render.resolution_x=256;scene.render.resolution_y=456;scene.eevee.taa_render_samples=16
    directory=ROOT/'review/reference-study';directory.mkdir(exist_ok=True)
    for i in range(192):
        scene.frame_set(1+i);scene.render.filepath=str(directory/f'{i:03d}.png');bpy.ops.render.render(write_still=True)
print('REFERENCE_GIFT_REVIEW_COMPLETE',flush=True)
