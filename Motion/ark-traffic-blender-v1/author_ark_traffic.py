"""Original Ark rescue models, skin rigs, cycles and environment in Blender.

The engine draws the transparent exports over the map; no gameplay is baked.
Run Blender --background --python this.py -- --build, then --render-animals or
--render-world. Review exports stay here until their Blender source is approved.
"""
from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

import bpy
from mathutils import Vector
from bpy_extras.object_utils import world_to_camera_view

HERE = Path(__file__).resolve().parent
SPECIES = ('tortoise', 'elephant', 'goat', 'rabbit')
DIRS, FRAMES = 8, 8
FPS = 8
materials = {}


def material(name, color, roughness=.72):
    if name in materials:
        return materials[name]
    mat = bpy.data.materials.new(name)
    mat.diffuse_color = (*color, 1)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes.get('Principled BSDF')
    # Artist palettes are sRGB; the shader consumes linear light.
    linear = tuple(c / 12.92 if c <= .04045 else ((c + .055) / 1.055) ** 2.4 for c in color)
    bsdf.inputs['Base Color'].default_value = (*linear, 1)
    bsdf.inputs['Roughness'].default_value = roughness
    materials[name] = mat
    return mat


def mesh_finish(obj, name, mat, group=None, rig=None):
    obj.name = name
    obj.data.materials.append(mat)
    for polygon in obj.data.polygons:
        polygon.use_smooth = True
    if rig:
        modifier = obj.modifiers.new('Skin deformation', 'ARMATURE')
        modifier.object = rig
        obj.parent = rig
        vertex_group = obj.vertex_groups.new(name=group or 'root')
        vertex_group.add(list(range(len(obj.data.vertices))), 1, 'REPLACE')
    return obj


def sphere(name, location, scale, mat, rig=None, group='root', segments=24):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=segments, ring_count=16, location=location)
    obj = bpy.context.object
    obj.scale = scale
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    return mesh_finish(obj, name, mat, group, rig)


def rounded_box(name, location, scale, mat, bevel=.10):
    bpy.ops.mesh.primitive_cube_add(size=2, location=location)
    obj = bpy.context.object
    obj.name = name
    obj.scale = scale
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    modifier = obj.modifiers.new('Soft carved corners', 'BEVEL')
    modifier.width, modifier.segments = bevel, 3
    obj.modifiers.new('Weighted normals', 'WEIGHTED_NORMAL')
    obj.data.materials.append(mat)
    return obj


def tube(name, centers, radii, mat, rig=None, groups=None, sides=12):
    """Continuous tapered skin rather than articulated capsule primitives."""
    vertices, faces = [], []
    for i, (center, radius) in enumerate(zip(centers, radii)):
        tangent = Vector(centers[min(i + 1, len(centers) - 1)]) - Vector(centers[max(0, i - 1)])
        tangent.normalize()
        cross = tangent.cross(Vector((0, 1, 0)))
        if cross.length < .1:
            cross = tangent.cross(Vector((1, 0, 0)))
        cross.normalize()
        up = tangent.cross(cross).normalized()
        rx, ry = radius if isinstance(radius, tuple) else (radius, radius)
        for j in range(sides):
            a = math.tau * j / sides
            v = Vector(center) + cross * math.cos(a) * rx + up * math.sin(a) * ry
            vertices.append(tuple(v))
    for i in range(len(centers) - 1):
        for j in range(sides):
            a = i * sides + j
            b = i * sides + (j + 1) % sides
            faces.append((a, b, b + sides, a + sides))
    faces.append(tuple(reversed(range(sides))))
    faces.append(tuple((len(centers) - 1) * sides + j for j in range(sides)))
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata(vertices, [], faces)
    mesh.update()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    mesh_finish(obj, name, mat)
    sub = obj.modifiers.new('Organic skin subdivision', 'SUBSURF')
    sub.levels = sub.render_levels = 1
    if rig:
        obj.parent = rig
        modifier = obj.modifiers.new('Continuous limb skin', 'ARMATURE')
        modifier.object = rig
        for group in set(g for ring in groups for g, _ in ring):
            obj.vertex_groups.new(name=group)
        for i, weights in enumerate(groups):
            for group, weight in weights:
                obj.vertex_groups[group].add(list(range(i * sides, (i + 1) * sides)), weight, 'REPLACE')
    return obj


def bone(rig, name, head, tail, parent='root'):
    b = rig.data.edit_bones.new(name)
    b.head, b.tail = head, tail
    if parent:
        b.parent = rig.data.edit_bones[parent]
    return b


