"""Build an editable 3D Kai motion study. Run with Blender --background --python.

This is a new model approximation, not the original mascot's production mesh.
No raster image pieces are used. Review appearance before app integration.
"""
import math
import os
import sys
from pathlib import Path

import bpy
from mathutils import Vector, Matrix, Quaternion

OUT = Path(__file__).resolve().parent
OUT.mkdir(parents=True, exist_ok=True)
bpy.ops.object.select_all(action='SELECT')
bpy.ops.object.delete(use_global=False)
scene = bpy.context.scene
scene.render.engine = 'CYCLES'
scene.cycles.samples = 24
scene.cycles.use_denoising = True
scene.render.resolution_x = 540
scene.render.resolution_y = 720
scene.render.resolution_percentage = 100
scene.render.fps = 24
scene.frame_start = 1
scene.frame_end = 144
scene.render.image_settings.file_format = 'PNG'
scene.view_settings.view_transform = 'AgX'


def material(name, color, roughness=.5, grain=0):
    m = bpy.data.materials.new(name)
    m.diffuse_color = (*color, 1)
    m.use_nodes = True
    p = m.node_tree.nodes.get('Principled BSDF')
    p.inputs['Base Color'].default_value = (*color, 1)
    p.inputs['Roughness'].default_value = roughness
    if name == 'Warm brown skin':
        p.inputs['Subsurface Weight'].default_value = .08
    if grain:
        noise = m.node_tree.nodes.new('ShaderNodeTexNoise')
        noise.inputs['Scale'].default_value = 110
        bump = m.node_tree.nodes.new('ShaderNodeBump')
        bump.inputs['Strength'].default_value = grain
        bump.inputs['Distance'].default_value = .025
        m.node_tree.links.new(noise.outputs['Fac'], bump.inputs['Height'])
        m.node_tree.links.new(bump.outputs['Normal'], p.inputs['Normal'])
    return m


skin = material('Warm brown skin', (.38, .135, .042), .48, .07)
ear_inner = material('Ear and lip warmth', (.24, .06, .022), .55)
shirt = material('Kai green cotton', (.08, .38, .07), .72, .16)
denim = material('Blue denim', (.025, .20, .35), .75, .18)
cuff = material('Folded denim cuffs', (.05, .29, .46), .78, .16)
green = material('Green sneaker panels', (.04, .30, .095), .52)
cream = material('Cream sneaker soles and laces', (.83, .79, .62), .7)
white = material('Eye white and teeth', (.94, .91, .81), .3)
iris = material('Brown iris', (.21, .085, .017), .26)
black = material('Pupil', (.006, .004, .003), .2)
hair = material('Dark brown locs', (.009, .004, .0015), .8, .3)
mouth = material('Mouth interior', (.045, .006, .003), .68)
tongue = material('Tongue', (.48, .11, .075), .5)
objects_to_bind = []


def smooth(obj, mat):
    obj.data.materials.append(mat)
    if obj.type == 'MESH':
        for p in obj.data.polygons:
            p.use_smooth = True
    return obj


def sphere(name, loc, scale, mat, bone=None):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=40, ring_count=24, location=loc)
    obj = bpy.context.object
    obj.name = name
    obj.scale = scale
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    smooth(obj, mat)
    if bone:
        objects_to_bind.append((obj, bone))
    return obj


def tube(name, points, radius, mat, bone=None):
    curve = bpy.data.curves.new(name, 'CURVE')
    curve.dimensions = '3D'
    curve.resolution_u = 12
    curve.bevel_depth = radius
    curve.bevel_resolution = 4
    spl = curve.splines.new('BEZIER')
    spl.bezier_points.add(len(points) - 1)
    for p, co in zip(spl.bezier_points, points):
        p.co = co
        p.handle_left_type = p.handle_right_type = 'AUTO'
    obj = bpy.data.objects.new(name, curve)
    bpy.context.collection.objects.link(obj)
    smooth(obj, mat)
    if bone:
        objects_to_bind.append((obj, bone))
    return obj


def lathe(name, rings, mat):
    verts, faces = [], []
    n = 48
    for z, rx, ry in rings:
        for i in range(n):
            a = 2 * math.pi * i / n
            verts.append((rx * math.cos(a), ry * math.sin(a), z))
    for r in range(len(rings)-1):
        for i in range(n):
            j = (i+1) % n
            faces.append((r*n+i, r*n+j, (r+1)*n+j, (r+1)*n+i))
    faces.extend([tuple(reversed(range(n))), tuple((len(rings)-1)*n+i for i in range(n))])
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata(verts, [], faces)
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    smooth(obj, mat)
    sub = obj.modifiers.new('Soft clothing surface', 'SUBSURF')
    sub.levels = 2
    objects_to_bind.append((obj, 'spine'))
    return obj


