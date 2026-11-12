"""Five original Bible cover scenes, using the accepted CC0 Red Sea humans.

First review: Blender -b -t 4 --python build_covers.py -- --story lost-sheep --size 720
No old scene is edited. All new scenery, sheep, props and poses are native bpy.
"""
import bpy, sys, math, random, json
from pathlib import Path
from mathutils import Vector, Matrix
from mathutils.bvhtree import BVHTree

ROOT=Path(__file__).resolve().parent.parent
REPO=ROOT.parent.parent
SOURCE=REPO/'Motion/red-sea-blender-v1/red-sea-characters.blend'
ARGS=sys.argv[sys.argv.index('--')+1:] if '--' in sys.argv else []
def arg(name,default):
    return ARGS[ARGS.index(name)+1] if name in ARGS else default
STORY=arg('--story','lost-sheep')
SIZE=int(arg('--size','1024'))
SAMPLES=int(arg('--samples','64'))
random.seed(1240)
bpy.ops.wm.open_mainfile(filepath=str(SOURCE))
scene=bpy.context.scene
# Keep accepted human mesh/armature libraries; remove the original presentation.
library={}
fitted_people=[]
for index in range(3):
    library[index]=[o for o in bpy.data.objects if o.get('character_role')==f'traveller_{index}']
moses=bpy.data.objects.get('Moses armature')
def belongs_to(obj,ancestor):
    while obj:
        if obj==ancestor:return True
        obj=obj.parent
    return False
library[3]=[o for o in bpy.data.objects if belongs_to(o,moses)]
for obj in list(bpy.data.objects):
    if not any(obj in group for group in library.values()):
        bpy.data.objects.remove(obj,do_unlink=True)
for objects in library.values():
    for obj in objects:
        obj.hide_render=True
        obj.hide_set(True)
scene.render.engine='BLENDER_EEVEE_NEXT'
scene.eevee.taa_render_samples=SAMPLES
scene.render.film_transparent=False
scene.render.resolution_x=SIZE
scene.render.resolution_y=SIZE
scene.render.resolution_percentage=100
scene.render.image_settings.file_format='PNG'
scene.render.image_settings.color_mode='RGB'
scene.view_settings.view_transform='AgX'
scene.view_settings.look='AgX - Medium High Contrast'
scene.use_nodes=False
scene.frame_set(1)

def material(name,color,rough=.7,metal=0):
    m=bpy.data.materials.new(name);m.use_nodes=True
    b=m.node_tree.nodes.get('Principled BSDF')
    b.inputs['Base Color'].default_value=(*color,1)
    b.inputs['Roughness'].default_value=rough
    b.inputs['Metallic'].default_value=metal
    return m
grass=material('Meadow / soft living green',(.075,.27,.025))
grass_far=material('Far hills / sage',(.15,.32,.09))
ochre=material('Path / pale warm earth',(.53,.34,.15),.95)
rock=material('Rock / warm limestone',(.32,.29,.22),.94)
wood=material('Props / warm natural wood',(.20,.075,.018),.85)
olive=material('Olive leaf / silver green',(.22,.31,.105),.85)
olive_dark=material('Olive leaf / shaded green',(.08,.16,.045),.9)
wool=material('Sheep / natural ivory wool',(.79,.75,.62),.96)
skin_sheep=material('Sheep / soft brown muzzle',(.24,.18,.12),.88)
hoof=material('Sheep / dark natural hoof',(.045,.029,.018),.9)
eye=material('Animals / dark warm eye',(.015,.011,.008),.25)
eye_light=material('Animals / tiny eye catchlight',(.98,.93,.79),.2)
nodes=wool.node_tree.nodes;links=wool.node_tree.links
noise=nodes.new('ShaderNodeTexNoise');noise.inputs['Scale'].default_value=55
noise.inputs['Detail'].default_value=3
bump=nodes.new('ShaderNodeBump');bump.inputs['Strength'].default_value=.35;bump.inputs['Distance'].default_value=.018
links.new(noise.outputs['Fac'],bump.inputs['Height']);links.new(bump.outputs['Normal'],nodes.get('Principled BSDF').inputs['Normal'])

def finish(obj,mat,bevel=0):
    obj.data.materials.append(mat)
    if bevel:
        mod=obj.modifiers.new('Soft finished edges','BEVEL');mod.width=bevel;mod.segments=3
        obj.modifiers.new('Clean corner normals','WEIGHTED_NORMAL')
    return obj
def cube(name,loc,dims,mat,bevel=.04):
    bpy.ops.mesh.primitive_cube_add(size=1,location=loc);o=bpy.context.object;o.name=name;o.dimensions=dims
    bpy.ops.object.transform_apply(location=False,rotation=False,scale=True)
    return finish(o,mat,bevel)