def rig_new(name, leg_x, leg_y, hip_height, knee_height):
    data = bpy.data.armatures.new(name + ' anatomical skeleton')
    rig = bpy.data.objects.new(name + ' walk rig', data)
    bpy.context.collection.objects.link(rig)
    bpy.context.view_layer.objects.active = rig
    rig.select_set(True)
    bpy.ops.object.mode_set(mode='EDIT')
    bone(rig, 'root', (0, 0, .25), (0, 0, 1), None)
    bone(rig, 'head', (.5, 0, hip_height), (1.1, 0, hip_height + .2))
    for row, x in zip(('front', 'back'), leg_x):
        for side, y in (('L', leg_y), ('R', -leg_y)):
            upper = row + '.' + side
            bone(rig, upper, (x, y, hip_height), (x, y, knee_height))
            bone(rig, upper + '.shin', (x, y, knee_height), (x + .025, y, .17), upper)
            bone(rig, upper + '.foot', (x + .025, y, .17), (x + .15, y, .12), upper + '.shin')
    bone(rig, 'ear.L', (.80, .13, hip_height + .3), (.86, .50, hip_height + .5), 'head')
    bone(rig, 'ear.R', (.80, -.13, hip_height + .3), (.86, -.50, hip_height + .5), 'head')
    bone(rig, 'trunk.1', (1.12, 0, hip_height + .2), (1.32, 0, hip_height - .2), 'head')
    bone(rig, 'trunk.2', (1.32, 0, hip_height - .2), (1.34, 0, .28), 'trunk.1')
    bone(rig, 'tail', (-.70, 0, hip_height), (-1.10, 0, hip_height - .1))
    bpy.ops.object.mode_set(mode='OBJECT')
    rig.select_set(False)
    rig['species'] = name
    rig['motion_note'] = 'Eight-pose diagonal walk: stance, toe-off, knee flexion, swing and planting. Four skinned legs.'
    return rig


def legs(rig, leg_x, leg_y, hip, knee, color, hoof, stout=.14, toes=False):
    for row, x in zip(('front', 'back'), leg_x):
        for side, y in (('L', leg_y), ('R', -leg_y)):
            key = row + '.' + side
            foot_z = .108 if stout > .12 else .075
            leg = tube(key + ' continuous leg and planted foot', [
                (x, y, hip + .06), (x, y, hip - .10),
                (x + .01, y, knee + .06), (x + .02, y, knee - .06),
                (x + .025, y, .22), (x + .04, y, foot_z + .03),
                (x + .13, y, foot_z), (x + .23, y, foot_z)],
                [stout * 1.16, stout, stout * .83, stout * .81, stout * .78,
                 (foot_z*.92, stout*.85), (foot_z*.96,stout*1.04), (foot_z*.30,stout*.66)], color, rig,
                [[(key, 1)], [(key, 1)], [(key, .65), (key + '.shin', .35)],
                 [(key, .25), (key + '.shin', .75)], [(key + '.shin', 1)],
                 [(key + '.shin', .5), (key + '.foot', .5)],
                 [(key + '.foot',1)], [(key + '.foot',1)]])
            leg.data.materials.append(hoof)
            for polygon in leg.data.polygons:
                if polygon.index >= 5 * 12 and polygon.index != 7 * 12:
                    polygon.material_index = 1
            if toes:
                for t in range(3):
                    sphere(key + ' toenail ' + str(t), (x + .20, y + (t - 1) * .067, .13),
                           (.025, .033, .038), material('Ivory toe', (.84, .86, .82)), rig, key + '.foot', 12)


def eyes(rig, x, y, z, size=.065):
    for side in (-1, 1):
        white = sphere('Kind eye white', (x, side * y, z), (size * .80, size * .40, size),
                       material('Warm eye whites', (.98, .97, .89)), rig, 'head')
        sphere('Dark chocolate eye', (x + size * .32, side * (y + size * .28), z + size * .015),
               (size * .47, size * .23, size * .62), material('Chocolate eyes', (.08, .065, .050)), rig, 'head')
        sphere('Eye catchlight', (x + size * .50, side * (y + size * .40), z + size * .29),
               (size * .13, size * .13, size * .15), material('Eye glints', (1, 1, 1)), rig, 'head', 12)


def ear_leaf(rig, name, center, size, mat, group):
    # Flattened, thick sculpted pinna, with an inset inner ear.
    sphere(name, center, size, mat, rig, group)
    inner = material('Warm inner ears', (.71, .45, .43))
    sphere(name + ' inner fold', (center[0] + size[0] * .45, center[1], center[2] + .015),
           (size[0] * .30, size[1] * .78, size[2] * .70), inner, rig, group)


