"""Kingdom Kids / milestone chest. Blender 4.5, no external assets.

Run: Blender -b -t 4 --python create_chest.py -- --review
After review: Blender -b -t 4 --python create_chest.py -- --runtime
"""
import bpy
import math
import os
import sys
import json
from mathutils import Vector

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
args = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else []
bpy.ops.object.select_all(action='SELECT')
bpy.ops.object.delete(use_global=False)
scene = bpy.context.scene
scene.render.engine = 'BLENDER_EEVEE_NEXT'
scene.eevee.taa_render_samples = 32
scene.render.resolution_percentage = 100
scene.render.image_settings.file_format = 'PNG'
scene.render.image_settings.color_mode = 'RGBA'
scene.render.image_settings.color_depth = '8'
scene.render.fps = 24
scene.frame_start = 1
scene.frame_end = 96
scene.world.color = (0.015, 0.018, 0.025)
scene.view_settings.view_transform = 'AgX'
scene.view_settings.look = 'AgX - Medium High Contrast'
scene.render.film_transparent = False

def mat(name, color, metallic=0, rough=0.34, emission=None):
    m = bpy.data.materials.new(name)
    m.diffuse_color = (*color, 1)
    m.use_nodes = True
    bsdf = m.node_tree.nodes.get('Principled BSDF')
    bsdf.inputs['Base Color'].default_value = (*color, 1)
    bsdf.inputs['Metallic'].default_value = metallic
    bsdf.inputs['Roughness'].default_value = rough
    if emission:
        bsdf.inputs['Emission Color'].default_value = (*emission[0], 1)
        bsdf.inputs['Emission Strength'].default_value = emission[1]
    return m

teal = mat('Deep teal enamel', (0.018, 0.27, 0.24), .2, .27)
teal_top = mat('Lid teal enamel', (0.03, 0.33, 0.295), .22, .26)
gold = mat('Warm brushed brass', (0.94, 0.56, 0.14), .74, .25)
gold_soft = mat('Interior warm gold', (0.4, 0.23, 0.07), .48, .35)
coral = mat('Coral seal', (1, 0.22, 0.13), .17, .28)
inner = mat('Velvet dark interior', (0.017, 0.10, 0.088), .0, .6)
seam = mat('Warm reveal seam', (.98, .72, .2), .25, .25, ((1, .52, .08), 0))
stage_mat = mat('Midnight navy stage', (.006, .018, .028), .0, .55)

def empty(name, location=(0,0,0), parent=None):
    obj = bpy.data.objects.new(name, None)
    scene.collection.objects.link(obj)
    obj.location = location
    obj.parent = parent
    return obj

motion = empty('CHEST / whole-object anticipation')
hinge = empty('LID / fixed rear hinge', (0, .79, 1.39), motion)

def finish(obj, material, bevel=.05, parent=motion):
    obj.data.materials.append(material)
    if bevel:
        mod = obj.modifiers.new('Small manufactured bevel', 'BEVEL')
        mod.width = bevel
        mod.segments = 4
        mod.limit_method = 'ANGLE'
    norm = obj.modifiers.new('Weighted clean normals', 'WEIGHTED_NORMAL')
    norm.keep_sharp = True
    obj.parent = parent
    return obj

def cube(name, loc, dims, material, bevel=.05, parent=motion):
    bpy.ops.mesh.primitive_cube_add(size=1, location=loc)
    obj = bpy.context.object
    obj.name = name
    obj.dimensions = dims
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    return finish(obj, material, bevel, parent)

def mesh(name, verts, faces, material, bevel=.035, parent=motion):
    data = bpy.data.meshes.new(name)
    data.from_pydata(verts, [], faces)
    data.update()
    obj = bpy.data.objects.new(name, data)
    scene.collection.objects.link(obj)
    return finish(obj, material, bevel, parent)

