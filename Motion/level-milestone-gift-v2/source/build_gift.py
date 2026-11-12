"""A wrapped gift that shakes, releases, and becomes separate settled panels.

Blender 4.5, original meshes; no stock safe/chest or external art assets.
Review first: Blender -b -t 4 --python build_gift.py -- --review
After approval: Blender -b -t 4 --python build_gift.py -- --runtime
"""
import bpy, math, sys, json
from pathlib import Path
from mathutils import Vector

ROOT=Path(__file__).resolve().parent.parent
ARGS=sys.argv[sys.argv.index('--')+1:] if '--' in sys.argv else []
bpy.ops.object.select_all(action='SELECT');bpy.ops.object.delete(use_global=False)
scene=bpy.context.scene;scene.render.engine='BLENDER_EEVEE_NEXT'
scene.eevee.taa_render_samples=48
scene.render.image_settings.file_format='PNG';scene.render.image_settings.color_mode='RGBA'
scene.render.resolution_percentage=100;scene.render.fps=24;scene.frame_start=1;scene.frame_end=96
scene.view_settings.view_transform='AgX';scene.view_settings.look='AgX - Medium High Contrast'
scene.render.film_transparent=False
scene.world.color=(.015,.025,.04)
def material(name,color,rough=.55,metal=0):
    m=bpy.data.materials.new(name);m.use_nodes=True;m.diffuse_color=(*color,1)
    b=m.node_tree.nodes.get('Principled BSDF');b.inputs['Base Color'].default_value=(*color,1)
    b.inputs['Roughness'].default_value=rough;b.inputs['Metallic'].default_value=metal
    return m
coral=material('Wrapping / warm coral',(.89,.20,.115),.62)
coral_side=material('Wrapping / coral shaded sides',(.73,.145,.082),.66)
mint=material('Wrapping / fresh mint',(.075,.51,.35),.58)
ivory=material('Paper / warm ivory inside',(.82,.74,.56),.9)
gold=material('Ribbon / soft golden satin',(.96,.61,.16),.28,.55)
gold_dark=material('Ribbon / underside satin',(.62,.35,.055),.45,.35)
pattern=material('Wrapping / small soft mint stars',(.64,.75,.47),.7)
navy=material('Review / navy stage',(.007,.02,.03),.73)
for paper in [coral,coral_side,mint]:
    nodes=paper.node_tree.nodes;links=paper.node_tree.links
    noise=nodes.new('ShaderNodeTexNoise');noise.inputs['Scale'].default_value=170;noise.inputs['Detail'].default_value=1
    bump=nodes.new('ShaderNodeBump');bump.inputs['Strength'].default_value=.1;bump.inputs['Distance'].default_value=.001
    links.new(noise.outputs['Fac'],bump.inputs['Height']);links.new(bump.outputs['Normal'],nodes.get('Principled BSDF').inputs['Normal'])

def empty(name,loc=(0,0,0),parent=None):
    o=bpy.data.objects.new(name,None);scene.collection.objects.link(o);o.location=loc;o.parent=parent;return o
motion=empty('Gift / unified anticipation')
def cube(name,loc,dims,mat,bevel=.015,parent=None):
    bpy.ops.mesh.primitive_cube_add(size=1,location=loc);o=bpy.context.object;o.name=name;o.dimensions=dims
    bpy.ops.object.transform_apply(location=False,rotation=False,scale=True)
    o.data.materials.append(mat)
    if bevel:
        mod=o.modifiers.new('Soft paper edge','BEVEL');mod.width=bevel;mod.segments=3
        o.modifiers.new('Clean planar normals','WEIGHTED_NORMAL')
    o.parent=parent
    return o
def panel(name,pivot,loc,dims,outer,inner_axis,inner_direction):
    root=empty(name+' / independent release pivot',pivot,motion)
    o=cube(name+' / thin cardboard and paper',loc,dims,outer,.018,root)
    o.data.materials.append(ivory)
    # Mesh normals choose the actual interior surface, rather than tinting an
    # entire solid cube. The revealed panel has a visible ivory paper reverse.
    for face in o.data.polygons:
        if face.normal[inner_axis]*inner_direction>.9:face.material_index=1
    return root,o
