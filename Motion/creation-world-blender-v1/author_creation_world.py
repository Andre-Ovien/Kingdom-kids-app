"""Native Blender sculpture, keyed fish/bird motion and Creation tile exports.

Uses original Kingdom Kids Ark quadruped sculptures with attribution; every
other mesh, material, tile, creature and motion in this file is authored here.
Run Blender --background --python this.py -- --build or --render.
"""
import argparse
import importlib.util
import math
import sys
from pathlib import Path

import bpy
from mathutils import Vector

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
OUT = REPO / 'Frontend/mobile/assets/images/games/creation_world'
spec = importlib.util.spec_from_file_location('ark_sculpture', HERE.parent / 'ark-traffic-blender-v1/author_ark_traffic.py')
ark = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ark)
mat, sphere, box = ark.material, ark.sphere, ark.rounded_box


def root(name):
    obj = bpy.data.objects.new(name, None)
    bpy.context.collection.objects.link(obj)
    return obj


def attach(objects, parent):
    for obj in objects:
        obj.parent = parent
    return parent


def tree(x=0, y=0, scale=1, parent=None):
    parts = []
    bark = mat('Creation honey bark', (.36, .18, .075))
    leaves = [mat('Creation leaf ' + str(i), c) for i, c in enumerate(((.18,.45,.14),(.31,.61,.19),(.51,.71,.27)))]
    parts.append(sphere('Tapered living trunk', (x,y,.62*scale), (.11*scale,.11*scale,.65*scale), bark))
    for i, (dx,dy,z,s) in enumerate(((-.26,0,1.13,.40),(.25,.04,1.24,.40),(0,.05,1.58,.47))):
        parts.append(sphere('Soft tree canopy', (x+dx*scale,y+dy*scale,z*scale), (s*scale,s*scale,s*.86*scale), leaves[i]))
    if parent: attach(parts,parent)
    return parts


def tile(kind):
    parent = root('Piece_' + kind)
    earth = mat('Carved clay sides', (.54,.36,.22))
    top = {'empty': (.85,.76,.59), 'land': (.54,.76,.29), 'forest':(.42,.67,.25),'water':(.10,.61,.77)}[kind]
    cap = mat(kind + ' terrain surface', top)
    parts = [box('Chunky earth tile', (0,0,0), (.94,.94,.14), earth,.14),
             box('Soft ' + kind + ' cap', (0,0,.16), (.95,.95,.055), cap,.12)]
    if kind == 'water':
        ripples = mat('Sunlit river ripples', (.54,.91,.92))
        for i in range(3):
            parts.append(sphere('Water soft ripple',(-.48+i*.4,.18*math.sin(i*2),.225),(.25,.025,.008),ripples))
        parent['habitat'] = 'Water tiles connect through their four board neighbors; fish follow the connected river.'
    elif kind == 'forest':
        tree(-.23,.18,.62,parent)
        tree(.35,-.08,.46,parent)
        parent['habitat'] = 'Trees provide bird perches and occupy meadow space; rearranging them can open animal routes.'
    elif kind == 'land':
        for i in range(5):
            leaf = sphere('Meadow blade',(.60*math.cos(i*2.4),.60*math.sin(i*2.4),.25),(.035,.08,.06),mat('Meadow blade green',(.32,.56,.17)))
            leaf.rotation_euler.z=i
            parts.append(leaf)
    attach(parts,parent)
    return parent


def sky_piece(kind):
    parent = root('Piece_' + kind)
    if kind == 'cloud':
        white = mat('Cloud warm white', (.98,.99,1.0))
        parts = [sphere('Cloud connected puff', (x,0,z), (s,.30,s*.80), white)
                 for x,z,s in ((-.50,.35,.30),(-.15,.52,.42),(.25,.42,.36),(.55,.33,.28))]
    else:
        gold = mat('Creation sunlight', (1.,.64,.06))
        moon = mat('Creation moon pearl', (.86,.92,1.))
        parts = [sphere('Warm light orb' if kind != 'moon' else 'Pearl moon', (0,0,.65), (.48,.16,.48), moon if kind == 'moon' else gold)]
        if kind in ('sun','light'):
            for i in range(10):
                angle=math.tau*i/10
                ray=sphere('Rounded sunray',(.70*math.cos(angle),0,.65+.70*math.sin(angle)),(.10,.08,.18),gold)
                ray.rotation_euler.y=math.pi/2-angle
                parts.append(ray)
        else:
            for x,z,s in ((-.18,.76,.06),(.14,.94,.04),(.20,.44,.06)):
                parts.append(sphere('Moon crater',(x,-.15,z),(s,.025,s),mat('Moon crater silver',(.66,.76,.88))))
    attach(parts,parent)
    for f in range(1,10):
        parent.location.z=math.sin(math.tau*(f-1)/8)*.05
        parent.keyframe_insert('location',frame=f)
    return parent