# Four genuinely separate, solid walls; an open top and a dark fitted interior.
cube('Body / front wall', (0,-.785,.76), (2.64,.16,1.24), teal, .065)
cube('Body / rear wall', (0,.785,.76), (2.64,.16,1.24), teal, .065)
cube('Body / left wall', (-1.245,0,.76), (.16,1.48,1.24), teal, .065)
cube('Body / right wall', (1.245,0,.76), (.16,1.48,1.24), teal, .065)
cube('Body / solid bottom', (0,0,.19), (2.63,1.64,.25), teal, .075)
cube('Interior / fitted velvet base', (0,0,.34), (2.34,1.35,.055), inner, .015)

# Restrained broad corner protectors make its form legible at phone scale.
for x in (-1.18,1.18):
    for y in (-.83,.83):
        cube('Brass corner rail', (x,y,.76), (.135,.10,1.22), gold, .033)
for y in (-.81,.81):
    cube('Body / rim front or back', (0,y,1.375), (2.70,.14,.105), gold, .033)
for x in (-1.29,1.29):
    cube('Body / rim side', (x,0,1.375), (.13,1.61,.105), gold, .028)
cube('Body / front base rail', (0,-.828,.21), (2.60,.095,.12), gold, .025)
cube('Body / right base rail', (1.287,0,.21), (.095,1.53,.12), gold, .025)

# Lid uses a shallow curved cross-section, rigidly parented to a rear hinge.
# All geometry is expressed in the hinge's local coordinates.
profile = [(-1.62,0),(-1.60,.105),(-1.40,.27),(-1.14,.38),
           (-.81,.42),(-.48,.38),(-.22,.27),(-.02,.105),(0,0)]
def arch(name, x0, x1, material, bevel, lift=0):
    verts = [(x,y,z+lift) for x in (x0,x1) for y,z in profile]
    n = len(profile)
    faces = [tuple(range(n-1,-1,-1)),tuple(range(n,n*2))]
    faces += [(i,i+1,i+1+n,i+n) for i in range(n-1)]
    faces += [(n-1,0,n,2*n-1)]
    obj=mesh(name, verts, faces, material, bevel, hinge)
    for polygon in obj.data.polygons[2:-1]:
        polygon.use_smooth=True
    return obj

arch('Lid / curved solid shell', -1.345,1.345,teal_top,.06)
for x in (-1.175,1.175):
    arch('Lid / curved brass band', x-.068,x+.068,gold,.016,.025)
cube('Lid / front brass lip', (0,-1.626,.032), (2.68,.10,.105),gold,.029,hinge)
cube('Lid / underside inset', (0,-.81,-.028), (2.36,1.37,.045),inner,.018,hinge)
for x in (-1.0,1.0):
    cube('Lid / underside support', (x,-.81,-.052),(.08,1.37,.055),gold_soft,.015,hinge)

# Lock belongs to the lower wall, the lid tab belongs to the moving lid.
cube('Lock / brass surround',(0,-.89,1.05),(.34,.105,.43),gold,.065)
cube('Lock / coral inset',(0,-.957,1.075),(.19,.06,.24),coral,.055)
cube('Lock / lid tab',(0,-1.686,.013),(.14,.095,.29),gold,.035,hinge)
# A simple engraved keyhole, avoiding busy ornamental detail.
bpy.ops.mesh.primitive_uv_sphere_add(segments=20,ring_count=10,radius=1,location=(0,-1.002,1.096))
keyhole=bpy.context.object
keyhole.name='Lock / dark keyhole'
keyhole.scale=(.039,.012,.044)
bpy.ops.object.transform_apply(location=False,rotation=False,scale=True)
finish(keyhole,inner,0)
cube('Lock / keyhole stem',(0,-1.002,1.053),(.036,.018,.052),inner,.008)

# Low feet and fixed hinge barrels visually ground the manufactured toy.
for x in (-1.11,1.11):
    for y in (-.64,.64):
        cube('Body / soft square foot',(x,y,.095),(.25,.29,.19),gold,.065)
for x in (-.93,.93):
    bpy.ops.mesh.primitive_cylinder_add(vertices=32,radius=.105,depth=.32,location=(x,.81,1.37),rotation=(0,math.pi/2,0))
    finish(bpy.context.object,gold,.016)