def build_elephant():
    blue = material('Elephant soft blue gray', (.48, .62, .73))
    hoof = material('Elephant foot blue', (.44, .55, .65))
    rig = rig_new('elephant', (.44, -.46), .29, .91, .47)
    sphere('Elephant barrel chest', (-.06, 0, 1.01), (.78, .47, .53), blue, rig)
    sphere('Elephant forehead', (.76, 0, 1.32), (.46, .34, .47), blue, rig, 'head')
    sphere('Elephant cheeks', (.89, 0, 1.12), (.32, .32, .28), blue, rig, 'head')
    legs(rig, (.44, -.46), .29, .91, .47, blue, hoof, .155, True)
    for side, letter in ((1, 'L'), (-1, 'R')):
        ear_leaf(rig, 'Elephant broad floppy ear ' + letter, (.57, side * .38, 1.33),
                 (.12, .29, .43), blue, 'ear.' + letter)
        # A child-safe short curved tusk and a real trunk silhouette.
        tube('Ivory tusk ' + letter, [(1.03, side * .20, 1.05), (1.24, side * .22, .96),
             (1.35, side * .21, 1.02)], [.05, .036, .004], material('Soft ivory', (.94, .91, .77)), rig,
             [[('head', 1)]] * 3)
    tube('Elephant continuous curled trunk', [(1.06, 0, 1.29), (1.24, 0, 1.14),
         (1.33, 0, .87), (1.34, 0, .58), (1.39, 0, .32), (1.54, 0, .29), (1.62, 0, .38)],
         [.14, .125, .105, .080, .062, .054, .040], blue, rig,
         [[('head', 1)], [('trunk.1', 1)], [('trunk.1', .75), ('trunk.2', .25)],
          [('trunk.2', 1)], [('trunk.2', 1)], [('trunk.2', 1)], [('trunk.2', 1)]])
    tube('Elephant tail', [(-.77, 0, 1.10), (-.92, 0, .98), (-1.01, 0, .73)],
         [.037, .029, .020], blue, rig, [[('tail', 1)]] * 3)
    sphere('Elephant tail brush', (-1.01, 0, .71), (.057, .045, .093), hoof, rig, 'tail')
    eyes(rig, 1.0, .285, 1.39, .067)
    return rig


def build_tortoise():
    skin = material('Tortoise olive skin', (.46, .56, .29))
    dark = material('Shell dark green seams', (.18, .35, .20))
    scute = material('Shell moss gold panels', (.38, .52, .25))
    rim = material('Shell honey rim', (.67, .58, .28))
    rig = rig_new('tortoise', (.39, -.36), .29, .39, .25)
    sphere('Tortoise underside', (0, 0, .40), (.62, .43, .17), rim, rig)
    sphere('Tortoise domed shell', (-.04, 0, .55), (.67, .46, .35), dark, rig)
    # Raised overlapping scutes follow the shell surface, leaving real seam gaps.
    for row, x in enumerate((-.43, -.12, .20, .43)):
        for col, y in enumerate((-.23, 0, .23)):
            v = max(.12, 1 - ((x + .04) / .69) ** 2 - (y / .49) ** 2)
            z = .55 + .35 * math.sqrt(v)
            panel = sphere('Shell scute %s %s' % (row, col), (x, y, z), (.18, .135, .047), scute, rig, segments=16)
            panel.rotation_euler.y = (x + .04) * .65
            panel.rotation_euler.x = -y * .85
    sphere('Tortoise neck', (.60, 0, .39), (.28, .14, .13), skin, rig, 'head')
    sphere('Tortoise friendly head', (.84, 0, .43), (.25, .21, .20), skin, rig, 'head')
    sphere('Tortoise rounded beak', (1.01, 0, .39), (.13, .15, .075), rim, rig, 'head')
    legs(rig, (.39, -.36), .29, .39, .25, skin, skin, .085)
    eyes(rig, .94, .175, .50, .054)
    for side in (-1, 1):
        sphere('Tortoise nostril', (1.11, side * .055, .43), (.01, .014, .012), dark, rig, 'head', 12)
    tube('Tortoise tapering tail', [(-.62, 0, .35), (-.85, 0, .28)], [.062, .008], skin, rig, [[('tail', 1)]] * 2)
    return rig


def build_goat():
    coat = material('Goat warm cream coat', (.89, .83, .67))
    brown = material('Goat caramel markings', (.54, .34, .17))
    hoof = material('Goat charcoal hooves', (.20, .17, .13))
    rig = rig_new('goat', (.40, -.42), .20, .79, .42)
    sphere('Goat pear shaped body', (-.08, 0, .88), (.63, .32, .38), coat, rig)
    sphere('Goat chest ruff', (.47, 0, .97), (.24, .27, .38), coat, rig)
    sphere('Goat long muzzle head', (.72, 0, 1.26), (.36, .23, .28), coat, rig, 'head')
    sphere('Goat caramel muzzle', (1.01, 0, 1.15), (.18, .18, .12), brown, rig, 'head')
    sphere('Goat soft dark nose', (1.15, 0, 1.18), (.055, .11, .047), hoof, rig, 'head')
    legs(rig, (.40, -.42), .20, .79, .42, coat, hoof, .078)
    for side, letter in ((1, 'L'), (-1, 'R')):
        ear_leaf(rig, 'Goat leaf ear ' + letter, (.72, side * .29, 1.31), (.20, .14, .065), coat, 'ear.' + letter)
        tube('Goat curved horn ' + letter, [(.63, side * .13, 1.48), (.51, side * .16, 1.72), (.34, side * .18, 1.78)],
             [.066, .039, .006], material('Goat horn warm tan', (.52, .46, .32)), rig, [[('head', 1)]] * 3)
    eyes(rig, .87, .197, 1.36, .058)
    tube('Goat little beard', [(1.01, 0, 1.10), (.96, 0, .91), (.87, 0, .90)],
         [.070, .044, .003], coat, rig, [[('head', 1)]] * 3)
    tube('Goat lifted short tail', [(-.65, 0, .99), (-.81, 0, 1.20)], [.075, .025], coat, rig, [[('tail', 1)]] * 2)
    for i in range(4):
        sphere('Goat soft chest tuft', (.48 + .015 * i, .06 * (i - 1.5), .67),
               (.08, .054, .15), coat, rig)
    return rig