# Oversized child head, brown locs, green tee, cuffed jeans, green/cream shoes.
sphere('Head', (0, 0, 3.0), (.64, .53, .69), skin, 'head')
sphere('Neck', (0, 0, 2.35), (.20, .19, .26), skin, 'spine')
for sign in (-1, 1):
    sphere('Ear', (sign*.625, 0, 3.01), (.13, .10, .205), skin, 'head')
    sphere('Ear inner', (sign*.662, -.071, 3.01), (.062, .031, .128), ear_inner, 'head')
    sphere('Cheek', (sign*.34, -.345, 2.82), (.245, .17, .21), skin, 'head')
sphere('Nose bridge', (0, -.476, 3.0), (.092, .105, .18), skin, 'head')
sphere('Nose tip', (0, -.563, 2.91), (.135, .125, .095), skin, 'head')
# Merge the facial skin into one continuous sculpt rather than floating cheeks.
facial_parts = [obj for obj, bn in objects_to_bind
                if bn == 'head' and obj.data.materials[0] == skin]
bpy.ops.object.select_all(action='DESELECT')
for obj in facial_parts:
    obj.select_set(True)
bpy.context.view_layer.objects.active = facial_parts[0]
bpy.ops.object.join()
face_obj = bpy.context.object
face_obj.name = 'Continuous facial sculpt'
bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
rem = face_obj.modifiers.new('Blend cheeks nose and ears', 'REMESH')
rem.mode = 'VOXEL'
rem.voxel_size = .014
bpy.ops.object.modifier_apply(modifier=rem.name)
sm = face_obj.modifiers.new('Smooth facial transitions', 'SMOOTH')
sm.factor = .65
sm.iterations = 12
bpy.ops.object.modifier_apply(modifier=sm.name)
for p in face_obj.data.polygons:
    p.use_smooth = True
objects_to_bind = [(obj,bn) for obj,bn in objects_to_bind if obj not in facial_parts]
objects_to_bind.append((face_obj, 'head'))
face_obj.select_set(False)
for sign in (-1, 1):
    sphere('Nostril', (sign*.075, -.646, 2.88), (.026, .014, .018), ear_inner, 'head')

blink_keys = []
for sign in (-1, 1):
    eye_center = (sign*.258, -.457, 3.16)
    sphere('Eye white', eye_center, (.177, .102, .195), white, 'head')
    sphere('Iris', (sign*.253, -.551, 3.155), (.116, .015, .131), iris, 'head')
    sphere('Pupil', (sign*.253, -.564, 3.155), (.074, .008, .087), black, 'head')
    sphere('Eye highlight', (sign*.253-.028, -.568, 3.202), (.023, .006, .025), white, 'head')
    # Eyelids sweep over the eyeball; the eye itself keeps its shape.
    for upper in (True, False):
        def lid_vertices(limit):
            vv = []
            for j in range(13):
                theta = .01 + (limit-.01)*j/12
                for i in range(25):
                    phi = math.pi*i/24
                    vv.append((.183*math.sin(theta)*math.cos(phi),
                               -.124*math.sin(theta)*math.sin(phi),
                               (.202 if upper else -.202)*math.cos(theta)))
            return vv
        faces = [(j*25+i, j*25+i+1, (j+1)*25+i+1, (j+1)*25+i)
                 for j in range(12) for i in range(24)]
        mesh = bpy.data.meshes.new('Eyelid surface')
        mesh.from_pydata(lid_vertices(.81 if upper else .64), [], faces)
        obj = bpy.data.objects.new('Upper eyelid' if upper else 'Lower eyelid', mesh)
        bpy.context.collection.objects.link(obj)
        obj.location = eye_center
        smooth(obj, skin)
        obj.shape_key_add(name='Open')
        k = obj.shape_key_add(name='Blink')
        for v, co in zip(k.data, lid_vertices(math.pi/2+.015)):
            v.co = co
        blink_keys.append(k)
        objects_to_bind.append((obj, 'head'))
    tube('Expressive eyebrow', [(sign*.12,-.48,3.46),(sign*.27,-.455,3.505),(sign*.41,-.37,3.46)], .034, hair, 'head')