def ellipsoid(name,loc,scale,mat,sub=2):
    bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=sub,radius=1,location=loc)
    o=bpy.context.object;o.name=name;o.scale=scale
    for p in o.data.polygons:p.use_smooth=True
    return finish(o,mat)
def curve(name,coords,bevel,mat):
    d=bpy.data.curves.new(name,'CURVE');d.dimensions='3D';d.resolution_u=12;d.bevel_depth=bevel;d.bevel_resolution=4
    s=d.splines.new('BEZIER');s.bezier_points.add(len(coords)-1)
    for p,co in zip(s.bezier_points,coords):p.co=co;p.handle_left_type='AUTO';p.handle_right_type='AUTO'
    o=bpy.data.objects.new(name,d);scene.collection.objects.link(o);d.materials.append(mat);return o
def mesh(name,verts,faces,mat):
    d=bpy.data.meshes.new(name);d.from_pydata(verts,[],faces);d.update()
    o=bpy.data.objects.new(name,d);scene.collection.objects.link(o);finish(o,mat)
    for p in d.polygons:p.use_smooth=True
    return o
def bone_direction(rig,name,head,tail):
    p=rig.pose.bones[name];rest=p.bone.matrix_local
    q=(rest.to_3x3()@Vector((0,1,0))).rotation_difference(Vector(tail)-Vector(head))
    p.matrix=Matrix.Translation(Vector(head))@q.to_matrix().to_4x4()@rest.to_3x3().to_4x4()
    bpy.context.view_layer.update()
def arm(rig,side,hand,pole):
    start=rig.pose.bones['upperarm_'+side].head.copy();hand=Vector(hand)
    upper=rig.data.bones['upperarm_'+side].length;lower=rig.data.bones['lowerarm_'+side].length
    axis=hand-start;distance=min(axis.length,upper+lower-.004);axis.normalize();hand=start+axis*distance
    p=Vector(pole)-start;p-=axis*p.dot(axis);p.normalize()
    along=(upper*upper-lower*lower+distance*distance)/(2*distance)
    elbow=start+axis*along+p*math.sqrt(max(0,upper*upper-along*along))
    bone_direction(rig,'upperarm_'+side,start,elbow)
    bone_direction(rig,'lowerarm_'+side,elbow,hand)
    bone_direction(rig,'hand_'+side,hand,hand+Vector((0,-.025,-.045)))
    return hand
def leg(rig,side,ankle,pole):
    start=rig.pose.bones['thigh_'+side].head.copy();ankle=Vector(ankle)
    upper=rig.data.bones['thigh_'+side].length;lower=rig.data.bones['calf_'+side].length
    axis=ankle-start;distance=min(axis.length,upper+lower-.002);axis.normalize();ankle=start+axis*distance
    p=Vector(pole)-start;p-=axis*p.dot(axis);p.normalize()
    along=(upper*upper-lower*lower+distance*distance)/(2*distance)
    knee=start+axis*along+p*math.sqrt(max(0,upper*upper-along*along))
    bone_direction(rig,'thigh_'+side,start,knee);bone_direction(rig,'calf_'+side,knee,ankle)
    rest=rig.data.bones['foot_'+side]
    bone_direction(rig,'foot_'+side,ankle,ankle+(rest.tail_local-rest.head_local))
    return knee