def build_rabbit():
    fur = material('Rabbit soft peach fur', (.89, .69, .58))
    cream = material('Rabbit creamy muzzle', (.99, .92, .82))
    rig = rig_new('rabbit', (.31, -.34), .20, .50, .29)
    sphere('Rabbit round belly', (-.15, 0, .64), (.55, .34, .38), fur, rig)
    sphere('Rabbit soft head', (.43, 0, .83), (.31, .28, .32), fur, rig, 'head')
    legs(rig, (.31, -.34), .20, .50, .29, fur, cream, .073)
    for side in (-1, 1):
        sphere('Rabbit strong hind haunch', (-.34, side * .20, .46), (.25, .16, .24), fur, rig, 'back.' + ('L' if side == 1 else 'R'))
        sphere('Rabbit muzzle cheek', (.68, side * .09, .72), (.13, .11, .105), cream, rig, 'head')
    for side, letter in ((1, 'L'), (-1, 'R')):
        ear_leaf(rig, 'Rabbit long ear ' + letter, (.40, side * .13, 1.24), (.095, .10, .39), fur, 'ear.' + letter)
    sphere('Rabbit pink button nose', (.795, 0, .765), (.045, .052, .036),
           material('Rabbit blush nose', (.70, .38, .35)), rig, 'head')
    eyes(rig, .60, .235, .90, .065)
    sphere('Rabbit fluffy tail', (-.67, 0, .66), (.14, .14, .14), cream, rig, 'tail')
    return rig


def animate(rig, species):
    amp = {'elephant': .36, 'tortoise': .40, 'goat': .44, 'rabbit': .40}[species]
    for frame in range(1, FRAMES + 2):
        t = math.tau * (frame - 1) / FRAMES
        for row in ('front', 'back'):
            for side in ('L', 'R'):
                # Diagonal support pairs move together. Hind knees trail front.
                phase = t + (0 if (row, side) in (('front', 'L'), ('back', 'R')) else math.pi)
                if row == 'back':
                    phase -= .18
                key = row + '.' + side
                upper, lower, foot = (rig.pose.bones[key + suffix] for suffix in ('', '.shin', '.foot'))
                for pb in (upper, lower, foot): pb.rotation_mode = 'XYZ'
                upper.rotation_euler.z = math.sin(phase) * amp
                lower.rotation_euler.z = max(0, math.cos(phase)) * amp * .75
                foot.rotation_euler.z = -upper.rotation_euler.z * .45 - lower.rotation_euler.z * .40
                for pb in (upper, lower, foot): pb.keyframe_insert('rotation_euler', frame=frame)
        root = rig.pose.bones['root']
        root.location.y = math.cos(t * 2) * (.007 if species == 'tortoise' else .015)
        root.keyframe_insert('location', frame=frame)
        head = rig.pose.bones['head']
        head.rotation_mode = 'XYZ'
        head.rotation_euler.z = math.sin(t) * .015
        head.keyframe_insert('rotation_euler', frame=frame)
        for name in ('ear.L', 'ear.R', 'tail', 'trunk.1', 'trunk.2'):
            pb = rig.pose.bones[name]
            pb.rotation_mode = 'XYZ'
            pb.rotation_euler.x = math.sin(t + (.2 if name.endswith('R') else 0)) * (.03 if 'ear' in name else .035)
            pb.keyframe_insert('rotation_euler', frame=frame)
    if rig.animation_data and rig.animation_data.action:
        rig.animation_data.action.name = species + ' coordinated quadruped walk'
    rig['walk_cycle_frames'] = FRAMES


def camera(name, location, target, scale):
    data = bpy.data.cameras.new(name)
    obj = bpy.data.objects.new(name, data)
    bpy.context.collection.objects.link(obj)
    obj.location = location
    obj.rotation_euler = (Vector(target) - obj.location).to_track_quat('-Z', 'Y').to_euler()
    data.type, data.ortho_scale = 'ORTHO', scale
    bpy.context.scene.camera = obj
    return obj