# An inset smile with teeth and a small tongue, curved across the face.
verts, faces = [], []
for row in range(9):
    t = row / 8
    for i in range(33):
        x = -.245 + .49*i/32
        edge = 1 - (x/.245)**2
        z_top = 2.738 - .025*edge
        z_bottom = 2.738 - .16*edge
        verts.append((x, -.495 + .24*x*x, z_top*(1-t)+z_bottom*t))
for j in range(8):
    for i in range(32):
        faces.append((j*33+i,j*33+i+1,(j+1)*33+i+1,(j+1)*33+i))
mesh = bpy.data.meshes.new('Smile opening')
mesh.from_pydata(verts, [], faces)
obj = bpy.data.objects.new('Smile opening',mesh)
bpy.context.collection.objects.link(obj)
smooth(obj,mouth)
objects_to_bind.append((obj,'head'))
tube('Lower smile lip', [(-.245,-.481,2.738),(-.14,-.501,2.635),(0,-.509,2.578),(.14,-.501,2.635),(.245,-.481,2.738)], .016, ear_inner,'head')
for i in range(6):
    x = -.155 + i*.062
    sphere('Smile tooth', (x,-.503+.24*x*x,2.70+.25*x*x), (.033,.016,.027), white,'head')
sphere('Tongue', (0,-.506,2.601), (.085,.011,.021), tongue,'head')

# Locs are actual curved geometry with rounded tips, following the head crown.
sphere('Hair cap', (0,.025,3.43), (.61,.48,.30), hair,'head')
for i in range(35):
    phi = i*2.399963
    radius = .13 + .44*math.sqrt((i+.5)/35)
    x, y = radius*math.cos(phi), radius*.73*math.sin(phi)
    z = 3.52 + .16*(1-radius/.57)
    length = .22+.17*(.5+.5*math.sin(i*2.17))
    tip = (x+math.cos(phi)*length, y+math.sin(phi)*length*.66, z-.12-.14*(i%3))
    tube('Loc %02d'%i,[(x,y,z),(x+math.cos(phi)*.14,y+math.sin(phi)*.11,z+.04),tip],.055,hair,'head')
    sphere('Rounded loc tip',tip,(.057,.057,.057),hair,'head')

lathe('Green T shirt',[(1.32,.405,.265),(1.38,.415,.28),(1.75,.375,.25),(2.10,.405,.245),(2.19,.31,.22),(2.24,.205,.175)],shirt)
tube('Neckline',[(.20*math.cos(a),.177*math.sin(a),2.235) for a in [i*2*math.pi/48 for i in range(49)]],.017,shirt,'spine')
sphere('Jeans hips',(0,0,1.23),(.36,.25,.26),denim,'root')
for sign, side in ((-1,'L'),(1,'R')):
    sphere('Jeans leg '+side,(sign*.205,0,.83),(.18,.205,.48),denim,'root')
    sphere('Denim cuff '+side,(sign*.205,-.008,.40),(.19,.215,.11),cuff,'root')
    sphere('Green sneaker '+side,(sign*.205,-.115,.20),(.20,.31,.17),green,'root')
    sphere('Cream sole '+side,(sign*.205,-.12,.095),(.211,.321,.065),cream,'root')
    sphere('Cream toe '+side,(sign*.205,-.32,.18),(.183,.115,.095),cream,'root')
    sphere('Sneaker tongue '+side,(sign*.205,-.18,.315),(.107,.12,.038),cream,'root')
    for z, y in ((.306,-.225),(.282,-.266),(.254,-.302)):
        tube('Sneaker lace '+side,[(sign*.205-.09,y,z),(sign*.205,y-.01,z+.013),(sign*.205+.09,y,z)],.014,cream,'root')
    tube('Jeans seam '+side,[(sign*.29,-.161,1.3),(sign*.315,-.169,.85),(sign*.305,-.16,.50)],.006,cuff,'root')

# Rest skeleton. Continuous arm geometry is skinned across shoulder/elbow/wrist.
arm_data = bpy.data.armatures.new('Kai skeleton')
rig = bpy.data.objects.new('Kai motion rig', arm_data)
bpy.context.collection.objects.link(rig)
bpy.context.view_layer.objects.active = rig
rig.select_set(True)
bpy.ops.object.mode_set(mode='EDIT')
def bone(name, head, tail, parent=None):
    b=arm_data.edit_bones.new(name)
    b.head, b.tail = head, tail
    if parent:
        b.parent=arm_data.edit_bones[parent]
    return b