def human(index,name,loc,angle=0,cloth=(.12,.25,.25),scale=1):
    originals=library[index];copies={}
    for src in originals:
        obj=src.copy()
        if src.data is not None:obj.data=src.data.copy()
        scene.collection.objects.link(obj);obj.name=name+' / '+src.name
        obj.hide_render=False;obj.hide_set(False);obj.animation_data_clear();copies[src]=obj
    for src,obj in copies.items():
        if src.parent in copies:obj.parent=copies[src.parent]
        for mod in obj.modifiers:
            if mod.type=='ARMATURE' and mod.object in copies:mod.object=copies[mod.object]
    rig=next(o for o in copies.values() if o.type=='ARMATURE')
    rig.location=loc;rig.rotation_euler=(0,0,angle);rig.scale=(scale,scale,scale)
    for pb in rig.pose.bones:pb.matrix_basis=Matrix.Identity(4)
    bpy.context.view_layer.update()
    robe=next(o for o in copies.values() if 'woven robe' in o.name)
    body=next(o for o in copies.values() if 'anatomical body' in o.name)
    fitted_people.append((robe,body))
    robe.data.materials.clear();robe.data.materials.append(material(name+' / woven garment',cloth,.92))
    # Tailor oversized source kimono sleeves around the anatomical arm axes.
    # Preserve woven folds and the shoulder joint rather than merely scaling
    # the whole character or hiding the deformation with a large robe.
    group_names={group.index:group.name for group in robe.vertex_groups}
    for vertex in robe.data.vertices:
        weights={group_names[g.group]:g.weight for g in vertex.groups if g.group in group_names}
        candidates=[(weights.get(bone,0),bone) for bone in
                    ['upperarm_l','lowerarm_l','upperarm_r','lowerarm_r']]
        weight,bone=max(candidates)
        if weight>.25:
            b=rig.data.bones[bone];axis=b.tail_local-b.head_local
            t=max(0,min(1,(vertex.co-b.head_local).dot(axis)/axis.length_squared))
            if bone.startswith('upperarm') and t<.34:
                continue  # retain anatomical shoulder-cap clearance
            center=b.head_local+axis*t;radial=vertex.co-center
            clearance=.090 if bone.startswith('upperarm') else .065
            if radial.length>clearance:
                desired=clearance+(radial.length-clearance)*.68
                vertex.co=center+radial.normalized()*desired
    for side,sign in [('l',1),('r',-1)]:
        shoulder=rig.data.bones['upperarm_'+side].head_local
        arm(rig,side,(sign*.27,-.07,shoulder.z-.51),(sign*.39,.01,shoulder.z-.23))
        for finger in ('index','middle','ring','pinky'):
            for segment in ('01','02','03'):
                pb=rig.pose.bones[f'{finger}_{segment}_{side}'];pb.rotation_mode='XYZ';pb.rotation_euler[0]=.18
    return rig,copies,robe
def freeze_ground_cloth(robe):
    bpy.context.view_layer.update()
    evaluated=robe.evaluated_get(bpy.context.evaluated_depsgraph_get())
    data=bpy.data.meshes.new_from_object(evaluated);transform=robe.matrix_world.copy()
    for vertex in data.vertices:
        world=transform@vertex.co
        if world.z<.025:
            world.z=.009+.009*(1+math.sin(world.x*17+world.y*11))
            vertex.co=transform.inverted()@world
    robe.modifiers.clear();robe.data=data;robe.parent=None;robe.matrix_world=transform
def fit_cloth_clearance(robe,body):
    """Keep tailored cloth just outside the actual posed anatomical surface."""
    deps=bpy.context.evaluated_depsgraph_get()
    evaluated_body=body.evaluated_get(deps)
    skin_mesh=evaluated_body.to_mesh()
    points=[body.matrix_world@v.co for v in skin_mesh.vertices]
    bvh=BVHTree.FromPolygons(points,[list(face.vertices) for face in skin_mesh.polygons],all_triangles=False)
    evaluated_body.to_mesh_clear()
    evaluated=robe.evaluated_get(deps)
    data=bpy.data.meshes.new_from_object(evaluated);transform=robe.matrix_world.copy();inverse=transform.inverted()
    for vertex in data.vertices:
        world=transform@vertex.co
        closest,normal,_,distance=bvh.find_nearest(world)
        if closest is not None and distance<.13 and (world-closest).dot(normal)<.012:
            world=closest+normal*.012
        if world.z<.012:world.z=.012
        vertex.co=inverse@world
    robe.modifiers.clear();robe.data=data;robe.parent=None;robe.matrix_world=transform
def relaxed_fingers(rig,amount=.09):
    for side in ['l','r']:
        for finger in ['index','middle','ring','pinky']:
            for segment in ['01','02','03']:
                p=rig.pose.bones[f'{finger}_{segment}_{side}'];p.rotation_mode='XYZ';p.rotation_euler[0]=amount
def kneel(rig):
    leg(rig,'r',(-.14,.35,.395),(-.15,-.30,.50))
    leg(rig,'l',(.16,-.27,.37),(.18,-.55,.82))
def gray_hair(copies):
    for obj in copies.values():
        if obj.type=='MESH' and ('hair' in obj.name.lower() or 'afro' in obj.name.lower()):
            materials=[]
            for original in obj.data.materials:
                m=original.copy();materials.append(m)
                if not m.use_nodes:continue
                b=next((n for n in m.node_tree.nodes if n.type=='BSDF_PRINCIPLED'),None)
                if not b:continue
                for link in list(b.inputs['Base Color'].links):m.node_tree.links.remove(link)
                b.inputs['Base Color'].default_value=(.35,.33,.29,1)
            obj.data.materials.clear()
            for m in materials:obj.data.materials.append(m)
