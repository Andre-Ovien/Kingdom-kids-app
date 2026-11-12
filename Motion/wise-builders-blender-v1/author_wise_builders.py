"""Original Blender houses, foundations, storm motion and safe toy collapse.

No people are present inside the houses. All pieces stay in a small garden.
Run Blender --background --python this.py -- --render for native sources and PNGs.
"""
import argparse
import importlib.util
import math
import sys
from pathlib import Path
import bpy
from mathutils import Vector

HERE=Path(__file__).resolve().parent
REPO=HERE.parents[1]
OUT=REPO/'Frontend/mobile/assets/images/games/wise_builders'
spec=importlib.util.spec_from_file_location('creation_sculpture',HERE.parent/'creation-world-blender-v1/author_creation_world.py')
creation=importlib.util.module_from_spec(spec);spec.loader.exec_module(creation)
ark=creation.ark
mat,sphere,box=ark.material,ark.sphere,ark.rounded_box


def root(name):
    obj=bpy.data.objects.new(name,None);bpy.context.collection.objects.link(obj);return obj


def parent_new(before,name):
    parent=root(name)
    for obj in set(bpy.context.scene.objects)-before-{parent}:obj.parent=parent
    return parent


def mesh(name,vertices,faces,color):
    data=bpy.data.meshes.new(name);data.from_pydata(vertices,[],faces);data.update()
    obj=bpy.data.objects.new(name,data);bpy.context.collection.objects.link(obj);data.materials.append(color)
    bevel=obj.modifiers.new('Soft handmade edges','BEVEL');bevel.width=.025;bevel.segments=3
    obj.modifiers.new('Weighted normals','WEIGHTED_NORMAL')
    return obj


def opening(wall,location,scale):
    bpy.ops.mesh.primitive_cube_add(size=2,location=location);cutter=bpy.context.object;cutter.scale=scale
    mod=wall.modifiers.new('Architectural door and window opening','BOOLEAN');mod.operation='DIFFERENCE';mod.object=cutter
    bpy.context.view_layer.objects.active=wall
    bpy.ops.object.modifier_apply(modifier=mod.name)
    bpy.data.objects.remove(cutter,do_unlink=True)


def foundation(kind):
    before=set(bpy.context.scene.objects)
    if kind=='rock':
        stone=mat('Foundation solid blue grey rock',(.40,.53,.57))
        box('Broad flat rock foundation',(0,0,.09),(1.05,.83,.17),stone,.23)
        for x,y in ((-.92,-.68),(.95,-.65),(-.8,.63),(.75,.65)):
            sphere('Connected bedrock rounded shoulder',(x,y,.05),(.27,.27,.18),stone)
    else:
        sand=mat('Foundation soft golden sand',(.87,.66,.33))
        sphere('Sandy mound',(0,0,-.03),(1.22,1.04,.26),sand)
        for i in range(18):
            angle=i*2.4
            sphere('Loose rounded sand grains',(.9*math.cos(angle),.77*math.sin(angle),.05),(.075,.06,.04),mat('Light loose sand',(.96,.78,.46)))
    return parent_new(before,'Foundation_'+kind)


def house():
    groups={}
    plaster=mat('House warm ivory plaster',(.91,.82,.64))
    timber=mat('House honey timber',(.46,.25,.10))
    teal=mat('House teal door and shutters',(.10,.40,.40))
    roof=mat('House terracotta roof',(.63,.24,.105))
    for kind in ('back-wall','left-wall','right-wall','front-wall','roof','brace'):
        before=set(bpy.context.scene.objects)
        if kind in ('back-wall','front-wall'):
            y=.61 if kind=='back-wall' else -.61
            wall=box('Handmade '+kind,(0,y,.82),(.77,.075,.61),plaster,.035)
            mesh('House gable', [(-.77,y-.075,1.40),(.77,y-.075,1.40),(0,y-.075,1.98),
                                 (-.77,y+.075,1.40),(.77,y+.075,1.40),(0,y+.075,1.98)],
                 [(0,1,2),(3,5,4),(0,3,4,1),(0,2,5,3),(1,4,5,2)],plaster)
            if kind=='front-wall':
                opening(wall,(.22,y,.55),(.22,.20,.41))
                opening(wall,(-.40,y,.94),(.16,.20,.17))
                box('Painted door',(.22,y+.01,.54),(.20,.08,.39),teal,.035)
                sphere('Round door handle',(.34,y-.09,.55),(.025,.02,.025),mat('Warm door handle',(.93,.68,.17)))
                box('Dark window glass',(-.40,y+.01,.94),(.145,.02,.15),mat('Window sky glass',(.17,.37,.43)),.02)
                for x in (-.59,-.21):box('Window small shutter',(x,y-.035,.94),(.065,.025,.19),teal,.015)
                box('White window cross',(-.40,y-.10,.94),(.017,.017,.16),plaster,.008)
        elif kind in ('left-wall','right-wall'):
            x=-.77 if kind=='left-wall' else .77
            wall=box('Handmade '+kind,(x,0,.82),(.075,.61,.61),plaster,.035)
            opening(wall,(x,0,1.02),(.20,.18,.17))
            box('Side window inset',(x,0,1.02),(.02,.17,.16),mat('Window sky glass',(.17,.37,.43)),.015)
            box('Side window mullion',(x+.08,0,1.02),(.012,.018,.18),plaster,.004)
        elif kind=='roof':
            for side in (-1,1):
                panel=mesh('Joined roof slope',[(0,-.76,2.05),(0,.76,2.05),(side*.94,.76,1.36),(side*.94,-.76,1.36)],[(0,1,2,3)],roof)
                solid=panel.modifiers.new('Terracotta tile depth','SOLIDIFY');solid.thickness=.10
                for row in range(4):
                    z=2.05-(row+.35)*.69/4;x=side*(row+.35)*.94/4
                    beam=box('Roof tile course',(x,0,z+.015),(.017,.79,.018),mat('Roof tile warm edge',(.75,.32,.16)),.008)
            sphere('Soft ridge cap',(0,0,2.08),(.075,.82,.075),roof)
        else:
            for side in (-1,1):
                for ends in (((side*.85,-.48,.35),(side*.85,.48,1.30)),((side*.85,.48,.35),(side*.85,-.48,1.30))):
                    ark.beam_between('Storm brace timber',*ends,.09,.075,timber)
        groups[kind]=parent_new(before,'House_piece_'+kind)
    return groups