def lighting():
    scene = bpy.context.scene
    world = bpy.data.worlds.new('Warm sky') if not scene.world else scene.world
    scene.world = world
    world.use_nodes = True
    world.node_tree.nodes['Background'].inputs[0].default_value = (.70, .81, .88, 1)
    world.node_tree.nodes['Background'].inputs[1].default_value = .38
    for name, location, power, size in [('Soft sun', (-4, -6, 10), 900, 7), ('Warm rim', (4, 3, 6), 500, 6)]:
        data = bpy.data.lights.new(name, 'AREA')
        obj = bpy.data.objects.new(name, data)
        bpy.context.collection.objects.link(obj)
        obj.location = location
        obj.rotation_euler = (-obj.location).to_track_quat('-Z', 'Y').to_euler()
        data.energy, data.shape, data.size = power, 'DISK', size
    scene.render.engine = 'BLENDER_EEVEE_NEXT'
    scene.eevee.taa_render_samples = 32
    scene.render.image_settings.file_format = 'PNG'
    scene.render.image_settings.color_mode = 'RGBA'
    scene.render.film_transparent = True
    scene.render.fps = FPS
    scene.view_settings.view_transform = 'AgX'
    scene.view_settings.look = 'AgX - Medium High Contrast'
    scene.render.resolution_percentage = 100
    scene.render.image_settings.color_depth = '8'


def build():
    bpy.ops.object.select_all(action='SELECT')
    bpy.ops.object.delete(use_global=False)
    scene = bpy.context.scene
    scene.name = 'Ark animal studio'
    scene.render.resolution_x = scene.render.resolution_y = 224
    lighting()
    camera('Animal export camera', (3.8, -5.8, 6.8), (.12, 0, .74), 3.1)
    rigs = [build_tortoise(), build_elephant(), build_goat(), build_rabbit()]
    for rig, species in zip(rigs, SPECIES):
        animate(rig, species)
    scene.frame_start, scene.frame_end = 1, FRAMES
    scene['provenance'] = 'Original procedural mesh sculpture and authored anatomical four-leg rigs. No stock assets or generated raster art.'
    # Save all models and actions; the export routine hides three at a time.
    bpy.ops.wm.save_as_mainfile(filepath=str(HERE / 'ark-traffic-source.blend'))
    return rigs


def set_species(rigs, species):
    for rig in rigs:
        visible = rig['species'] == species
        rig.hide_render = not visible
        for child in rig.children_recursive:
            child.hide_render = not visible


def render_animals(rigs, only_species=None):
    scene = bpy.context.scene
    scene.render.resolution_x = scene.render.resolution_y = 224
    # Global positive X is right; heading0 faces right in the game.
    cam = scene.camera
    cam.location = (0, -5.8, 6.8)
    cam.rotation_euler = (Vector((0, 0, .73)) - cam.location).to_track_quat('-Z', 'Y').to_euler()
    cam.data.ortho_scale = 3.1
    manifest = {'version': 1, 'directions': DIRS, 'frames': FRAMES + 1, 'cell': 224,
                'foot_anchor': [112, 154], 'species': {}}
    for species in SPECIES:
        cam.data.ortho_scale = 3.55 if species == 'elephant' else 3.1
        bpy.context.view_layer.update()
        projected = world_to_camera_view(scene, cam, Vector((0,0,0)))
        anchor = [round(projected.x*224,3), round((1-projected.y)*224,3)]
        folder = HERE / 'frames' / species
        manifest['species'][species] = {'frames': str(folder.relative_to(HERE)), 'frame_count': DIRS * (FRAMES + 1), 'foot_anchor':anchor}
        if only_species and species != only_species:
            continue
        set_species(rigs, species)
        rig = next(r for r in rigs if r['species'] == species)
        folder.mkdir(parents=True, exist_ok=True)
        for direction in range(DIRS):
            # Canvas Y points down; the ground Y points away from the camera.
            rig.rotation_euler.z = -math.tau * direction / DIRS
            action = rig.animation_data.action
            rig.animation_data.action = None
            for pb in rig.pose.bones:
                pb.location = (0, 0, 0)
                pb.rotation_euler = (0, 0, 0)
            scene.render.filepath = str(folder / ('d%s-f00.png' % direction))
            bpy.ops.render.render(write_still=True)
            rig.animation_data.action = action
            for frame in range(1, FRAMES + 1):
                scene.frame_set(frame)
                path = folder / ('d%s-f%02d.png' % (direction, frame))
                scene.render.filepath = str(path)
                bpy.ops.render.render(write_still=True)
        rig.rotation_euler.z = 0
    (HERE / 'source-manifest.json').write_text(json.dumps(manifest, indent=2))


def map_point(x, y, z=0):
    # Exact orthographic mapping used by the Flutter graph.
    return ((x - .5) * 10, (.5 - y) * 15 / .8574929257, z)


def beam_between(name, a, b, width, depth, mat):
    av, bv = Vector(a), Vector(b)
    mid = (av + bv) / 2
    obj = rounded_box(name, mid, ((bv - av).length / 2, width / 2, depth / 2), mat, .045)
    obj.rotation_euler.z = math.atan2(bv.y - av.y, bv.x - av.x)
    return obj


def tree(name, x, y, scale=1):
    p = map_point(x, y)
    wood = material('Tree warm bark', (.36, .23, .11))
    green = material('Rounded treetop sage', (.27, .53, .30))
    tube(name + ' bent trunk', [(p[0], p[1], .1), (p[0] + .08, p[1], 1.0 * scale)], [.10 * scale, .074 * scale], wood)
    for offset, size in [((0, 0, 1.20), (.58, .48, .55)), ((.28, .04, 1.04), (.40, .36, .39)), ((-.28, -.02, 1.02), (.40, .36, .42))]:
        sphere(name + ' canopy', (p[0] + offset[0] * scale, p[1] + offset[1] * scale, offset[2] * scale),
               tuple(v * scale for v in size), green, segments=20)