def sheep(name,loc=(0,0,0),scale=1,angle=0,carried=False):
    root=bpy.data.objects.new(name,None);scene.collection.objects.link(root);root.location=loc;root.scale=(scale,)*3;root.rotation_euler[2]=angle
    items=[]
    items.append(ellipsoid(name+' / continuous wool body',(0,0,.57),(.43,.22,.28),wool,3))
    items.append(ellipsoid(name+' / chest',(.29,0,.66),(.18,.18,.22),wool,3))
    items.append(ellipsoid(name+' / head',(.43,0,.77),(.20,.13,.18),skin_sheep,3))
    items.append(ellipsoid(name+' / soft muzzle',(.56,-.01,.73),(.115,.095,.086),skin_sheep,3))
    items.append(ellipsoid(name+' / nose',(.651,-.012,.745),(.015,.061,.030),hoof,2))
    for side in (-1,1):
        e=ellipsoid(name+' / ear',(.39,side*.17,.82),(.115,.055,.031),skin_sheep,2);e.rotation_euler=(side*.22,0,side*.18);items.append(e)
        items.append(ellipsoid(name+' / eye',(.51,side*.109,.805),(.021,.016,.022),eye,2))
        items.append(ellipsoid(name+' / catchlight',(.517,side*.122,.813),(.006,.005,.006),eye_light,2))
    for x in (-.255,.25):
        for y in (-.135,.135):
            endz=.31 if carried else .055
            endx=x-.04 if carried else x
            endy=-.50 if carried and y<0 else y-.018
            items.append(ellipsoid(name+' / upper wool leg',(x,y,.43),(.065,.06,.13),wool,2))
            items.append(curve(name+' / continuous leg',[(x,y,.45),(x+.015,endy*.45,.30),(endx,endy,endz)],.045,skin_sheep))
            items.append(ellipsoid(name+' / cloven hoof',(endx,endy,endz-.016),(.052,.049,.05),hoof,2))
    items.append(curve(name+' / short wool tail',[(-.40,0,.63),(-.49,0,.59),(-.46,0,.53)],.058,wool))
    for obj in items:obj.parent=root
    return root

def land():
    # One continuous low-relief meadow, with a broad winding footpath.
    verts=[];faces=[];N=60
    for j in range(N+1):
        y=-5+22*j/N
        for i in range(N+1):
            x=-15+30*i/N
            z=.018*math.sin(x*.6)*math.cos(y*.65)+max(0,y-2)*.024*math.sin(x*.28+y*.15)
            verts.append((x,y,z-.022))
    for j in range(N):
        for i in range(N):k=j*(N+1)+i;faces.append((k,k+1,k+N+2,k+N+1))
    mesh('Continuous meadow',verts,faces,grass)
    for x,y,sx,sy,sz in [(-6,13,10,7,1.3),(6,16,9,7,2.1),(-9,22,11,8,3.2)]:
        ellipsoid('Soft distant hill',(x,y,0),(sx,sy,sz),grass_far,4)
    verts=[];faces=[]
    for j in range(46):
        y=-5+j*.48;x=1.45+1.3*math.sin(y*.37);width=.24+.004*j+.035*math.sin(j*.7)
        verts.extend([(x-width+.035*math.sin(j*1.9),y,.011),
                      (x+width+.03*math.cos(j*1.7),y,.012)])
    for j in range(45):faces.append((2*j,2*j+1,2*j+3,2*j+2))
    mesh('Winding warm footpath',verts,faces,ochre)

def tree(name,loc,size=1):
    x,y,z=loc
    curve(name+' / trunk',[(x,y,z),(x+.07*size,y,z+.8*size),(x-.10*size,y+.03*size,z+1.65*size)],.08*size,wood)
    for a in range(5):
        theta=a*math.tau/5
        tip=Vector((x+math.cos(theta)*.65*size,y+math.sin(theta)*.55*size,z+1.9*size))
        curve(name+' / living branch',[(x,y,z+.9*size),(x+math.cos(theta)*.3*size,y+math.sin(theta)*.3*size,z+1.6*size),tip],.036*size,wood)
    # Native leaf geometry builds an airy canopy instead of a stack of spheres.
    verts=[];faces=[]
    for i in range(550):
        a=random.random()*math.tau;r=math.sqrt(random.random())*.94*size
        px=x+math.cos(a)*r;py=y+math.sin(a)*r*.78
        pz=z+(1.70+.56*(1-r/(.94*size))+random.uniform(-.18,.18))*size
        length=random.uniform(.075,.125)*size;angle=random.random()*math.tau
        u=Vector((math.cos(angle),math.sin(angle),random.uniform(-.4,.4)))*length
        v=Vector((-math.sin(angle),math.cos(angle),0))*length*.27
        center=Vector((px,py,pz));k=len(verts)
        verts.extend([center-u,center+v+Vector((0,0,.014*size)),center+u,center-v])
        faces.append((k,k+1,k+2,k+3))
    o=mesh(name+' / individual silver-green leaves',verts,faces,olive);o.data.materials.append(olive_dark)
    for p in o.data.polygons:p.material_index=random.randrange(2)