def visibility(groups, visible):
    for name,parent in groups.items():
        for obj in [parent,*parent.children_recursive]:obj.hide_render=name not in visible


def weather():
    groups={};before=set(bpy.context.scene.objects)
    cloud=mat('Storm soft slate clouds',(.39,.48,.60))
    for x,z,s in ((-.70,2.90,.34),(-.28,3.04,.43),(.18,2.99,.40),(.63,2.90,.31)):
        sphere('Raincloud connected puff',(x,.10,z),(s,.25,s*.5),cloud)
    cloudroot=parent_new(before,'Weather_cloud');groups['cloud']=cloudroot
    before=set(bpy.context.scene.objects)
    for index in range(40):
        x=-1.3+(index%8)*.37;y=-.85+(index//8)*.32;z=.2+(index%7)*.40
        drop=sphere('Blender rain drop',(x,y,z),(.015,.015,.09),mat('Rain pale blue',(.54,.75,.89)))
        drop.rotation_euler.y=-.18
        for frame in range(1,9):
            drop.location.z=(z-(frame-1)*.36)%2.8
            drop.location.x=x-(frame-1)*.025
            drop.keyframe_insert('location',frame=frame)
    groups['rain']=parent_new(before,'Weather_rain')
    before=set(bpy.context.scene.objects)
    for i in range(3):
        centers=[(-1.2+j*.42,.5,1.9-i*.55+math.sin(j*.7)*.09) for j in range(7)]
        arc=ark.tube('Soft wind ribbon',centers,[.016]*7,mat('Wind pearl ribbon',(.80,.90,.92)))
        for frame in range(1,9):
            arc.location.x=math.sin(math.tau*(frame-1)/8)*.35
            arc.keyframe_insert('location',frame=frame)
    groups['wind']=parent_new(before,'Weather_wind')
    return groups


def setup():
    bpy.ops.object.select_all(action='SELECT');bpy.ops.object.delete(use_global=False)
    scene=bpy.context.scene;scene.name='Wise Builders original house studio';ark.lighting()
    scene.render.resolution_x=scene.render.resolution_y=256
    ark.camera('House matched assembly camera',(4,-6,4.6),(0,0,1.1),3.75)
    groups=house();groups.update(rock=foundation('rock'),sand=foundation('sand'))
    groups.update(weather())
    visibility(groups,{'back-wall','left-wall','right-wall','front-wall','roof','brace','rock'})
    scene['provenance']='Original sculpted house architecture with boolean window/door openings, terracotta courses, structural braces, rock/sand foundations, keyed wind/rain and toy collapse. No occupants.'
    scene.frame_start=1;scene.frame_end=12
    HERE.mkdir(parents=True,exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=str(HERE/'wise-builders-source.blend'))
    return groups


def collapse(groups):
    for index,(kind,parent) in enumerate(groups.items()):
        if kind not in ('back-wall','left-wall','right-wall','front-wall','roof','brace','sand'):continue
        initial=parent.location.copy()
        for frame in range(1,13):
            t=(frame-1)/11;smooth=t*t*(3-2*t)
            parent.location=initial+Vector(((index%2-.5)*smooth*.48,smooth*.14,-smooth*.28))
            parent.rotation_euler=(smooth*(.15 if kind=='sand' else .45),smooth*(-.25 if index%2 else .70),smooth*.08)
            if kind=='sand':parent.scale=(1+smooth*.25,1+smooth*.30,1-smooth*.72)
            parent.keyframe_insert('location',frame=frame);parent.keyframe_insert('rotation_euler',frame=frame);parent.keyframe_insert('scale',frame=frame)


def landscape(cover=False):
    scene=bpy.data.scenes.new('Builders garden '+('cover' if cover else 'background'));bpy.context.window.scene=scene
    ark.lighting();scene.render.film_transparent=False
    scene.world.node_tree.nodes['Background'].inputs[0].default_value=(.74,.83,.84,1)
    ark.camera('Garden portrait camera',(0,-12,15),(0,.5,0),10.7)
    scene.render.resolution_x=800;scene.render.resolution_y=1000 if cover else 1280
    box('Whole garden island',(0,0,-.3),(6,8,.3),mat('Garden sunny grass',(.62,.76,.38)),.8)
    box('Garden house clearing',(0,-.5,.015),(4,2.4,.025),mat('Garden pale sand path',(.83,.76,.54)),.7)
    for x,y,s in ((-4,3,.85),(4,3,.9),(-4,-3,.65),(4,-3,.7)):creation.tree(x,y,s)
    sphere('Far garden hill',(-3,6,.2),(3,2,1.0),mat('Hill fresh green',(.48,.66,.31)))
    sphere('Far garden hill',(3.4,7,.1),(3.8,2,1.1),mat('Hill blue green',(.45,.65,.42)))
    if cover:
        for x,kind in ((-1.9,'rock'),(1.9,'sand')):
            groups=house();groups[kind]=foundation(kind)
            for parent in groups.values():parent.location.x+=x
    scene.render.filepath=str(OUT/('cover.png' if cover else 'background.png'));bpy.ops.render.render(write_still=True)


def native_preview():
    scene=bpy.data.scenes.new('Builders native storm experiment');bpy.context.window.scene=scene
    ark.lighting();scene.render.film_transparent=False
    ark.camera('Two house storm camera',(6,-11,7),(0,0,1),10)
    scene.render.resolution_x=1100;scene.render.resolution_y=800
    for x,kind in ((-2,'rock'),(2,'sand')):
        groups=house();groups[kind]=foundation(kind);weathergroups=weather();groups.update(weathergroups)
        if kind=='sand':collapse(groups)
        for parent in groups.values():
            parent.location.x+=x
            # The parent offset is separate from the collapse animation.
            if parent.animation_data:
                offset=root('Site translation '+kind);offset.location.x=x;parent.parent=offset;parent.location.x-=x
    box('Storm garden base',(0,0,-.32),(5,3,.22),mat('Rain darkening meadow',(.35,.52,.28)),.6)
    scene.frame_start=1;scene.frame_end=12;scene.render.fps=3
    scene['lesson']='Matthew 7:24–27. Children compare both houses in wind/rain; rock stands, soft sand washes away. Houses contain no people.'
    bpy.ops.wm.save_as_mainfile(filepath=str(HERE/'wise-builders-source.blend'))
    for frame in (1,6,12):
        scene.frame_set(frame);scene.render.filepath=str(HERE/f'review-storm-{frame:02d}.png');bpy.ops.render.render(write_still=True)


def render():
    groups=setup();OUT.mkdir(parents=True,exist_ok=True);scene=bpy.context.scene
    parts={'back-wall','left-wall','right-wall','front-wall','roof','brace'}
    for kind in (*parts,'rock','sand'):
        visibility(groups,{kind});scene.frame_set(1)
        scene.render.filepath=str(OUT/f'{kind}.png');bpy.ops.render.render(write_still=True)
    visibility(groups,parts);scene.render.filepath=str(OUT/'standing.png');bpy.ops.render.render(write_still=True)
    for storm in ('rain','wind','rain_and_wind'):
        visibility(groups,{'cloud'}|({'rain'} if storm=='rain' else {'wind'} if storm=='wind' else {'rain','wind'}))
        for frame in range(1,9):
            scene.frame_set(frame);path=HERE/'frames'/f'storm-{storm}-{frame}.png';path.parent.mkdir(exist_ok=True)
            scene.render.filepath=str(path);bpy.ops.render.render(write_still=True)
    visibility(groups,parts|{'sand'});collapse(groups)
    for frame in range(1,13):
        scene.frame_set(frame);scene.render.filepath=str(HERE/'frames'/f'collapse-{frame}.png');bpy.ops.render.render(write_still=True)
    landscape();landscape(True);native_preview()


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--render',action='store_true')
    opts=parser.parse_args(sys.argv[sys.argv.index('--')+1:] if '--' in sys.argv else [])
    if opts.render:render()
    else:setup()