def fin(name, vertices, color, parent):
    mesh=bpy.data.meshes.new(name)
    mesh.from_pydata(vertices, [], [tuple(range(len(vertices)))])
    mesh.update()
    obj=bpy.data.objects.new(name,mesh)
    bpy.context.collection.objects.link(obj)
    obj.data.materials.append(color)
    solid=obj.modifiers.new('Soft fin thickness','SOLIDIFY');solid.thickness=.045
    bevel=obj.modifiers.new('Soft fin edges','BEVEL');bevel.width=.035;bevel.segments=3
    obj.parent=parent
    return obj


def fish():
    parent=root('Piece_fish')
    coral=mat('Fish coral skin',(.96,.32,.12));gold=mat('Fish golden fins',(1.,.68,.15))
    parts=[sphere('Fish seamless body',(0,0,.46),(.58,.20,.28),coral),
           sphere('Fish muzzle',(.45,0,.46),(.24,.18,.20),coral)]
    for side in (-1,1):
        parts += [sphere('Fish pearl eye',(.44,side*.164,.56),(.10,.045,.10),mat('Eye pearl',(1.,.98,.87))),
                  sphere('Fish bright pupil',(.475,side*.196,.57),(.042,.018,.045),mat('Eye black',(.025,.037,.035)))]
    attach(parts,parent)
    tail=root('Fish tail hinge');tail.parent=parent;tail.location=(-.49,0,.45)
    fin('Fish flowing tail',[(0,0,0),(-.43,0,.28),(-.37,0,-.28)],gold,tail)
    fin('Fish dorsal fin',[(-.25,0,.69),(.10,0,.84),(.28,0,.65)],gold,parent)
    for side in (-1,1):
        fin('Fish curved pectoral fin',[(.12,side*.18,.47),(-.12,side*.35,.28),(-.20,side*.19,.44)],gold,parent)
    for f in range(1,10):
        tail.rotation_euler.z=math.sin(math.tau*(f-1)/8)*.38
        tail.keyframe_insert('rotation_euler',frame=f)
        parent.rotation_euler.z=math.sin(math.tau*(f-1)/8)*.06
        parent.keyframe_insert('rotation_euler',frame=f)
    parent['motion'] = 'Eight keyed tail strokes; mobile advances along connected neighboring water tiles.'
    return parent


def bird():
    parent=root('Piece_bird')
    blue=mat('Bluebird feather',(.08,.44,.72));belly=mat('Bluebird warm belly',(.96,.83,.54))
    parts=[sphere('Bluebird feathered body',(-.07,0,.48),(.39,.24,.32),blue),
           sphere('Bluebird breast',(.12,-.055,.42),(.25,.21,.23),belly),
           sphere('Bluebird rounded head',(.26,0,.76),(.24,.22,.24),blue)]
    for side in (-1,1):
        parts += [sphere('Bluebird dark eye',(.34,side*.18,.80),(.05,.025,.055),mat('Eye black',(.025,.037,.035)))]
    attach(parts,parent)
    fin('Bluebird natural beak',[(.44,-.07,.73),(.68,0,.71),(.44,.07,.73)],mat('Bird warm beak',(1.,.59,.08)),parent)
    fin('Bluebird tail feathers',[(-.32,-.12,.40),(-.71,0,.48),(-.32,.12,.40)],blue,parent)
    wings=[]
    for side in (-1,1):
        hinge=root('Bluebird wing hinge');hinge.parent=parent;hinge.location=(-.10,side*.19,.57)
        wing=sphere('Bluebird tapered wing',(-.19,side*.38,-.03),(.34,.20,.055),blue);wing.parent=hinge
        wings.append((hinge,side))
    for f in range(1,10):
        for hinge,side in wings:
            hinge.rotation_euler.x=side*(.25+math.sin(math.tau*(f-1)/8)*.80)
            hinge.keyframe_insert('rotation_euler',frame=f)
    parent['motion']='Eight keyed natural wing beats; birds land on placed forest tiles.'
    return parent


def show_only(pieces, kind):
    for name,parent in pieces.items():
        for obj in [parent,*parent.children_recursive]:obj.hide_render=name!=kind


def build():
    bpy.ops.object.select_all(action='SELECT');bpy.ops.object.delete(use_global=False)
    scene=bpy.context.scene;scene.name='Creation living world asset studio'
    ark.lighting();scene.render.fps=8
    ark.camera('Creation sculpture camera',(0,-6,7),(0,0,.38),3.0)
    scene.render.resolution_x=scene.render.resolution_y=224
    pieces={kind:tile(kind) for kind in ('empty','water','land','forest')}
    pieces.update({kind:sky_piece(kind) for kind in ('light','cloud','sun','moon')})
    pieces.update(fish=fish(),bird=bird())
    scene['provenance']='Original Blender Creation tiles, sky forms, fish sculpture and bird sculpture with native keyed fin/wing animations. Ark animal rigs reused from original Kingdom Kids source.'
    scene.frame_start=1;scene.frame_end=8
    show_only(pieces,'forest')
    HERE.mkdir(exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=str(HERE/'creation-world-source.blend'))
    return pieces