bone('root',(0,0,.1),(0,0,1.3))
bone('spine',(0,0,1.3),(0,0,2.30),'root')
bone('head',(0,0,2.30),(0,0,3.5),'spine')
for sign,side in ((-1,'L'),(1,'R')):
    bone('upper_arm.'+side,(sign*.37,0,2.11),(sign*.64,-.015,1.70),'spine')
    bone('forearm.'+side,(sign*.64,-.015,1.70),(sign*.73,-.045,1.26),'upper_arm.'+side)
    bone('hand.'+side,(sign*.73,-.045,1.26),(sign*.76,-.065,1.06),'forearm.'+side)
bpy.ops.object.mode_set(mode='OBJECT')
rig.select_set(False)

def bind(obj, bone_name):
    # Keep geometry in world coordinates and apply one rigid group for face/shoes.
    if obj.type == 'CURVE':
        bpy.context.view_layer.objects.active=obj
        obj.select_set(True)
        bpy.ops.object.convert(target='MESH')
        obj.select_set(False)
    group=obj.vertex_groups.new(name=bone_name)
    group.add(list(range(len(obj.data.vertices))),1,'REPLACE')
    mod=obj.modifiers.new('Kai skeleton','ARMATURE')
    mod.object=rig

for obj,bn in objects_to_bind:
    bind(obj,bn)

for sign,side in ((-1,'L'),(1,'R')):
    # Skin surface includes upper arm, forearm and palm; voxel union removes seams.
    parts=[]
    for part_name, a, b, radius in [
        ('Upper arm', (sign*.37,0,2.11),(sign*.64,-.015,1.70), .12),
        ('Forearm', (sign*.64,-.015,1.70),(sign*.73,-.045,1.26), .098)]:
        a,b=Vector(a),Vector(b)
        part=sphere(part_name, (a+b)/2,(radius,radius,(b-a).length/2+radius*.35),skin)
        part.rotation_euler=(b-a).to_track_quat('Z','Y').to_euler()
        parts.append(part)
    parts.append(sphere('Elbow skin',(sign*.64,-.015,1.70),(.113,.111,.115),skin))
    parts.append(sphere('Palm',(sign*.75,-.065,1.145),(.105,.07,.145),skin))
    for j in range(4):
        x=sign*(.665+j*.057)
        parts.append(sphere('Finger',(x,-.071,.997+.019*abs(j-1)),(.022,.030,.13-.012*abs(j-1)),skin))
    parts.append(sphere('Thumb',(sign*.654,-.084,1.13),(.048,.049,.093),skin))
    bpy.ops.object.select_all(action='DESELECT')
    for obj in parts:
        obj.select_set(True)
    bpy.context.view_layer.objects.active=parts[0]
    bpy.ops.object.join()
    obj=bpy.context.object
    obj.name='Continuous skinned arm '+side
    bpy.ops.object.transform_apply(location=True,rotation=True,scale=True)
    rem=obj.modifiers.new('Continuous skin union','REMESH')
    rem.mode='VOXEL'
    rem.voxel_size=.011
    bpy.ops.object.modifier_apply(modifier=rem.name)
    sm=obj.modifiers.new('Soft skin','SMOOTH')
    sm.factor=.6
    sm.iterations=3
    bpy.ops.object.modifier_apply(modifier=sm.name)
    for p in obj.data.polygons:
        p.use_smooth=True
    groups={bn:obj.vertex_groups.new(name=bn+'.'+side) for bn in ('upper_arm','forearm','hand')}
    for v in obj.data.vertices:
        z=v.co.z
        elbow=max(0,min(1,(z-1.64)/.13))
        hand_w=max(0,min(1,(1.35-z)/.18))
        weights={'upper_arm':elbow,'forearm':(1-elbow)*(1-hand_w),'hand':(1-elbow)*hand_w}
        for bn,w in weights.items():
            if w:
                groups[bn].add([v.index],w,'REPLACE')
    mod=obj.modifiers.new('Smooth anatomical deformation','ARMATURE')
    mod.object=rig
    mod.use_deform_preserve_volume=True
    sub=obj.modifiers.new('Skin finishing','SUBSURF')
    sub.levels=1
    # Sleeve follows shoulder; rounded overlap conceals the clothing seam.
    sleeve=sphere('T shirt sleeve '+side,(sign*.435,-.001,2.01),(.16,.164,.19),shirt)
    bind(sleeve,'upper_arm.'+side)

# Animate through target orientations with eased transitions, wrist follow-through,
# body counterbalance, head attention and real eyelid closure.
def ease(t):
    t=max(0,min(1,t))
    return t*t*t*(10+t*(-15+6*t))