def ark_model(ark_x, ark_y):
    wood = material('Ark cedar hull', (.56, .29, .12))
    edge = material('Ark golden planks', (.75, .46, .21))
    dark = material('Ark doorway shade', (.22, .12, .08))
    red = material('Ark terracotta roof', (.66, .28, .16))
    p = map_point(ark_x, ark_y)
    # Hull is a proper pointed boat with a broad rounded belly and raised prow.
    rings, vertices, faces = [], [], []
    for z, length, breadth in [(0, 1.7, .32), (.22, 2.05, .61), (.60, 2.22, .72), (.76, 2.25, .73)]:
        ring = []
        for j in range(32):
            angle = math.tau * j / 32
            ring.append(len(vertices))
            vertices.append((p[0] + length * math.cos(angle), p[1] + breadth * math.sin(angle), z))
        rings.append(ring)
    for i in range(len(rings) - 1):
        for j in range(32): faces.append((rings[i][j], rings[i][(j+1)%32], rings[i+1][(j+1)%32], rings[i+1][j]))
    faces.append(tuple(rings[0][::-1]))
    mesh = bpy.data.meshes.new('Ark handbuilt boat hull')
    mesh.from_pydata(vertices, [], faces)
    obj = bpy.data.objects.new('Ark pointed wooden hull', mesh)
    bpy.context.collection.objects.link(obj)
    mesh_finish(obj, obj.name, wood)
    rounded_box('Ark upper deck', (p[0], p[1], .76), (1.97, .63, .06), edge, .15)
    seam = material('Ark cedar plank seams', (.34,.17,.07))
    for z,length,breadth in ((.20,2.02,.59),(.38,2.13,.66),(.58,2.21,.71)):
        points=[(p[0]+length*math.cos(j*math.tau/64),p[1]+breadth*math.sin(j*math.tau/64),z) for j in range(65)]
        tube('Ark curved hull plank seam',points,[.013]*len(points),seam,sides=6)
    for j in range(24):
        angle=j*math.tau/24
        if math.sin(angle)<-.65 and math.cos(angle)>.05: continue
        q=(p[0]+1.98*math.cos(angle),p[1]+.65*math.sin(angle),.95)
        rounded_box('Ark individual deck rail post',q,(.026,.026,.20),edge,.015)
    railpoints=[(p[0]+1.98*math.cos(j*math.tau/64),p[1]+.65*math.sin(j*math.tau/64),1.15) for j in range(65)]
    tube('Ark continuous cedar deck rail',railpoints,[.030]*65,edge,sides=8)
    rounded_box('Ark two storey house', (p[0] - .10, p[1] + .10, 1.26), (1.28, .51, .47), edge, .04)
    for z in(.86,1.04,1.23,1.43,1.63):
        beam_between('Ark house wooden plank joint',(p[0]-1.36,p[1]-.415,z),(p[0]+1.16,p[1]-.415,z),.018,.018,seam)
    # Gabled roof with a continuous mesh and ridge, not an unexplained block.
    verts = [(p[0]+x, p[1]+y, z) for x,y,z in [(-1.50,-.56,1.73), (1.30,-.56,1.73), (-1.50,0,2.10), (1.30,0,2.10), (-1.50,.75,1.73), (1.30,.75,1.73)]]
    roof = bpy.data.meshes.new('Ark gabled roof mesh')
    roof.from_pydata(verts, [], [(0,1,3,2), (2,3,5,4), (0,2,4), (1,5,3)])
    robj = bpy.data.objects.new('Ark broad rain roof', roof)
    bpy.context.collection.objects.link(robj)
    mesh_finish(robj, robj.name, red)
    bevel = robj.modifiers.new('Roof edge bevel', 'BEVEL'); bevel.width=.045; bevel.segments=2
    for ix in range(5):
        rounded_box('Ark friendly upper window', (p[0] - 1.00 + ix*.45, p[1] - .423, 1.41), (.105,.02,.12), dark, .045)
    rounded_box('Ark open entrance', (p[0] + .68, p[1] - .433, 1.07), (.23,.03,.25), dark, .06)
    for ix in range(12):
        x=p[0]-1.42+ix*.24
        beam_between('Ark roof carved tile seam',(x,p[1]-.55,1.741),(x,p[1],2.107),.016,.016,wood)
    # Ramp is grounded at the exact gameplay destination; animals disappear
    # into the doorway and reappear as residents on the deck in Flutter.
    ramp = rounded_box('Ark boarding ramp', (p[0], p[1] - .61, .42), (.34,.64,.055), edge, .025)
    ramp.rotation_euler.x = .42