# The seam is a physical narrow strip; its glow has a brief, bounded pulse.
cube('Reveal / front seam',(0,-.903,1.430),(2.39,.020,.022),seam,.007)
cube('Reveal / right seam',(1.364,0,1.430),(.020,1.40,.022),seam,.007)
cube('Reveal / left seam',(-1.364,0,1.430),(.020,1.40,.022),seam,.007)

def key_transform(obj, frame, loc=None, rot=None, scale=None):
    if loc is not None:
        obj.location=loc
        obj.keyframe_insert('location',frame=frame)
    if rot is not None:
        obj.rotation_euler=rot
        obj.keyframe_insert('rotation_euler',frame=frame)
    if scale is not None:
        obj.scale=scale
        obj.keyframe_insert('scale',frame=frame)

# 0.0–0.6s still. 0.6–1.6s restrained acceleration. Open 1.6–2.1s.
poses=[(1,0,0),(14,0,0),(18,.011,.012),(21,-.017,-.017),
       (24,.025,.022),(27,-.028,-.023),(30,.034,.030),
       (33,-.044,-.029),(35,.048,.040),(37,-.045,-.030),
       (39,.027,.018),(41,0,0),(52,0,0),(96,0,0)]
for f,rx,rz in poses:
    key_transform(motion,f,loc=(rz*.22,0,abs(rz)*.4),rot=(rx,0,rz))
for f,angle in [(1,0),(32,0),(37,-2),(40,-5),(44,-38),(48,-91),(51,-108),(56,-102),(62,-105),(96,-105)]:
    key_transform(hinge,f,rot=(math.radians(angle),0,0))
strength=seam.node_tree.nodes.get('Principled BSDF').inputs['Emission Strength']
for f,s in [(1,0),(25,0),(32,.8),(37,3),(41,6),(48,3),(56,.55),(70,.1),(96,.1)]:
    strength.default_value=s
    strength.keyframe_insert('default_value',frame=f)

def area(name,loc,power,color,size,target=(0,0,1)):
    data=bpy.data.lights.new(name,'AREA')
    data.energy=power
    data.color=color
    data.shape='DISK'
    data.size=size
    obj=bpy.data.objects.new(name,data)
    scene.collection.objects.link(obj)
    obj.location=loc
    obj.rotation_euler=(Vector(target)-obj.location).to_track_quat('-Z','Y').to_euler()
    return obj

area('Key / broad warm softbox',(-3,-4,6),650,(1,.83,.61),4)
area('Fill / cool teal bounce',(4,-2,3.2),390,(.40,.87,1),3.5)
area('Rim / warm gold edge',(-1,3,5),1000,(1,.57,.20),2.6)
area('Front / readable hardware',(0,-4,2.5),110,(1,.94,.83),2)
glow_data=bpy.data.lights.new('Reveal / interior warm light','POINT')
glow_data.color=(1,.55,.13)
glow_data.shadow_soft_size=.6
glow_obj=bpy.data.objects.new('Reveal / interior warm light',glow_data)
scene.collection.objects.link(glow_obj)
glow_obj.location=(0,0,1.10)
for f,p in [(1,0),(31,0),(39,40),(43,100),(50,110),(60,28),(75,10),(96,10)]:
    glow_data.energy=p
    glow_data.keyframe_insert('energy',frame=f)

floor=cube('REVIEW ONLY / midnight ground',(0,0,-.08),(200,200,.10),stage_mat,.0,parent=None)
# Spotlight pool and actual shadows on the review stage.
spotdata=bpy.data.lights.new('Spotlight / overhead','SPOT')
spotdata.energy=1450
spotdata.color=(1,.89,.72)
spotdata.spot_size=math.radians(46)
spotdata.spot_blend=.62
spotdata.shadow_soft_size=.3
spotobj=bpy.data.objects.new('Spotlight / overhead',spotdata)
scene.collection.objects.link(spotobj)
spotobj.location=(-.5,-.8,7)
spotobj.rotation_euler=(Vector((0,0,0))-spotobj.location).to_track_quat('-Z','Y').to_euler()