for frame in range(1,145):
    seconds=(frame-1)/24
    lift=ease((seconds-.45)/.95)*(1-ease((seconds-4.15)/1.1))
    wave_window=ease((seconds-1.4)/.35)*(1-ease((seconds-3.85)/.35))
    wave=math.sin((seconds-1.5)*2*math.pi*1.25)*wave_window
    for bn,rot in [('spine',(0,math.sin(seconds*1.1)*.018,-lift*.035)),
                   ('head',(.015*math.sin(seconds*1.3),-lift*.06,lift*.035)),
                   ('upper_arm.R',(.012*math.sin(seconds*1.7),0,lift*.04))]:
        p=rig.pose.bones[bn]
        p.rotation_mode='XYZ'
        p.rotation_euler=rot
        p.keyframe_insert(data_path='rotation_euler',frame=frame)
    bpy.context.view_layer.update()
    def orient_bone(bn, origin, direction):
        rest_bone=arm_data.bones[bn]
        q=(rest_bone.tail_local-rest_bone.head_local).normalized().rotation_difference(direction.normalized())
        p=rig.pose.bones[bn]
        p.rotation_mode='QUATERNION'
        p.matrix=Matrix.Translation(origin) @ q.to_matrix().to_4x4() @ rest_bone.matrix_local.to_quaternion().to_matrix().to_4x4()
        p.keyframe_insert(data_path='location',frame=frame)
        p.keyframe_insert(data_path='rotation_quaternion',frame=frame)
        bpy.context.view_layer.update()
        return origin + direction.normalized()*rest_bone.length
    shoulder=Vector((-.37,0,2.11))
    upper_dir=Vector((-.27,-.015,-.41)).lerp(Vector((-.40,-.05,.16)),lift)
    elbow=orient_bone('upper_arm.L',shoulder,upper_dir)
    fore_dir=Quaternion(Vector((0,1,0)),lift*2.92) @ Vector((-.09,-.03,-.44))
    wrist=orient_bone('forearm.L',elbow,fore_dir)
    hand_dir=Quaternion(Vector((0,1,0)),lift*(3.0+wave*.18)) @ Vector((-.03,-.02,-.20))
    orient_bone('hand.L',wrist,hand_dir)
    blink=0
    for center in (1.03,3.35,5.45):
        d=seconds-center
        if -.095<d<.14:
            blink=max(blink,ease((d+.095)/.085)*(1-ease((d-.005)/.135)))
    for k in blink_keys:
        k.value=blink
        k.keyframe_insert(data_path='value',frame=frame)
    scene.frame_set(frame)

# Soft spotlight and a three-quarter frontal camera.
floor_mat=material('Midnight purple stage',(.024,.014,.052),.78)
bpy.ops.mesh.primitive_plane_add(size=200,location=(0,0,0))
smooth(bpy.context.object,floor_mat)
world=scene.world
world.use_nodes=True
world.node_tree.nodes['Background'].inputs[0].default_value=(.085,.06,.14,1)
world.node_tree.nodes['Background'].inputs[1].default_value=.35
def point_at(obj,co):
    obj.rotation_euler=(Vector(co)-obj.location).to_track_quat('-Z','Y').to_euler()
for name,loc,energy,size,color in [('Warm key',(-3,-4,6),420,4,(1,.83,.66)),('Soft fill',(3,-2,4),180,3,(.74,.83,1)),('Hair rim',(1,2,5),500,3,(.91,.78,1))]:
    data=bpy.data.lights.new(name,'AREA')
    data.energy,data.shape,data.size=energy,'DISK',size
    data.color=color
    obj=bpy.data.objects.new(name,data)
    bpy.context.collection.objects.link(obj)
    obj.location=loc
    point_at(obj,(0,0,2))
bpy.ops.object.camera_add(location=(.25,-8,3.2))
camera=bpy.context.object
point_at(camera,(-.08,0,1.96))
camera.data.type='ORTHO'
camera.data.ortho_scale=4.65
scene.camera=camera
scene.frame_set(58)
bpy.ops.wm.save_as_mainfile(filepath=str(OUT/'kai-motion-study.blend'))
scene.render.filepath=str(OUT/'kai-review.png')
bpy.ops.render.render(write_still=True)
if '--render-animation' in sys.argv:
    (OUT/'frames').mkdir(exist_ok=True)
    scene.render.filepath=str(OUT/'frames'/'kai-')
    bpy.ops.render.render(animation=True)