def build_world(config, level):
    scene = bpy.data.scenes.new('Ark traffic level %s environment' % level)
    bpy.context.window.scene = scene
    lighting()
    scene.render.film_transparent = False
    scene.render.resolution_x, scene.render.resolution_y = 960, 1440
    cam = camera('Map orthographic camera', (0, -18, 30), (0, 0, 0), 15)
    cam.data.sensor_fit = 'VERTICAL'
    grass = material('Meadow soft green', (.43,.67,.37))
    earth = material('Trail warm sand', (.77,.64,.40))
    mud = material('Rain softened earth', (.47,.34,.20))
    water = material('River gentle turquoise', (.15,.57,.66), .28)
    stone = material('Shortcut rounded stones', (.50,.55,.47))
    wood = material('Bridge honey cedar', (.64,.43,.21))
    rounded_box('Meadow base', (0,0,-.12), (6,10,.14), grass, .15)
    # Quiet river crossed by the routes, with banks visible under each bridge.
    river_y = map_point(.5,.49)[1]
    rounded_box('Soft turquoise river', (0,river_y,-.012), (6,1.22,.052), water, .35)
    for ix in range(15):
        sphere('Riverbank rounded pebbles', (-5.3+ix*.76, river_y+(-1 if ix%2 else 1)*1.20, .04),
               (.21,.12,.07), stone, segments=12)
    traffic = config['traffic']
    nodes = {n['id']: n for n in traffic['nodes']}
    for e in traffic['edges']:
        a, b = nodes[e['a']], nodes[e['b']]
        ap, bp = map_point(a['x'],a['y'],.055), map_point(b['x'],b['y'],.055)
        terrain = e['terrain']
        if e.get('route_group') in ('bridge','east') and min(a['y'],b['y']) < .49 < max(a['y'],b['y']):
            beam_between(e['id']+' timber deck',ap,bp,e['width']*10,.12,wood)
            delta=Vector(bp)-Vector(ap)
            side=Vector((-delta.y,delta.x,0)).normalized()*e['width']*5
            count=max(4,int(delta.length/.18))
            for index in range(count+1):
                point=Vector(ap)+delta*index/count
                point.z=.137
                cross=beam_between('Bridge individual plank',point-side,point+side,.026,.025,earth)
                for sign in (-1,1):
                    post=point+side*sign
                    rounded_box('Bridge little railing post',(post.x,post.y,.25),(.026,.026,.21),wood,.012)
            for sign in(-1,1): beam_between('Bridge safe rounded handrail',Vector(ap)+side*sign+Vector((0,0,.40)),Vector(bp)+side*sign+Vector((0,0,.40)),.045,.045,wood)
        elif terrain=='rocky':
            delta=Vector(bp)-Vector(ap)
            count=max(4,int(delta.length/.23))
            for index in range(count+1):
                point=Vector(ap)+delta*index/count
                sphere('Goat shortcut stepping rock',(point.x,point.y,.085),(.17,.14,.13),stone,segments=12)
        else:
            beam_between(e['id']+' broad walkable trail',ap,bp,e['width']*10,.03,mud if terrain=='mud' else earth)
            if terrain=='mud':
                delta=Vector(bp)-Vector(ap)
                for index in range(1,5):
                    point=Vector(ap)+delta*index/5
                    sphere('Mud puddle sheen',(point.x,point.y,.083),(.15,.20,.008),material('Mud shallow puddles',(.38,.37,.25),.22),segments=16)
    for n in nodes.values():
        p=map_point(n['x'],n['y'],.057)
        sphere('Junction soft sand',p,(.38,.40,.025),earth,segments=20)
    for e in traffic['edges']:
        if e.get('gate'):
            a,b=nodes[e['a']],nodes[e['b']]
            ap,bp=Vector(map_point(a['x'],a['y'])),Vector(map_point(b['x'],b['y']))
            point=(ap+bp)/2
            delta=(bp-ap).normalized(); side=Vector((-delta.y,delta.x,0))*e['width']*5
            for sign in(-1,1):
                q=point+side*sign
                rounded_box('Gate sculpted cedar post',(q.x,q.y,.32),(.065,.065,.32),wood,.04)
    ark=nodes[traffic['ark_node']]
    before=set(bpy.data.objects)
    ark_model(ark['x'],ark['y'])
    arkparts=set(bpy.data.objects)-before
    arkroot=bpy.data.objects.new('Map ark scale and dock anchor',None)
    bpy.context.collection.objects.link(arkroot)
    arkroot.location=map_point(ark['x'],ark['y'])
    bpy.context.view_layer.update()
    for obj in arkparts:
        obj.parent=arkroot
        obj.matrix_parent_inverse=arkroot.matrix_world.inverted()
    arkroot.scale=(.82,.82,.82)
    for i,(x,y,s) in enumerate([(.055,.20,.85),(.10,.33,.75),(.94,.34,.80),(.92,.69,.95),(.06,.90,.7),(.90,.90,.65),(.40,.08,.55)]): tree('Meadow tree %s'%i,x,y,s)
    flower=material('Tiny buttercup gold',(.94,.74,.23))
    for i in range(32):
        x=.04+(i*0.127)% .91; y=.65+(i*.081)% .30
        if min(math.hypot(x-n['x'],y-n['y']) for n in nodes.values())<.07: continue
        p=map_point(x,y,.06)
        sphere('Meadow buttercup',(p[0],p[1],.09),(.030,.027,.025),flower,segments=8)
    scene['graph_config'] = json.dumps(config)
    scene['projection_note']='Normalized gameplay points map exactly to the z=0 camera ground plane; ortho vertical span15, horizontal10.'
    return scene