def flowers():
    yellow=material('Wildflower / soft golden yellow',(.83,.55,.085))
    pale=material('Wildflower / pale ivory',(.89,.81,.63))
    for center in [(-1.3,-.95),(.85,-.85),(1.9,.95),(-2.1,1.2),(.1,2.7)]:
        for i in range(12):
            x=center[0]+random.uniform(-.25,.25);y=center[1]+random.uniform(-.20,.20)
            z=.055+random.random()*.11
            curve('Wildflower / stem',[(x,y,0),(x+.012,y,z)],.004,olive_dark)
            for a in range(5):
                theta=a*math.tau/5
                petal=ellipsoid('Wildflower / soft petal',(x+.019*math.cos(theta),y+.019*math.sin(theta),z),(.022,.012,.009),yellow if i%3 else pale,2)
                petal.rotation_euler[2]=theta
            ellipsoid('Wildflower / warm center',(x,y,z+.005),(.012,.012,.009),ochre,2)
        for i in range(30):
            x=center[0]+random.uniform(-.33,.33);y=center[1]+random.uniform(-.27,.27)
            h=random.uniform(.08,.22);direction=random.uniform(0,math.tau)
            dx=.03*math.cos(direction);dy=.03*math.sin(direction)
            mesh('Meadow / curved grass blade',[(x-.006,y,0),(x+.006,y,0),(x+dx+.003,y+dy,h*.6),(x+dx,y+dy,h)],[(0,1,2,3)],olive_dark)

def lights_and_camera(target=(0,0,1.05),camloc=(3.3,-6.5,3.0),ortho=4.25):
    world=bpy.data.worlds.new('Soft morning blue sky');scene.world=world;world.use_nodes=True
    n=world.node_tree.nodes;n.get('Background').inputs['Color'].default_value=(.075,.31,.68,1);n.get('Background').inputs['Strength'].default_value=.65
    def area(name,loc,energy,color,size):
        data=bpy.data.lights.new(name,'AREA');data.energy=energy;data.color=color;data.shape='DISK';data.size=size
        obj=bpy.data.objects.new(name,data);scene.collection.objects.link(obj);obj.location=loc
        obj.rotation_euler=(Vector(target)-obj.location).to_track_quat('-Z','Y').to_euler()
    area('Morning / warm broad key',(-3,-4,6),550,(1,.83,.59),4.5)
    area('Sky / gentle cool fill',(4,-2,4),210,(.61,.80,1),5)
    area('Sun / golden rim',(-1,4,5),600,(1,.67,.33),3)
    data=bpy.data.lights.new('Sun / bright warm morning','SUN');data.energy=2.0;data.color=(1,.88,.66);data.angle=.13
    sun=bpy.data.objects.new('Sun / bright warm morning',data);scene.collection.objects.link(sun);sun.rotation_euler=(.45,-.5,-.45)
    data=bpy.data.cameras.new('Locked story cover camera');data.type='PERSP';data.lens=56
    camera=bpy.data.objects.new('Locked story cover camera',data);scene.collection.objects.link(camera);scene.camera=camera;camera.location=camloc
    camera.rotation_euler=(Vector(target)-camera.location).to_track_quat('-Z','Y').to_euler()
    data.dof.use_dof=True;data.dof.aperture_fstop=5.6
    focus=bpy.data.objects.new('Cover / gentle foreground focus',None);scene.collection.objects.link(focus);focus.location=target;data.dof.focus_object=focus