front,_=panel('Front coral panel',(0,-.84,.04),(0,0,.76),(2.4,.045,1.52),coral,1,1)
rear,_=panel('Rear coral panel',(0,.84,.04),(0,0,.76),(2.4,.045,1.52),coral,1,-1)
left,_=panel('Left coral panel',(-1.19,0,.04),(0,0,.76),(.045,1.65,1.52),coral_side,0,1)
right,_=panel('Right coral panel',(1.19,0,.04),(0,0,.76),(.045,1.65,1.52),coral_side,0,-1)
base,_=panel('Base mint panel',(0,0,.035),(0,0,0),(2.4,1.7,.045),mint,2,1)
lid,_=panel('Top mint paper lid',(0,0,1.58),(0,0,0),(2.47,1.77,.065),mint,2,-1)

# Ribbon sections belong to the physical panel they wrap and travel with it.
for root,sign in [(front,-1),(rear,1)]:
    cube('Ribbon / vertical front-back section',(0,sign*.033,.76),(.22,.020,1.55),gold,.006,root)
for root,sign in [(left,-1),(right,1)]:
    cube('Ribbon / vertical side section',(sign*.033,0,.76),(.020,.22,1.55),gold,.006,root)
cube('Ribbon / top across width',(0,0,.044),(2.48,.22,.018),gold,.006,lid)
cube('Ribbon / top across depth',(0,0,.056),(.22,1.78,.018),gold,.006,lid)