def render_world():
    configs=json.loads((HERE/'traffic-levels.json').read_text())
    for scene in list(bpy.data.scenes):
        if scene.name.startswith('Ark traffic level '):
            bpy.data.scenes.remove(scene)
    for level in (1,2,3):
        config=configs[str(level)]
        scene=build_world(config,level)
        scene.render.filepath=str(HERE/'review'/('level-%s-background.png'%level))
        bpy.ops.render.render(write_still=True)
    bpy.ops.wm.save_as_mainfile(filepath=str(HERE/'ark-traffic-source.blend'))


def render_gate():
    for prior in list(bpy.data.scenes):
        if prior.name.startswith('Ark hinged gate states'):
            bpy.data.scenes.remove(prior)
    scene=bpy.data.scenes.new('Ark hinged gate states')
    bpy.context.window.scene=scene
    lighting()
    scene.render.resolution_x=scene.render.resolution_y=224
    camera('Gate sprite camera',(0,-5.8,6.8),(0,0,.30),1.9)
    wood=material('Gate warm cedar',(.64,.38,.16))
    hinge=bpy.data.objects.new('Gate left hinge',None)
    bpy.context.collection.objects.link(hinge)
    hinge.location=(-.60,0,0)
    bpy.context.view_layer.update()
    parts=[]
    for z in(.20,.53): parts.append(rounded_box('Gate cross rail',(0,0,z),(.60,.05,.047),wood,.025))
    for x in(-.52,-.26,0,.26,.52): parts.append(rounded_box('Gate soft upright',(x,0,.36),(.034,.052,.30),wood,.026))
    for obj in parts:
        obj.parent=hinge
        obj.matrix_parent_inverse=hinge.matrix_world.inverted()
    folder=HERE/'frames'/'gate'
    folder.mkdir(parents=True,exist_ok=True)
    for frame,angle in enumerate((0,-math.pi*.42)):
        hinge.rotation_euler.z=angle
        hinge.keyframe_insert('rotation_euler',frame=frame+1)
        scene.frame_set(frame+1)
        bpy.context.view_layer.update()
        scene.render.filepath=str(folder/('gate-f%s.png'%frame))
        bpy.ops.render.render(write_still=True)
    scene['provenance']='Original cedar gate model; closed/open exports from the same Blender hinge rig.'
    p=world_to_camera_view(scene,scene.camera,Vector((0,0,0)))
    manifest=json.loads((HERE/'source-manifest.json').read_text())
    manifest['gate']={'foot_anchor':[round(p.x*224,3),round((1-p.y)*224,3)]}
    (HERE/'source-manifest.json').write_text(json.dumps(manifest,indent=2))
    bpy.ops.wm.save_as_mainfile(filepath=str(HERE/'ark-traffic-source.blend'))


def project_anchors():
    scene=bpy.context.scene
    scene.render.resolution_x=scene.render.resolution_y=224
    cam=scene.camera
    cam.location=(0,-5.8,6.8)
    cam.rotation_euler=(Vector((0,0,.73))-cam.location).to_track_quat('-Z','Y').to_euler()
    manifest=json.loads((HERE/'source-manifest.json').read_text())
    for species in SPECIES:
        cam.data.ortho_scale=3.55 if species=='elephant' else 3.1
        bpy.context.view_layer.update()
        p=world_to_camera_view(scene,cam,Vector((0,0,0)))
        manifest['species'][species]['foot_anchor']=[round(p.x*224,3),round((1-p.y)*224,3)]
    (HERE/'source-manifest.json').write_text(json.dumps(manifest,indent=2))


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--build',action='store_true')
    parser.add_argument('--render-animals',action='store_true')
    parser.add_argument('--render-world',action='store_true')
    parser.add_argument('--render-gate',action='store_true')
    parser.add_argument('--only-species',choices=SPECIES)
    parser.add_argument('--project-anchors',action='store_true')
    opts=parser.parse_args(sys.argv[sys.argv.index('--')+1:] if '--' in sys.argv else [])
    if opts.build:
        rigs=build()
    else:
        bpy.ops.wm.open_mainfile(filepath=str(HERE/'ark-traffic-source.blend'))
        bpy.context.window.scene=bpy.data.scenes['Ark animal studio']
        rigs=[obj for obj in bpy.context.scene.objects if obj.type=='ARMATURE' and 'species' in obj]
    if opts.render_animals: render_animals(rigs,opts.only_species)
    if opts.render_world: render_world()
    if opts.render_gate: render_gate()
    if opts.project_anchors: project_anchors()


if __name__=='__main__': main()