land()
if STORY=='lost-sheep':
    rig,copies,robe=human(0,'Shepherd',(-.47,-.12,-.34),angle=-.04,cloth=(.36,.18,.07))
    # A supported kneel: one knee rests near the earth, the other foot is planted.
    leg(rig,'r',(-.14,.35,.395),(-.15,-.30,.50))
    leg(rig,'l',(.16,-.27,.37),(.18,-.55,.82))
    arm(rig,'l',(.49,-.23,.965),(.38,-.31,1.12))
    staff_hand=arm(rig,'r',(-.34,-.16,1.13),(-.42,-.18,1.24))
    bone_direction(rig,'hand_l',(.49,-.23,.965),(.51,-.26,.93))
    for side in ['l','r']:
        for finger in ['index','middle','ring','pinky']:
            for segment in ['01','02','03']:
                pb=rig.pose.bones[f'{finger}_{segment}_{side}'];pb.rotation_euler[0]=.09 if side=='l' else .56
    head=rig.pose.bones['head'];head.rotation_mode='XYZ';head.rotation_euler=(.13,-.10,-.08)
    bpy.context.view_layer.update()
    # Bake just the still garment after skeletal deformation, then let its hem
    # gather softly on the ground; no cloth or knees disappear beneath terrain.
    freeze_ground_cloth(robe)
    staff=curve('Shepherd / curved wooden staff',[(-.84,-.31,.015),(-.80,-.28,.70),(-.76,-.24,1.36),(-.69,-.22,1.46),(-.61,-.23,1.43),(-.60,-.24,1.32)],.021,wood)
    sheep('Found sheep',(.28,-.30,.01),scale=.70,angle=-.15)
    for i,(x,y) in enumerate([(-1.3,4.4),(-.48,5.3),(.75,4.7),(1.5,5.6),(-2.1,6.4)]):
        sheep('Flock '+str(i),(x,y,.01),.64,angle=random.uniform(-.7,.7))
    tree('Right olive tree',(2.5,1.8,0),1.16)
    tree('Far olive tree',(-2.7,6.4,.02),.88)
    for loc,scale in [((-1.2,-.4,.09),(.26,.20,.14)),((1.45,.8,.10),(.31,.23,.16)),((1.62,.69,.055),(.13,.11,.085))]:
        ellipsoid('Meadow limestone',loc,scale,rock,2)
    flowers()
    lights_and_camera(target=(.10,.28,.82),camloc=(1.9,-4.3,1.88),ortho=3.3)
elif STORY=='joseph-colorful-coat':
    joseph,objects,robe=human(2,'Youthful Joseph',(-.40,-.22,0),angle=.16,cloth=(.21,.30,.24),scale=1.07)
    father,father_objects,father_robe=human(3,'Jacob',(.30,.10,0),angle=-.12,cloth=(.17,.23,.25),scale=.98)
    # Retain the accepted elder's beard, but remove Moses-specific staff props.
    for obj in father_objects.values():
        if 'staff' in obj.name.lower():obj.hide_render=True
    coat=material('Joseph / colorful woven coat',(.12,.36,.29),.88)
    n=coat.node_tree.nodes;l=coat.node_tree.links
    a=n.new('ShaderNodeAttribute');a.attribute_name='cloth_rest_position'
    separate=n.new('ShaderNodeSeparateXYZ');l.new(a.outputs['Vector'],separate.inputs['Vector'])
    wave=n.new('ShaderNodeMath');wave.operation='MULTIPLY';wave.inputs[1].default_value=6.5;l.new(separate.outputs['Z'],wave.inputs[0])
    fract=n.new('ShaderNodeMath');fract.operation='FRACT';l.new(wave.outputs[0],fract.inputs[0])
    ramp=n.new('ShaderNodeValToRGB');ramp.color_ramp.interpolation='CONSTANT'
    colors=[(.045,.35,.30),(.72,.23,.09),(.68,.48,.06),(.24,.09,.32)]
    ramp.color_ramp.elements.remove(ramp.color_ramp.elements[1])
    for i,c in enumerate(colors):
        e=ramp.color_ramp.elements[0] if i==0 else ramp.color_ramp.elements.new(i/4)
        e.color=(*c,1)
    l.new(fract.outputs[0],ramp.inputs['Fac']);l.new(ramp.outputs['Color'],n.get('Principled BSDF').inputs['Base Color'])
    robe.data.materials.clear();robe.data.materials.append(coat)
    relaxed_fingers(joseph,.11);relaxed_fingers(father,.12)
    arm(father,'r',(-.43,-.18,1.16),(-.45,-.12,1.30))
    for rig,rotation in [(joseph,(.03,.23,0)),(father,(.13,-.30,0))]:
        head=rig.pose.bones['head'];head.rotation_mode='XYZ';head.rotation_euler=rotation
    tree('Family olive tree',(-2.4,2.4,0),1.1)
    tree('Orchard olive tree',(2.6,5.7,0),.8)
    # A warm family courtyard gives the coat scene its own narrative setting.
    stone=material('Courtyard / warm sandstone',(.54,.38,.21),.9)
    for i in range(8):cube('Courtyard / low stone wall',(-2.4+i*.6,3,.30),(.57,.3,.59),stone,.065)
    flowers();lights_and_camera(target=(.1,.3,1.05),camloc=(2,-5.6,2.2))