camdata=bpy.data.cameras.new('Portrait / locked camera')
cam=bpy.data.objects.new('Portrait / locked camera',camdata)
scene.collection.objects.link(cam)
scene.camera=cam
camdata.type='ORTHO'
cam.location=(5,-8,5.2)
def aim(target):
    cam.rotation_euler=(Vector(target)-cam.location).to_track_quat('-Z','Y').to_euler()
aim((0,0,1.65))
camdata.ortho_scale=7.8
scene.render.resolution_x=720
scene.render.resolution_y=1280

# Restrained luminous seam, not blown-out emission or sprayed particles.
scene.use_nodes=True
nodes=scene.node_tree.nodes
nodes.clear()
rl=nodes.new('CompositorNodeRLayers')
gl=nodes.new('CompositorNodeGlare')
gl.glare_type='FOG_GLOW'
gl.quality='HIGH'
gl.threshold=1.5
gl.size=6
gl.mix=-.92
out=nodes.new('CompositorNodeComposite')
scene.node_tree.links.new(rl.outputs['Image'],gl.inputs['Image'])
scene.node_tree.links.new(gl.outputs['Image'],out.inputs['Image'])

scene['Asset notes']='Rigid rear-hinged chest. No baked badge, rank, number, confetti or UI. Runtime renders transparent.'
scene['Reveal start seconds']=1.6
scene['Fully open seconds']=2.1
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(ROOT,'source','kingdom_kids_milestone_chest.blend'))

if '--review' in args:
    scene.render.resolution_x=540
    scene.render.resolution_y=960
    for label,frame in [('closed',14),('seam-glow',39),('hero-open',58)]:
        scene.frame_set(frame)
        scene.render.filepath=os.path.join(ROOT,'review',label+'.png')
        bpy.ops.render.render(write_still=True)
    scene.render.resolution_x=270
    scene.render.resolution_y=480
    scene.eevee.taa_render_samples=16
    for i,frame in enumerate([1,22,35,41,47,58,72,96]):
        scene.frame_set(frame)
        scene.render.filepath=os.path.join(ROOT,'review',f'timeline-{i:02d}.png')
        bpy.ops.render.render(write_still=True)

if '--runtime' in args or '--runtime-test' in args:
    floor.hide_render=True
    scene.render.film_transparent=True
    scene.render.resolution_x=352
    scene.render.resolution_y=352
    camdata.ortho_scale=4.35
    aim((0,0,1.53))
    scene.eevee.taa_render_samples=32
    samples=[(i,1+i*1.2) for i in range(80)]
    if '--runtime-test' in args:
        samples=[samples[0],samples[-1]]
    for i,frame in samples:
        whole=math.floor(frame)
        scene.frame_set(whole,subframe=frame-whole)
        scene.render.filepath=os.path.join(ROOT,'runtime',f'chest-{i:03d}.png')
        bpy.ops.render.render(write_still=True)
    manifest={'version':1,'name':'Kingdom Kids milestone chest',
              'cellWidth':352,'cellHeight':352,'columns':10,
              'frameCount':80,'fps':20,'durationSeconds':4.0,'sourceFps':24,
              'atlases':[{'asset':'assets/images/milestones/box_reveal_atlas.webp',
                           'firstFrame':0,'frameCount':80}],
              'posterAsset':'assets/images/milestones/box_reveal_poster.webp',
              'timings':{'spotlightHold':.6,'shakeStart':.6,'openingStarts':1.6,
                         'boxOpen':2.1,'badgeStart':2.1,'badgeEnd':2.8},
              'floorAnchor':[.50,.925],'boxAnchor':[.50,.54],
              'badgeAnchor':[.46,.10],'badgeEmergenceAnchor':[.50,.54],
              'blendFile':'source/kingdom_kids_milestone_chest.blend',
              'contains':['chest','rigid lid','seam glow'],
              'flutterOverlays':['stage','spotlight','badge','confetti','rank/level','Keep exploring'],
              'decodedAtlasBytes':3520*2816*4}
    with open(os.path.join(ROOT,'runtime','manifest.json'),'w') as file:
        json.dump(manifest,file,indent=2)