def ribbon(name,points,width,parent=lid,twist=0):
    # Catmull-Rom gives a continuous strip with a true width and thin reverse.
    controls=[Vector(p) for p in points];verts=[];faces=[]
    for k in range((len(controls)-1)*12+1):
        segment=min(len(controls)-2,k//12);t=(k-segment*12)/12
        p0=controls[max(0,segment-1)];p1=controls[segment];p2=controls[segment+1];p3=controls[min(len(controls)-1,segment+2)]
        p=.5*((2*p1)+(-p0+p2)*t+(2*p0-5*p1+4*p2-p3)*t*t+(-p0+3*p1-3*p2+p3)*t*t*t)
        # Bow/tail width rolls gently with the tape, instead of using round tubes.
        angle=twist*math.sin(k/((len(controls)-1)*12)*math.pi)
        across=Vector((0,math.cos(angle),math.sin(angle)))*width*.5
        verts.extend([p-across,p+across])
        if k:faces.append((2*k-2,2*k-1,2*k+1,2*k))
    data=bpy.data.meshes.new(name);data.from_pydata(verts,[],faces);data.update()
    obj=bpy.data.objects.new(name,data);scene.collection.objects.link(obj);obj.parent=parent
    data.materials.append(gold);data.materials.append(gold_dark)
    for face in data.polygons:face.use_smooth=True
    solid=obj.modifiers.new('Actual satin tape thickness','SOLIDIFY');solid.thickness=.012;solid.material_offset=1
    bevel=obj.modifiers.new('Soft satin edges','BEVEL');bevel.width=.004;bevel.segments=2
    return obj

ribbon('Bow / left continuous folded loop',[(0,0,.10),(-.24,.02,.32),(-.61,.045,.42),(-.73,.045,.24),(-.49,-.015,.10),(-.05,-.015,.10)],.20,twist=.43)
ribbon('Bow / right continuous folded loop',[(0,.015,.10),(.23,.035,.34),(.57,.055,.39),(.71,.05,.24),(.46,-.012,.105),(.05,-.015,.10)],.20,twist=-.39)
cube('Bow / soft center knot',(0,-.012,.15),(.23,.23,.18),gold,.055,lid)
ribbon('Bow / left flowing tail',[(-.04,-.06,.14),(-.22,-.12,.10),(-.50,-.18,.075),(-.70,-.22,.05),(-.82,-.24,.04)],.18,twist=.25)
ribbon('Bow / right flowing tail',[(.04,-.035,.12),(.26,-.09,.085),(.52,-.14,.07),(.79,-.18,.045)],.18,twist=-.18)

# A few readable printed four-point stars belong to the front wrapping paper.
for x,z,r in [(-.78,.52,.075),(.74,1.15,.07),(-.64,1.15,.045),(.78,.43,.05)]:
    verts=[(x, -.030,z)]
    for k in range(8):
        a=k*math.pi/4;rr=r if k%2==0 else r*.3
        verts.append((x+math.sin(a)*rr,-.030,z+math.cos(a)*rr))
    faces=[(0,k+1,(k+1)%8+1) for k in range(8)]
    data=bpy.data.meshes.new('Mint star print');data.from_pydata(verts,[],faces);data.materials.append(pattern)
    obj=bpy.data.objects.new('Wrapping / small mint star print',data);scene.collection.objects.link(obj);obj.parent=front

def key(obj,frame,loc=None,rot=None,scale=None):
    if loc is not None:obj.location=loc;obj.keyframe_insert('location',frame=frame)
    if rot is not None:obj.rotation_euler=rot;obj.keyframe_insert('rotation_euler',frame=frame)
    if scale is not None:obj.scale=scale;obj.keyframe_insert('scale',frame=frame)
for frame,a in [(1,0),(14,0),(18,.015),(21,-.021),(24,.026),(27,-.03),(30,.04),(33,-.05),(36,.057),(38,-.043),(40,.025),(42,0),(96,0)]:
    key(motion,frame,loc=(a*.19,0,abs(a)*.20),rot=(a*.45,a*.3,a))

# Paper panels are independent rigid objects. Edges part, panels briefly lift,
# then settle as separate thin sheets; no entire intact container is left.
for root,axis,sign,settled,yaw in [
    (front,0,1,(.10,-.95,.045),-.18),(rear,0,-1,(-.27,.93,.065),.32),
    (left,1,-1,(-1.14,.32,.083),.35),(right,1,1,(1.14,-.25,.11),-.40)]:
    initial=root.location.copy()
    for frame,angle,offset in [(1,0,0),(38,0,0),(42,8,.07),(46,48,.24),(50,88,.18),(56,98,.09),(64,90,0),(96,90,0)]:
        rot=[0,0,0];rot[axis]=math.radians(sign*angle)
        rot[2]=yaw*min(1,max(0,(frame-42)/14))
        if frame>=56:
            amount=min(1,(frame-50)/14)
            loc=initial.lerp(Vector(settled),amount)
            if frame==56:loc.z=.245
        else:loc=initial+Vector((0,0,offset))
        key(root,frame,loc=loc,rot=rot)
for frame,loc,angle in [(1,(0,0,.035),0),(40,(0,0,.035),0),
                        (53,(-.18,.12,.095),-.2),(64,(-.18,.12,.035),-.2),
                        (96,(-.18,.12,.035),-.2)]:
    key(base,frame,loc=loc,rot=(0,0,angle))

# Mint lid and its bow rise together, tumble away, then lie near the rear.
for frame,loc,rot in [
    (1,(0,0,1.58),(0,0,0)),(38,(0,0,1.58),(0,0,0)),
    (42,(0,0,1.75),(-.1,.06,0)),(46,(.23,.34,2.28),(-.7,.18,.08)),
    (50,(.62,.77,1.90),(-2.6,.23,-.18)),(56,(.74,.75,.80),(-5.65,.10,-.29)),
    (60,(.74,.75,.30),(-6.16,0,-.35)),
    (63,(.74,.75,.10),(-math.tau,0,-.35)),(68,(.74,.75,.15),(-math.tau+.05,0,-.35)),
    (75,(.74,.75,.09),(-math.tau,0,-.35)),(96,(.74,.75,.09),(-math.tau,0,-.35))]:
    key(lid,frame,loc=loc,rot=rot)
# One complete controlled tumble ends outside-up, keeping the bow above floor.

def area(name,loc,power,color,size):
    d=bpy.data.lights.new(name,'AREA');d.energy=power;d.color=color;d.shape='DISK';d.size=size
    o=bpy.data.objects.new(name,d);scene.collection.objects.link(o);o.location=loc
    o.rotation_euler=(Vector((0,0,.7))-o.location).to_track_quat('-Z','Y').to_euler()
area('Gift / warm soft key',(-3,-4,6),550,(1,.87,.71),4)
area('Gift / cool readable fill',(4,-2,4),330,(.66,.89,1),4)
area('Gift / warm glint rim',(-1,3,5),700,(1,.67,.34),3)
floor=cube('REVIEW ONLY / stage floor',(0,0,-.058),(200,200,.10),navy,0)
spotdata=bpy.data.lights.new('REVIEW ONLY / spotlight','SPOT');spotdata.energy=950;spotdata.spot_size=math.radians(47);spotdata.spot_blend=.6;spotdata.shadow_soft_size=.25
spot=bpy.data.objects.new('REVIEW ONLY / spotlight',spotdata);scene.collection.objects.link(spot);spot.location=(0,-.3,7)
spot.rotation_euler=(Vector((0,0,0))-spot.location).to_track_quat('-Z','Y').to_euler()
camdata=bpy.data.cameras.new('Locked portrait gift camera');camdata.type='ORTHO';camdata.ortho_scale=6.2
cam=bpy.data.objects.new('Locked portrait gift camera',camdata);scene.collection.objects.link(cam);scene.camera=cam
cam.location=(3,-7,5.3)
def aim(target):cam.rotation_euler=(Vector(target)-cam.location).to_track_quat('-Z','Y').to_euler()
aim((0,0,.9));scene.render.resolution_x=540;scene.render.resolution_y=960
scene['Contract']='No badge, level, rank, text, confetti or background baked into runtime. Thin wrapped package releases into separate settled pieces.'
bpy.ops.wm.save_as_mainfile(filepath=str(ROOT/'source/gift-package.blend'))
if '--review' in ARGS:
    for label,frame in [('gift-closed',14),('gift-burst',49),('gift-settled',82)]:
        scene.frame_set(frame);scene.render.filepath=str(ROOT/'review'/f'{label}.png');bpy.ops.render.render(write_still=True)
    scene.render.resolution_x=352;scene.render.resolution_y=352;camdata.ortho_scale=6.4;aim((0,0,.85));floor.hide_render=True;scene.render.film_transparent=True
    for label,frame in [('gift-closed-transparent',14),('gift-settled-transparent',82)]:
        scene.frame_set(frame);scene.render.filepath=str(ROOT/'review'/f'{label}.png');bpy.ops.render.render(write_still=True)
if '--runtime' in ARGS:
    scene.render.resolution_x=352;scene.render.resolution_y=352;camdata.ortho_scale=6.4;aim((0,0,.85));floor.hide_render=True;scene.render.film_transparent=True
    for i in range(80):
        f=1+i*1.2;scene.frame_set(math.floor(f),subframe=f-math.floor(f));scene.render.filepath=str(ROOT/'runtime'/f'gift-{i:03d}.png');bpy.ops.render.render(write_still=True)
    manifest={'version':1,'name':'Kingdom Kids wrapped gift release','cellWidth':352,'cellHeight':352,'columns':10,
              'frameCount':80,'fps':20,'durationSeconds':4.0,
              'atlases':[{'asset':'assets/images/milestones/box_reveal_atlas.webp','firstFrame':0,'frameCount':80}],
              'posterAsset':'assets/images/milestones/box_reveal_poster.webp',
              'boxAnchor':[.5,.55],'floorAnchor':[.5,.66],'badgeAnchor':[.5,.25],
              'timings':{'spotlightHold':.6,'shakeStart':.6,'openingStarts':1.6,'boxOpen':2.0,'badgeStart':2.0,'badgeEnd':2.8,'brightStageStart':2.0,'piecesSettled':3.1},
              'decodedAtlasBytes':3520*2816*4,'artworkVersion':'gift-v2'}
    (ROOT/'runtime/box_reveal.json').write_text(json.dumps(manifest,indent=2)+'\n')
print('GIFT_RENDER_COMPLETE',flush=True)