elif STORY=='good-samaritan':
    traveler,objects,robe=human(0,'Resting traveler',(-.54,-.06,-.45),angle=.20,cloth=(.09,.22,.31))
    helper,helper_objects,helper_robe=human(0,'Caring Samaritan',(.58,-.25,-.34),angle=-.22,cloth=(.35,.14,.055))
    leg(traveler,'r',(-.16,-.50,.49),(-.14,-.51,.78))
    leg(traveler,'l',(.16,-.46,.49),(.14,-.52,.80))
    kneel(helper)
    arm(traveler,'l',(.40,-.20,1.0),(.37,-.06,1.13))
    arm(helper,'r',(-.56,-.19,1.0),(-.51,-.15,1.19))
    for rig,rotation in [(traveler,(.14,.30,0)),(helper,(.17,-.30,0))]:
        head=rig.pose.bones['head'];head.rotation_mode='XYZ';head.rotation_euler=rotation
    relaxed_fingers(traveler,.10);relaxed_fingers(helper,.10)
    freeze_ground_cloth(robe);freeze_ground_cloth(helper_robe)
    # A clean bandage, with no wounds, distress, weapons or graphic imagery.
    bandage=material('Care / clean ivory bandage',(.86,.81,.67),.94)
    wrist=traveler.matrix_world@traveler.pose.bones['hand_l'].head
    cuff=ellipsoid('Care / soft bandage at wrist',wrist,(.069,.062,.070),bandage,3)
    ellipsoid('Traveler / supportive smooth rock',(-.57,.35,.28),(.45,.25,.30),rock,3)
    clay=material('Care / warm terracotta water jar',(.42,.17,.065),.78)
    ellipsoid('Care / small water flask',(.17,-.54,.16),(.12,.12,.17),clay,3)
    cube('Care / folded cloth',(.03,-.56,.08),(.28,.18,.10),bandage,.035)
    stone=material('Inn / sunlit limestone',(.57,.43,.28),.95)
    cube('Inn / distant welcoming wall',(2.4,4.2,1.0),(2.0,.65,2.0),stone,.08)
    cube('Inn / timber doorway',(2.4,3.85,.65),(.65,.035,1.25),wood,.035)
    tree('Roadside olive tree',(-2.7,2.7,0),1.2)
    flowers();lights_and_camera(target=(.1,.0,.86),camloc=(2,-4.8,1.95))
elif STORY=='walls-of-jericho':
    joshua,joshua_objects,joshua_robe=human(0,'Joshua',(-.67,-.1,0),angle=-.38,cloth=(.32,.14,.045))
    priest,priest_objects,priest_robe=human(0,'Priest with shofar',(.38,.35,0),angle=-.30,cloth=(.52,.49,.35))
    second,second_objects,second_robe=human(1,'Marching Israelite',(1.25,.85,0),angle=-.32,cloth=(.10,.30,.24),scale=.92)
    for rig in [joshua,priest,second]:
        for side,sign in [('l',1),('r',-1)]:
            ankle=rig.data.bones['calf_'+side].tail_local.copy()+Vector((0,-.13*sign,.035 if sign==1 else 0))
            leg(rig,side,ankle,(sign*.16,-.30,.60))
    relaxed_fingers(joshua,.1)
    arm(priest,'r',(-.08,-.29,1.46),(-.35,-.21,1.42));relaxed_fingers(priest,.18)
    horn_mat=material('Shofar / natural warm horn',(.42,.26,.11),.47)
    origin=priest.matrix_world@Vector((-.08,-.30,1.48))
    curve('Priest / slender curved shofar',[origin,origin+Vector((.13,-.01,.02)),origin+Vector((.26,.03,.07)),origin+Vector((.32,.06,.15))],.023,horn_mat)
    tip=origin+Vector((.32,.06,.15));direction=Vector((.08,.03,.11)).normalized()
    u=direction.cross(Vector((0,1,0))).normalized();v=direction.cross(u).normalized()
    verts=[];faces=[];N=32
    for center,radius in [(tip-direction*.07,.026),(tip,.055),(tip-direction*.005,.043)]:
        verts.extend([center+radius*(u*math.cos(k*math.tau/N)+v*math.sin(k*math.tau/N)) for k in range(N)])
    for k in range(N):
        j=(k+1)%N;faces.extend([(k,j,j+N,k+N),(k+N,j+N,j+2*N,k+2*N)])
    mesh('Priest / hollow horn bell and rim',verts,faces,horn_mat)
    sandstone=material('Jericho / warm stone',(.54,.35,.16),.88)
    for row in range(7):
        for i in range(17):
            cube('Jericho / staggered stone block',(-5+i*.63+(.31 if row%2 else 0),3.45,.20+row*.34),(.60,.42,.32),sandstone,.045)
    for x in [-3.7,2.7]:
        cube('Jericho / square watch tower',(x,3.5,1.57),(.94,.8,3.12),sandstone,.05)
        for c in range(3):cube('Jericho / tower battlement',(x-.32+c*.32,3.48,3.2),(.21,.75,.26),sandstone,.025)
    covenant=material('Ark / warm gold covering',(.52,.34,.09),.6,.25)
    cube('March / covered covenant ark',(-.25,1.85,.80),(.88,.48,.48),covenant,.045)
    for y in [1.60,2.10]:curve('March / ark carrying pole',[(-1.0,y,.74),(.60,y,.74)],.022,wood)
    flowers();lights_and_camera(target=(.15,.75,1.25),camloc=(2.2,-6.3,2.40))