def background():
    scene=bpy.data.scenes.new('Creation open garden background');bpy.context.window.scene=scene
    ark.lighting();scene.render.film_transparent=False
    scene.world.node_tree.nodes['Background'].inputs[0].default_value=(.62,.84,.91,1)
    scene.render.resolution_x=800;scene.render.resolution_y=1280
    ark.camera('Portrait garden camera',(0,-12,16),(0,0,.1),11.8)
    box('Open garden base',(0,0,-.40),(6,8,.40),mat('Garden soft moss',(.73,.86,.52)),.9)
    box('Sunlit clearing',(0,-.5,-.02),(3.4,4.1,.03),mat('Garden pale clearing',(.83,.88,.64)),1.2)
    for x,y,s in [(-4,3,1.1),(-4,-2,.75),(4,2,.85),(4,-3,.95),(-4.4,5,.9),(3.9,5,1.1)]:tree(x,y,s)
    for i in range(7):
        sphere('Garden riverbank stone',(-4+i*1.4,5.9,.02),(.52,.30,.16),mat('Rounded warm stone',(.77,.72,.58)))
    scene.render.filepath=str(OUT/'background.png');bpy.ops.render.render(write_still=True)


def native_preview():
    """An editable Blender world, with the same board rules recorded as metadata."""
    scene=bpy.data.scenes.new('Creation completed world interactive preview');bpy.context.window.scene=scene
    ark.lighting();scene.render.film_transparent=False
    ark.camera('Living world orbit camera',(9,-13,14),(0,1,0),12)
    scene.render.resolution_x=1000;scene.render.resolution_y=800
    cells={'water':[0,5,10,15,1,2],'land':[3,4,8,9,13,14,18,19],'forest':[6,11]}
    for kind,indices in cells.items():
        for cell in indices:
            parent=tile(kind);parent.location=((cell%5-2)*1.85,(1.5-cell//5)*1.85,0)
    fish_root=fish();fish_root.scale=(.58,.58,.58)
    river=[0,5,10,15,10,5,0]
    for index,cell in enumerate(river):
        fish_root.location=((cell%5-2)*1.85,(1.5-cell//5)*1.85,.20)
        fish_root.keyframe_insert('location',frame=1+index*24)
    bird_root=bird();bird_root.scale=(.65,.65,.65)
    for frame,cell,lift in ((1,6,1.0),(25,11,2.2),(49,11,1.0),(73,6,2.2),(97,6,1.0)):
        bird_root.location=((cell%5-2)*1.85,(1.5-cell//5)*1.85,lift)
        bird_root.keyframe_insert('location',frame=frame)
    for species,cell in (('goat',3),('rabbit',19)):
        rig=getattr(ark,'build_'+species)();ark.animate(rig,species)
        rig.scale=(.55,.55,.55);rig.location=((cell%5-2)*1.85,(1.5-cell//5)*1.85,.22)
    scene.frame_end=145;scene.render.fps=24
    scene['interactive_preview']='Open preview.html for rule-aware placement; this native scene preserves original meshes, materials, creature actions and an editable completed world.'
    scene['constraints']='Four-neighbor connected river source0/outlet15; all meadow land connected; forests block ground routes; fish water/birds forests/goat+rabbit land.'
    bpy.ops.wm.save_as_mainfile(filepath=str(HERE/'creation-world-source.blend'))
    scene.render.filepath=str(HERE/'review-completed-world.png');bpy.ops.render.render(write_still=True)


def render():
    pieces=build();OUT.mkdir(parents=True,exist_ok=True)
    scene=bpy.context.scene
    for kind in pieces:
        show_only(pieces,kind)
        frames=range(1,9) if kind in ('fish','bird') else (1,)
        for frame in frames:
            scene.frame_set(frame)
            path=HERE/'frames'/f'{kind}-{frame}.png' if kind in ('fish','bird') else OUT/f'{kind}.png'
            path.parent.mkdir(parents=True,exist_ok=True)
            scene.render.filepath=str(path);bpy.ops.render.render(write_still=True)
    background();native_preview()


def main():
    args=argparse.ArgumentParser();args.add_argument('--build',action='store_true');args.add_argument('--render',action='store_true')
    opts=args.parse_args(sys.argv[sys.argv.index('--')+1:] if '--' in sys.argv else [])
    if opts.render:render()
    else:build()


if __name__=='__main__':main()