elif STORY=='ruth-and-naomi':
    ruth,ruth_objects,ruth_robe=human(1,'Ruth',(-.42,-.10,-.34),angle=.20,cloth=(.11,.29,.26))
    kneel(ruth);arm(ruth,'l',(.46,-.24,.90),(.38,-.30,1.12));relaxed_fingers(ruth,.12)
    freeze_ground_cloth(ruth_robe)
    naomi,naomi_objects,naomi_robe=human(1,'Older Naomi',(.95,1.05,-.30),angle=-.16,cloth=(.24,.13,.26),scale=.90)
    leg(naomi,'r',(-.15,-.40,.34),(-.14,-.50,.72));leg(naomi,'l',(.15,-.40,.34),(.14,-.50,.72))
    gray_hair(naomi_objects);relaxed_fingers(naomi,.10)
    arm(naomi,'r',(-.18,-.13,.86),(-.32,-.13,1.06));arm(naomi,'l',(.18,-.13,.86),(.32,-.13,1.06))
    freeze_ground_cloth(naomi_robe)
    ellipsoid('Naomi / low resting stone',(.95,1.25,.21),(.35,.26,.23),rock,3)
    straw=material('Harvest / golden barley',(.68,.43,.07),.85)
    stalk=material('Harvest / warm green stalk',(.32,.36,.055),.91)
    def grain(x,y,height):
        curve('Barley / slender stem',[(x,y,0),(x+.015,y,height)],.004,stalk)
        for j in range(4):
            for side in [-1,1]:
                e=ellipsoid('Barley / paired grain',(x+side*.014,y,height-.07+j*.027),(.013,.010,.024),straw,1)
                e.rotation_euler[1]=side*.35
        curve('Barley / long soft awn',[(x,y,height+.005),(x+.01,y,height+.14)],.0014,straw)
    for i in range(230):
        x=random.uniform(-2.1,2.0);y=random.uniform(-.8,4.2)
        if -.8<x<1.4 and -.6<y<1.65:continue
        grain(x,y,random.uniform(.36,.66))
    for i in range(8):grain(.10+random.uniform(-.06,.06),-.27+random.uniform(-.04,.04),random.uniform(.44,.55))
    # Woven basket has an open mouth, actual ribs and gathered grain inside.
    basket_material=material('Basket / warm willow',(.34,.17,.048),.85)
    for h in range(9):
        z=.04+h*.022;r=.13+z*.35
        coords=[(.22+r*math.cos(a*math.tau/24),-.53+r*.76*math.sin(a*math.tau/24),z) for a in range(25)]
        curve('Basket / continuous woven ring',coords,.010,basket_material)
    for k in range(20):
        a=k*math.tau/20
        curve('Basket / upright rib',[(.22+.14*math.cos(a),-.53+.105*math.sin(a),.03),(.22+.21*math.cos(a),-.53+.16*math.sin(a),.23)],.007,basket_material)
    for i in range(12):
        e=ellipsoid('Basket / gathered barley',(.22+random.uniform(-.12,.12),-.53+random.uniform(-.08,.08),.21),(.065,.023,.018),straw,2)
        e.rotation_euler[2]=random.random()*math.pi
    tree('Harvest / olive tree',(-2.6,3.8,0),1.1)
    lights_and_camera(target=(.13,.28,.93),camloc=(2,-5.25,2.05))
else:raise ValueError('Unknown Bible story cover')

# Fit final posed sleeve/shoulder surfaces to maintain anatomical clearance.
for robe,body in fitted_people:fit_cloth_clearance(robe,body)

# Do not retain the hidden source libraries in exported scenes.
for objects in library.values():
    for obj in objects:bpy.data.objects.remove(obj,do_unlink=True)
scene['Story']=STORY
scene['Human source']='Accepted Red Sea CC0 MPFB humans; every human uses African dark-skin source.'
scene['Art provenance']='Native Blender meshes, fitted garments, armatures, authored poses and original environments. No imagegen or downloaded illustrations.'
bpy.ops.file.pack_all()
bpy.ops.wm.save_as_mainfile(filepath=str(ROOT/'source'/f'{STORY}.blend'))
scene.render.filepath=str(ROOT/'review'/f'{STORY}-hero.png')
bpy.ops.render.render(write_still=True)
print('STORY_COVER_COMPLETE',STORY,scene.render.filepath,flush=True)
