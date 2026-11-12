"""Native Red Sea environment, reproducible in Blender 4.5 LTS.

The camera and sea-foot mesh are authored in screen coordinates so the existing
game's complete validated drop polygon remains dry. All visible surface detail
is geometry or procedural Blender shading; no image/background projection.
"""
import bpy
import math
import random
import json
import sys
import shutil
from pathlib import Path
from mathutils import Vector, noise as mnoise
from bpy_extras.object_utils import world_to_camera_view

OUT = Path(__file__).resolve().parent
ARGS = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else []
MODE = ARGS[0] if ARGS else 'preview'
SEA_LEVEL = 0.0
SEA_FLOOR = -24.0
SEA_SPAN = 1200.0
random.seed(470)
bpy.ops.object.select_all(action='SELECT')
bpy.ops.object.delete(use_global=False)
scene = bpy.context.scene
scene.render.engine = 'CYCLES'
scene.cycles.samples = 24
scene.cycles.use_denoising = True
scene.cycles.max_bounces = 5
scene.cycles.transmission_bounces = 5
scene.cycles.volume_bounces = 2
scene.render.resolution_x = 786
scene.render.resolution_y = 1704
scene.render.resolution_percentage = 100
scene.render.image_settings.file_format = 'PNG'
scene.render.image_settings.color_mode = 'RGBA'
scene.render.film_transparent = False
scene.view_settings.view_transform = 'AgX'
scene.view_settings.look = 'AgX - Medium High Contrast'
scene.view_settings.exposure = .05
scene.render.fps = 24

def mat(name, color, roughness=.5, metallic=0):
    m=bpy.data.materials.new(name);m.use_nodes=True
    p=m.node_tree.nodes.get('Principled BSDF')
    p.inputs['Base Color'].default_value=(*color,1)
    p.inputs['Roughness'].default_value=roughness
    p.inputs['Metallic'].default_value=metallic
    return m

def mesh(name, verts, faces, material, smooth=True):
    m=bpy.data.meshes.new(name);m.from_pydata(verts,[],faces);m.update()
    o=bpy.data.objects.new(name,m);scene.collection.objects.link(o)
    o.data.materials.append(material)
    if smooth:
        for p in m.polygons:p.use_smooth=True
    return o

def sphere(name, loc, scale, material, subdivisions=2):
    bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=subdivisions,radius=1,location=loc)
    o=bpy.context.object;o.name=name;o.scale=scale;o.data.materials.append(material)
    for p in o.data.polygons:p.use_smooth=True
    return o

def curve(name, points, radius, material):
    c=bpy.data.curves.new(name,'CURVE');c.dimensions='3D';c.resolution_u=1
    c.bevel_depth=radius;c.bevel_resolution=2
    s=c.splines.new('POLY');s.points.add(len(points)-1)
    for p,co in zip(s.points,points):p.co=(*co,1)
    o=bpy.data.objects.new(name,c);scene.collection.objects.link(o)
    o.data.materials.append(material)
    return o

bpy.ops.object.camera_add(location=(0,-16,12))
cam=bpy.context.object;cam.name='Portrait game camera'
cam.rotation_euler=(Vector((0,8,1))-cam.location).to_track_quat('-Z','Y').to_euler()
cam.data.lens=38;cam.data.sensor_width=36;cam.data.sensor_fit='HORIZONTAL'
cam.data.clip_end=1500
scene.camera=cam
bpy.context.view_layer.update()

def use_metal():
    try:
        prefs=bpy.context.preferences.addons['cycles'].preferences
        prefs.compute_device_type='METAL';prefs.refresh_devices()
        available=False
        for d in prefs.devices:
            d.use=d.type=='METAL';available=available or d.use
        if available:scene.cycles.device='GPU'
    except Exception as error:print('Metal unavailable; using CPU:',error)

if MODE in ['deep_preview','deep_clips','deep_ready_review','deep_ready_loop','deep_opening_patch','fluid_studies','fluid_motion','fluid_fix']:use_metal()

# Ray/ground intersection takes normalized screen x/y (top-left origin).
def ground_at(sx,sy,z=0):
    aspect=scene.render.resolution_y/scene.render.resolution_x
    halfx=cam.data.sensor_width/(2*cam.data.lens)
    ray=cam.rotation_euler.to_matrix()@Vector(((sx-.5)*2*halfx,(.5-sy)*2*halfx*aspect,-1))
    distance=(z-cam.location.z)/ray.z
    return cam.location+ray*distance

def project(p):
    v=world_to_camera_view(scene,cam,Vector(p));return [round(v.x,6),round(1-v.y,6)]

world=bpy.data.worlds.new('Coastal sky');world.use_nodes=True;scene.world=world
wn=world.node_tree.nodes;wl=world.node_tree.links
# Directional coastal sky: cool overhead, pale warm light at the horizon.
tc=wn.new('ShaderNodeTexCoord');sep=wn.new('ShaderNodeSeparateXYZ')
wl.new(tc.outputs['Normal'],sep.inputs[0])
invert=wn.new('ShaderNodeMath');invert.operation='MULTIPLY';invert.inputs[1].default_value=-1
wl.new(sep.outputs['Z'],invert.inputs[0])
sky=wn.new('ShaderNodeValToRGB')
sky.color_ramp.elements[0].position=0;sky.color_ramp.elements[0].color=(.55,.7,.8,1)
sky.color_ramp.elements[1].position=.34;sky.color_ramp.elements[1].color=(.08,.36,.57,1)
wl.new(invert.outputs[0],sky.inputs[0])
cloud=wn.new('ShaderNodeTexNoise');cloud.inputs['Scale'].default_value=4.5;cloud.inputs['Detail'].default_value=3
wl.new(tc.outputs['Normal'],cloud.inputs['Vector'])
cloudmask=wn.new('ShaderNodeValToRGB');cloudmask.color_ramp.elements[0].position=.6
cloudmask.color_ramp.elements[0].color=(0,0,0,1);cloudmask.color_ramp.elements[1].position=.77
cloudmask.color_ramp.elements[1].color=(.78,.78,.78,1)
wl.new(cloud.outputs['Fac'],cloudmask.inputs[0])
mixsky=wn.new('ShaderNodeMixRGB');mixsky.inputs[2].default_value=(.83,.85,.8,1)
wl.new(cloudmask.outputs[0],mixsky.inputs[0]);wl.new(sky.outputs[0],mixsky.inputs[1])
wl.new(mixsky.outputs[0],wn.get('Background').inputs['Color'])
wn.get('Background').inputs['Strength'].default_value=.65
bpy.ops.object.light_add(type='SUN',location=(-15,45,40))
sun=bpy.context.object;sun.name='Warm coastal sun';sun.data.energy=2.2
sun.data.angle=math.radians(12);sun.data.color=(1,.8,.55)
sun.rotation_euler=(Vector((0,0,0))-sun.location).to_track_quat('-Z','Y').to_euler()
bpy.ops.object.light_add(type='AREA',location=(1,-5,18))
fill=bpy.context.object;fill.name='Cool sky reflection';fill.data.energy=750
fill.data.shape='DISK';fill.data.size=18;fill.data.color=(.52,.79,1)
fill.rotation_euler=(Vector((0,15,0))-fill.location).to_track_quat('-Z','Y').to_euler()
bpy.ops.object.light_add(type='AREA',location=(0,28,3))
waterlight=bpy.context.object;waterlight.name='Soft light inside sea corridor';waterlight.data.energy=3500
waterlight.data.shape='DISK';waterlight.data.size=22;waterlight.data.color=(.54,.85,1)
waterlight.rotation_euler=(Vector((0,55,-14))-waterlight.location).to_track_quat('-Z','Y').to_euler()

# A native emissive sun disc and optical bloom provide the distant warm focal point.
halfx=cam.data.sensor_width/(2*cam.data.lens);aspect=1704/786
sr=cam.rotation_euler.to_matrix()@Vector(((.64-.5)*2*halfx,(.5-.235)*2*halfx*aspect,-1))
sunpos=cam.location+sr.normalized()*650
sunmat=mat('Sun disc',(1,.68,.21),.5)
sunp=sunmat.node_tree.nodes.get('Principled BSDF')
sunp.inputs['Emission Color'].default_value=(1,.71,.28,1);sunp.inputs['Emission Strength'].default_value=5
sphere('Warm distant sun',sunpos,(19,19,19),sunmat,4)
scene.use_nodes=True
cn=scene.node_tree.nodes;cl=scene.node_tree.links;cn.clear()
rl=cn.new('CompositorNodeRLayers');glow=cn.new('CompositorNodeGlare')
glow.glare_type='FOG_GLOW';glow.quality='MEDIUM';glow.threshold=2;glow.size=8
out=cn.new('CompositorNodeComposite');cl.new(rl.outputs['Image'],glow.inputs['Image']);cl.new(glow.outputs['Image'],out.inputs[0])

sand=mat('Wet golden sand',(.49,.31,.135),.48)
n=sand.node_tree.nodes;l=sand.node_tree.links;p=n.get('Principled BSDF')
tex=n.new('ShaderNodeTexNoise');tex.inputs['Scale'].default_value=2.4
tex.inputs['Detail'].default_value=5;tex.inputs['Roughness'].default_value=.74
stc=n.new('ShaderNodeTexCoord');l.new(stc.outputs['Object'],tex.inputs['Vector'])
r=n.new('ShaderNodeValToRGB');r.color_ramp.elements[0].position=.23
r.color_ramp.elements[0].color=(.22,.13,.057,1)
r.color_ramp.elements[1].position=.8;r.color_ramp.elements[1].color=(.73,.51,.27,1)
l.new(tex.outputs['Fac'],r.inputs[0]);l.new(r.outputs[0],p.inputs['Base Color'])
b=n.new('ShaderNodeBump');b.inputs['Strength'].default_value=.36;b.inputs['Distance'].default_value=.12
l.new(tex.outputs['Fac'],b.inputs['Height']);l.new(b.outputs[0],p.inputs['Normal'])
fine=n.new('ShaderNodeTexNoise');fine.inputs['Scale'].default_value=90;fine.inputs['Detail'].default_value=2
l.new(stc.outputs['Object'],fine.inputs['Vector'])
b2=n.new('ShaderNodeBump');b2.inputs['Strength'].default_value=.2;b2.inputs['Distance'].default_value=.018
l.new(fine.outputs['Fac'],b2.inputs['Height']);l.new(b.outputs[0],b2.inputs['Normal']);l.new(b2.outputs[0],p.inputs['Normal'])
verts=[];faces=[]
near_shore_y=ground_at(.5,.745,SEA_LEVEL).y
deep_ramp_y=ground_at(.5,.70,SEA_FLOOR).y
def smooth(t):
    t=max(0,min(1,t));return t*t*(3-2*t)
def rounded_ramp(t):
    # Long nearly-linear descent, with C1 rounded ends; this keeps the sandy
    # ramp facing the accepted camera instead of hiding its floor behind a lip.
    t=max(0,min(1,t));edge=.07
    if t<edge:return t*t/(2*edge*(1-edge))
    if t>1-edge:return 1-(1-t)**2/(2*edge*(1-edge))
    return (t-edge/2)/(1-edge)
def bed_elevation(y):
    if y<deep_ramp_y:
        return SEA_LEVEL+(SEA_FLOOR-SEA_LEVEL)*rounded_ramp((y-near_shore_y)/(deep_ramp_y-near_shore_y))
    if y>300:
        return SEA_FLOOR+(SEA_LEVEL-SEA_FLOOR)*smooth((y-300)/430)
    return SEA_FLOOR
GROUND_YS=[-25+i*.3 for i in range(131)]+[16+i*2 for i in range(141)]+[300+i*5 for i in range(181)]
nx=80;ny=len(GROUND_YS)-1
for j,y in enumerate(GROUND_YS):
    for i in range(nx+1):
        x=-120+i/nx*240
        z=.022*math.sin(y*2.2+x*.13)+.01*math.sin(y*7.4-x*.25)
        verts.append((x,y,bed_elevation(y)+z-.03))
for j in range(ny):
    for i in range(nx):
        a=j*(nx+1)+i;faces.append((a,a+1,a+nx+2,a+nx+1))
ground=mesh('Continuous shore, rounded ramp, deep seabed and far coastal rise',verts,faces,sand)
# Reflection linking: preserve sand for camera/refraction, keep the miracle's
# near-vertical reflective surfaces from reading as opaque beige rock.
ground.visible_glossy=False

dune=mat('Distant warm sandstone',(.38,.23,.115),.85)
dv=[];df=[]
for j in range(26):
    yy=730+j*12
    for i in range(101):
        xx=-1000+i*20
        zz=max(0,14+16*math.sin(xx*.008+yy*.007)+6*math.sin(xx*.027+yy*.04)+2*math.sin(xx*.15+yy*.07))
        zz*=min(1,j/5)
        dv.append((xx,yy,zz))
for j in range(25):
    for i in range(100):
        a=j*101+i;df.append((a,a+1,a+102,a+101))
mesh('Irregular distant coastal hills',dv,df,dune)

rock=mat('Shore rocks',(.19,.17,.13),.72)
for k in range(95):
    sx=random.choice([random.uniform(.025,.125),random.uniform(.875,.98)])
    sy=random.uniform(.73,.995);point=ground_at(sx,sy)
    r=random.uniform(.05,.24)
    o=sphere('Small shore pebble',point,(r,r*.8,r*.55),rock,2)
    o.rotation_euler=(random.random(),random.random(),random.random()*6)

water=mat('Deep refractive turquoise seawater',(.005,.15,.205),.095)
wn=water.node_tree.nodes;wl=water.node_tree.links;wp=wn.get('Principled BSDF')
wp.inputs['IOR'].default_value=1.333
wp.inputs['Transmission Weight'].default_value=.9
wp.inputs['Specular Tint'].default_value=(1,1,1,1)
wp.inputs['Specular IOR Level'].default_value=.5
wp.inputs['Coat Weight'].default_value=.025;wp.inputs['Coat Roughness'].default_value=.09
coord=wn.new('ShaderNodeTexCoord')
noise=wn.new('ShaderNodeTexNoise');noise.inputs['Scale'].default_value=.9;noise.inputs['Detail'].default_value=5
noise.inputs['Roughness'].default_value=.7
wl.new(coord.outputs['Object'],noise.inputs['Vector'])
ramp=wn.new('ShaderNodeValToRGB')
ramp.color_ramp.elements[0].position=.15;ramp.color_ramp.elements[0].color=(.001,.035,.07,1)
ramp.color_ramp.elements[1].position=.85;ramp.color_ramp.elements[1].color=(.018,.43,.48,1)
mid=ramp.color_ramp.elements.new(.5);mid.color=(.004,.21,.29,1)
wl.new(noise.outputs['Fac'],ramp.inputs[0])
fnoise=wn.new('ShaderNodeTexNoise');fnoise.inputs['Scale'].default_value=5.5;fnoise.inputs['Detail'].default_value=4
wl.new(coord.outputs['Object'],fnoise.inputs[0])
fz=wn.new('ShaderNodeSeparateXYZ');wl.new(coord.outputs['Object'],fz.inputs[0])
fzmap=wn.new('ShaderNodeMath');fzmap.operation='MULTIPLY_ADD';fzmap.use_clamp=True
fzmap.inputs[1].default_value=1/(SEA_LEVEL-SEA_FLOOR);fzmap.inputs[2].default_value=1
wl.new(fz.outputs['Z'],fzmap.inputs[0])
heightmix=wn.new('ShaderNodeMath');heightmix.operation='MULTIPLY_ADD'
heightmix.inputs[1].default_value=.75;heightmix.inputs[2].default_value=.25
wl.new(fzmap.outputs[0],heightmix.inputs[0])
foamfac=wn.new('ShaderNodeMath');foamfac.operation='MULTIPLY'
wl.new(heightmix.outputs[0],foamfac.inputs[0]);wl.new(fnoise.outputs['Fac'],foamfac.inputs[1])
fm=wn.new('ShaderNodeValToRGB');fm.color_ramp.elements[0].position=.52
fm.color_ramp.elements[0].color=(0,0,0,1);fm.color_ramp.elements[1].position=.62
fm.color_ramp.elements[1].color=(.75,.75,.75,1);wl.new(foamfac.outputs[0],fm.inputs[0])
watermix=wn.new('ShaderNodeMixRGB');watermix.inputs[2].default_value=(.56,.83,.84,1)
wl.new(fm.outputs[0],watermix.inputs[0]);wl.new(ramp.outputs[0],watermix.inputs[1]);wl.new(watermix.outputs[0],wp.inputs['Base Color'])
micro=wn.new('ShaderNodeTexNoise');micro.inputs['Scale'].default_value=18;micro.inputs['Detail'].default_value=3
wl.new(coord.outputs['Object'],micro.inputs[0])
bump=wn.new('ShaderNodeBump');bump.inputs['Strength'].default_value=.25;bump.inputs['Distance'].default_value=.045
wl.new(micro.outputs['Fac'],bump.inputs['Height']);wl.new(bump.outputs[0],wp.inputs['Normal'])
absorb=wn.new('ShaderNodeVolumeAbsorption');absorb.inputs['Color'].default_value=(.015,.40,.54,1)
absorb.inputs['Density'].default_value=.025
scatter=wn.new('ShaderNodeVolumeScatter');scatter.inputs['Color'].default_value=(.015,.42,.48,1)
scatter.inputs['Density'].default_value=.027;scatter.inputs['Anisotropy'].default_value=.45
volume=wn.new('ShaderNodeAddShader');wl.new(absorb.outputs[0],volume.inputs[0]);wl.new(scatter.outputs[0],volume.inputs[1])
wl.new(volume.outputs[0],wn.get('Material Output').inputs['Volume'])
# The exposed vertical water faces have a stronger scattering response than the
# reflective horizontal ocean surface: colour remains teal at grazing angles.
face_water=mat('Flowing deep-blue exposed seawater',(.018,.28,.36),.18)
fn=face_water.node_tree.nodes;fl=face_water.node_tree.links;fw=fn.get('Principled BSDF')
fw.inputs['IOR'].default_value=1.333;fw.inputs['Transmission Weight'].default_value=.35
fw.inputs['Specular Tint'].default_value=(.03,.51,.8,1);fw.inputs['Specular IOR Level'].default_value=.28
fw.inputs['Coat Weight'].default_value=.025;fw.inputs['Coat Roughness'].default_value=.08
fc=fn.new('ShaderNodeTexCoord');ft=fn.new('ShaderNodeTexNoise');ft.inputs['Scale'].default_value=1.1;ft.inputs['Detail'].default_value=5
flow_scale=fn.new('ShaderNodeVectorMath');flow_scale.operation='MULTIPLY';flow_scale.inputs[1].default_value=(.24,.19,.32)
fl.new(fc.outputs['Object'],flow_scale.inputs[0])
FACE_FLOW=fn.new('ShaderNodeVectorMath');FACE_FLOW.operation='ADD';fl.new(flow_scale.outputs[0],FACE_FLOW.inputs[0])
fl.new(FACE_FLOW.outputs[0],ft.inputs['Vector'])
fr=fn.new('ShaderNodeValToRGB');fr.color_ramp.elements[0].color=(.003,.063,.12,1);fr.color_ramp.elements[1].color=(.022,.30,.38,1)
fl.new(ft.outputs['Fac'],fr.inputs[0]);fl.new(fr.outputs[0],fw.inputs['Base Color'])
fb=fn.new('ShaderNodeBump');fb.inputs['Strength'].default_value=.09;fb.inputs['Distance'].default_value=.045
fl.new(ft.outputs['Fac'],fb.inputs['Height']);fl.new(fb.outputs[0],fw.inputs['Normal'])
fa=fn.new('ShaderNodeVolumeAbsorption');fa.inputs['Color'].default_value=(.015,.40,.54,1);fa.inputs['Density'].default_value=.025
fs=fn.new('ShaderNodeVolumeScatter');fs.inputs['Color'].default_value=(.015,.42,.48,1)
fs.inputs['Density'].default_value=.027;fs.inputs['Anisotropy'].default_value=.45
fv=fn.new('ShaderNodeAddShader');fl.new(fa.outputs[0],fv.inputs[0]);fl.new(fs.outputs[0],fv.inputs[1]);fl.new(fv.outputs[0],fn.get('Material Output').inputs['Volume'])
foam=mat('Aerated soft white sea foam',(.69,.91,.88),.4)
fp=foam.node_tree.nodes.get('Principled BSDF');fp.inputs['Subsurface Weight'].default_value=.12
spray=mat('Sunlit spray',(.86,.97,.96),.22)
foam_patch=mat('Porous broken flowing foam',(.9,.97,.94),.32)
pn=foam_patch.node_tree.nodes;pl=foam_patch.node_tree.links
pt=pn.new('ShaderNodeTexCoord');pnoise=pn.new('ShaderNodeTexNoise');pnoise.inputs['Scale'].default_value=9;pnoise.inputs['Detail'].default_value=3
pl.new(pt.outputs['Object'],pnoise.inputs['Vector'])
pr=pn.new('ShaderNodeValToRGB');pr.color_ramp.elements[0].position=.51;pr.color_ramp.elements[0].color=(0,0,0,1)
pr.color_ramp.elements[1].position=.73;pr.color_ramp.elements[1].color=(1,1,1,1);pl.new(pnoise.outputs['Fac'],pr.inputs[0])
trans=pn.new('ShaderNodeBsdfTransparent');pmix=pn.new('ShaderNodeMixShader')
pl.new(pr.outputs[0],pmix.inputs[0]);pl.new(trans.outputs[0],pmix.inputs[1]);pl.new(pn.get('Principled BSDF').outputs[0],pmix.inputs[2]);pl.new(pmix.outputs[0],pn.get('Material Output').inputs['Surface'])
foam_patch.surface_render_method='DITHERED'
FOAM_PATCHES=[]
# Blender-generated wave foam follows the FFT crests instead of decorative
# spots. POINT density is interpolated across the real moving water meshes.
def add_wave_foam_shader(material):
    n=material.node_tree.nodes;l=material.node_tree.links
    attr=n.new('ShaderNodeAttribute');attr.attribute_name='OceanFoam'
    ramp=n.new('ShaderNodeValToRGB');ramp.color_ramp.elements[0].position=.38
    ramp.color_ramp.elements[0].color=(0,0,0,1)
    ramp.color_ramp.elements[1].position=.72;ramp.color_ramp.elements[1].color=(1,1,1,1)
    l.new(attr.outputs['Fac'],ramp.inputs[0])
    foam_bsdf=n.new('ShaderNodeBsdfPrincipled')
    foam_bsdf.inputs['Base Color'].default_value=(.8,.92,.91,1)
    foam_bsdf.inputs['Roughness'].default_value=.39
    mix=n.new('ShaderNodeMixShader');l.new(ramp.outputs[0],mix.inputs[0])
    l.new(n.get('Principled BSDF').outputs[0],mix.inputs[1]);l.new(foam_bsdf.outputs[0],mix.inputs[2])
    l.new(mix.outputs[0],n.get('Material Output').inputs['Surface'])
for material in [water,face_water]:add_wave_foam_shader(material)

def update_foam_attribute(obj):
    attr=obj.data.attributes.get('OceanFoam')
    if not attr:attr=obj.data.attributes.new('OceanFoam','FLOAT','POINT')
    for vertex,value in zip(obj.data.vertices,attr.data):
        q=vertex.co;top=ocean_surface(q.x,q.y)
        band=max(0,1-abs(q.z-top)/2)
        value.value=ocean_sample(q.x,q.y,1)*band*smooth((q.y-near_shore_y)/18)



DRY_POLYGON=[(.43,.33),(.57,.33),(.705,.43),(.855,.70),(.145,.70),(.295,.43)]
# This is wider than the complete authored polygon at every depth.
EDGE=[(.286,.495),(.305,.483),(.325,.413),(.33,.412),(.43,.275),(.70,.125)]
def screen_left(y):
    for (ya,xa),(yb,xb) in zip(EDGE,EDGE[1:]):
        if y<=yb:return xa+(xb-xa)*(y-ya)/(yb-ya)
    return EDGE[-1][1]

DEPTHS=[];BASE_WIDTHS=[];BED_HEIGHTS=[]
for j in range(151):
    if j<=120:
        sy=.286+j/120*(.70-.286)
        q=ground_at(screen_left(sy),sy,SEA_FLOOR)
    else:
        t=(j-120)/30
        deep=ground_at(.125,.70,SEA_FLOOR)
        shore=ground_at(.025,.745,SEA_LEVEL)
        q=deep.lerp(shore,t)
    DEPTHS.append(q.y);BASE_WIDTHS.append(abs(q.x));BED_HEIGHTS.append(bed_elevation(q.y))

# A genuine Blender Ocean modifier supplies the wind-driven Fourier spectrum,
# choppy wave elevations and generated whitecap density. It stays editable in
# the native scene, while sampled fields drive the custom parting volume.
bpy.ops.mesh.primitive_plane_add()
OCEAN_SOURCE=bpy.context.object;OCEAN_SOURCE.name='Native FFT sea simulation source'
OCEAN_SOURCE.hide_render=True;OCEAN_SOURCE.hide_set(True)
OCEAN=OCEAN_SOURCE.modifiers.new('Wind-driven Phillips wave spectrum','OCEAN')
OCEAN.resolution=9;OCEAN.viewport_resolution=9
OCEAN.spatial_size=64;OCEAN.wind_velocity=16;OCEAN.wave_scale=1.7
OCEAN.choppiness=1.6;OCEAN.depth=100;OCEAN.use_foam=True
OCEAN.foam_layer_name='WaveFoam';OCEAN.foam_coverage=.15
OCEAN_FIELDS=None;OCEAN_PHASE=None;OCEAN_GRID=81

def fft_field(time):
    OCEAN.time=time;bpy.context.view_layer.update()
    evaluated=OCEAN_SOURCE.evaluated_get(bpy.context.evaluated_depsgraph_get())
    data=evaluated.to_mesh()
    heights=[v.co.z for v in data.vertices]
    foam=[0.0]*len(heights);counts=[0]*len(heights)
    attr=data.color_attributes.get('WaveFoam')
    if attr:
        for loop,item in zip(data.loops,attr.data):
            foam[loop.vertex_index]+=item.color[0];counts[loop.vertex_index]+=1
        foam=[f/max(1,n) for f,n in zip(foam,counts)]
    evaluated.to_mesh_clear()
    return heights,foam

def prepare_ocean(phase):
    global OCEAN_FIELDS,OCEAN_PHASE
    phase=phase%(2*math.pi)
    if OCEAN_PHASE is not None and abs(OCEAN_PHASE-phase)<1e-7:return
    t=phase/(2*math.pi);weight=.5-.5*math.cos(math.pi*t)
    a=fft_field(10+2*t);b=fft_field(8+2*t)
    OCEAN_FIELDS=tuple([[x*(1-weight)+y*weight for x,y in zip(aa,bb)] for aa,bb in zip(a,b)])
    OCEAN_PHASE=phase

def ocean_sample(x,y,field=0):
    gx=((x+32)%64)/64*OCEAN_GRID;gy=((y+32)%64)/64*OCEAN_GRID
    ix=int(gx);iy=int(gy);fx=gx-ix;fy=gy-iy;stride=OCEAN_GRID+1
    values=OCEAN_FIELDS[field]
    return ((values[iy*stride+ix]*(1-fx)+values[iy*stride+ix+1]*fx)*(1-fy)
            +(values[(iy+1)*stride+ix]*(1-fx)+values[(iy+1)*stride+ix+1]*fx)*fy)

def ocean_surface(x,y,phase=0):
    # Physical level is identical throughout opening. Wind waves pre-exist the
    # miracle; they gently vanish at Moses' surface-height contact shoreline.
    return SEA_LEVEL+ocean_sample(x,y)*smooth((y-near_shore_y)/18)

prepare_ocean(0)
TOP_COLS=32;TOP_WIDTH=TOP_COLS+1

def top_offset(k,base):
    return .45*math.expm1(k/TOP_COLS*math.log1p((SEA_SPAN+base*.3)/.45))

def part_progress(progress,j):
    # The miracle travels from the near shore (j=150) towards the horizon.
    # Each location begins withdrawing only after the front reaches it.
    delay=.56*(1-j/150)**.80
    u=max(0,min(1,(progress-delay)/.44))
    return smooth(progress/.65)*smooth(u)
WALLS=[];FOAM_CURVES=[];DROPLETS=[];MISTS=[]
mist=bpy.data.materials.new('Fine entrained coastal spray');mist.use_nodes=True
mn=mist.node_tree.nodes;ml=mist.node_tree.links;mn.clear()
mo=mn.new('ShaderNodeOutputMaterial');ms=mn.new('ShaderNodeVolumeScatter')
ms.inputs['Color'].default_value=(.7,.86,.89,1);ms.inputs['Anisotropy'].default_value=.25
mt=mn.new('ShaderNodeTexNoise');mt.inputs['Scale'].default_value=2.1;mt.inputs['Detail'].default_value=3
mm=mn.new('ShaderNodeMath');mm.operation='MULTIPLY';mm.inputs[1].default_value=.065
ml.new(mt.outputs['Fac'],mm.inputs[0]);ml.new(mm.outputs[0],ms.inputs['Density']);ml.new(ms.outputs[0],mo.inputs['Volume'])
for side in [-1,1]:
    for j in range(65,147,9):
        o=sphere('Airborne curling fine sea spray',(0,0,0),(1.1,2.6,.45),mist,2)
        MISTS.append((o,side,j))
def water_point(side,j,zfraction,progress,phase,outer=False):
    ji=min(149,int(j));qj=j-ji
    y=DEPTHS[ji]*(1-qj)+DEPTHS[ji+1]*qj
    base=BASE_WIDTHS[ji]*(1-qj)+BASE_WIDTHS[ji+1]*qj
    bed=BED_HEIGHTS[ji]*(1-qj)+BED_HEIGHTS[ji+1]*qj
    progress=part_progress(progress,j)
    surface_phase=phase
    if side==1:phase+=1.31
    depth=max(0,SEA_LEVEL-bed)
    wav=.12*math.sin(y*.24+phase)+.075*math.sin(y*.91-phase*2)+.025*math.sin(y*2.3+phase*3)
    # Broad rolling irregularity comes from a coherent 3D turbulence field;
    # no repeated vertical sine creases are imposed on the liquid surface.
    turbulence=mnoise.noise(Vector((y*.052+.35*math.cos(phase),zfraction*1.7+.35*math.sin(phase),.71)))
    cross=max(0,math.exp(-((zfraction-.67)/.29)**2)-math.exp(-(.67/.29)**2))
    bowl=(depth*.035+max(0,1.8*ocean_sample(y+side*13,zfraction*32+17)))*math.sin(math.pi*zfraction)**1.3
    curl=depth*.045*zfraction**8*(1+.18*mnoise.noise(Vector((y*.09,math.cos(phase),math.sin(phase)))))
    x=side*(base*progress+max(0,wav*progress)+(bowl+curl)*progress+.07*progress)
    if outer:x+=side*(SEA_SPAN+base*.3)
    top=ocean_surface(x,y,surface_phase)
    z=bed+(top-bed)*zfraction
    return (x,y,z)

for side in [-1,1]:
    v=[];f=[];cols=36
    for j in range(151):
        for k in range(cols+1):v.append(water_point(side,j,k/cols,1,0))
    for j in range(150):
        for k in range(cols):
            a=j*(cols+1)+k
            f.append((a,a+1,a+cols+2,a+cols+1) if side==-1 else (a,a+cols+1,a+cols+2,a+1))
    # The top is a broad real surface joined to the visible vertical wall.
    top_start=len(v)
    for j in range(151):
        for k in range(TOP_WIDTH):
            q=Vector(water_point(side,j,1,1,0));q.x+=side*top_offset(k,BASE_WIDTHS[j])
            q.z=ocean_surface(q.x,q.y)
            v.append(tuple(q))
    for j in range(150):
        for k in range(TOP_COLS):
            a=top_start+j*TOP_WIDTH+k
            f.append((a,a+1,a+TOP_WIDTH+1,a+TOP_WIDTH) if side==-1 else (a,a+TOP_WIDTH,a+TOP_WIDTH+1,a+1))
    # Closed base and outer faces give absorption a real volume to travel through.
    bottom_start=len(v)
    for j in range(151):
        q=water_point(side,j,0,1,0)
        v.extend([(q[0],q[1],BED_HEIGHTS[j]-.3),(q[0]+side*(SEA_SPAN+BASE_WIDTHS[j]*.3),q[1],BED_HEIGHTS[j]-.3)])
    for j in range(150):
        a=bottom_start+j*2
        inner=j*(cols+1);next_inner=inner+cols+1
        f.append((inner,a,a+2,next_inner) if side==-1 else (inner,next_inner,a+2,a))
        f.append((a,a+2,a+3,a+1) if side==-1 else (a,a+1,a+3,a+2))
        b=top_start+j*TOP_WIDTH+TOP_COLS;c=b+TOP_WIDTH
        f.append((a+1,a+3,c,b) if side==-1 else (a+1,b,c,a+3))
    for j in [0,150]:
        a=j*(cols+1);b=top_start+j*TOP_WIDTH+TOP_COLS;c=bottom_start+j*2
        cap=tuple([a+k for k in range(cols+1)]+[b,c+1,c])
        if (j==0 and side==-1) or (j==150 and side==1):cap=tuple(reversed(cap))
        f.append(cap)
    obj=mesh(('Left' if side<0 else 'Right')+' thick parted sea',v,f,water)
    obj.data.materials.append(face_water)
    for polygon in obj.data.polygons[:150*cols]:polygon.material_index=1
    WALLS.append((obj,side,cols,top_start))
    # Broken crest patches are genuine foam geometry, not a uniform white rail.
    for start in range(0,148,7):
        if random.random()<.25:continue
        span=random.randint(1,3);end=min(150,start+span)
        points=[water_point(side,j,1,1,0) for j in range(start,end+1)]
        radius=.025+random.random()*.03
        o=curve('Broken foam crest',points,radius,foam)
        FOAM_CURVES.append((o,side,list(range(start,end+1)),1,radius))
    # Real, porous foam fragments curl with the upper liquid face. Their
    # different sizes and broken transparency avoid a rigid white pool rail.
    for patch_index in range(150):
        jc=random.uniform(25,147);zc=random.uniform(.947,1)
        jr=random.uniform(.25,1.15);zr=random.uniform(.004,.016)
        if patch_index<35:zc=random.uniform(.008,.025);zr=random.uniform(.003,.008)
        params=[(jc,zc)]
        for k in range(12):
            angle=k/12*2*math.pi
            params.append((max(0,min(150,jc+jr*math.sin(angle))),max(0,min(1,zc+zr*math.cos(angle)))))
        pv=[]
        for jj,zz in params:
            q=Vector(water_point(side,jj,zz,1,0));q.x-=side*.035;pv.append(tuple(q))
        pf=[(0,1+k,1+(k+1)%12) for k in range(12)]
        o=mesh('Broken upper-face foam',pv,pf,foam_patch)
        FOAM_PATCHES.append((o,side,params,jc))
    for k in range(130):
        j=random.randint(60,149);q=Vector(water_point(side,j,1,1,0))
        q+=Vector((random.uniform(-.4,.4),random.uniform(-.3,.3),random.uniform(.05,.45)))
        rad=random.uniform(.012,.035)
        o=sphere('Crest spray droplet',q,(rad,rad,rad*1.6),spray,1)
        DROPLETS.append((o,side,j,q-Vector(water_point(side,j,1,1,0)),rad))

# The centre drains only behind the moving front. Its surrounding surface is
# always SEA_LEVEL, so there is no shallow pool that rises into towering walls.
DRAIN_COLS=12
def drain_point(j,k,progress,phase):
    local=part_progress(progress,j)
    zf=1-smooth((local-.25)/.65)
    left=Vector(water_point(-1,j,zf,progress,phase));right=Vector(water_point(1,j,zf,progress,phase))
    u=k/DRAIN_COLS;q=left.lerp(right,u)
    q.z-=max(0,SEA_LEVEL-BED_HEIGHTS[j])*.34*math.sin(math.pi*u)**2*math.sin(math.pi*local)
    q.z+=.16*ocean_sample(q.x,q.y)*math.sin(math.pi*u)*local*(1-local)
    if local>.999:q.z-=.24
    return tuple(q)
dv=[];df=[]
for j in range(151):
    for k in range(DRAIN_COLS+1):dv.append(drain_point(j,k,1,0))
for j in range(150):
    for k in range(DRAIN_COLS):
        a=j*(DRAIN_COLS+1)+k;df.append((a,a+DRAIN_COLS+1,a+DRAIN_COLS+2,a+1))
drain_top_count=len(dv)
for j in range(151):
    for side in [-1,1]:
        q=water_point(side,j,0,1,0);dv.append((q[0],q[1],BED_HEIGHTS[j]-.4))
for j in range(150):
    b=drain_top_count+j*2;t=j*(DRAIN_COLS+1);tn=t+DRAIN_COLS+1
    df.extend([(b,b+1,b+3,b+2),(t,b,b+2,tn),(t+DRAIN_COLS,tn+DRAIN_COLS,b+3,b+1)])
for j in [0,150]:
    t=j*(DRAIN_COLS+1);b=drain_top_count+j*2
    cap=tuple([t+k for k in range(DRAIN_COLS+1)]+[b+1,b])
    df.append(tuple(reversed(cap)) if j==150 else cap)
DRAIN=mesh('Receding central water and rounded travelling front',dv,df,water)

# Union topology has only one external liquid boundary. Submerged side faces
# would otherwise refract inside the receding central water and make a dark
# triangular curtain. The combined mesh removes those internal interfaces.
def drain_fraction(progress,j):
    return 1-smooth((part_progress(progress,j)-.25)/.65)

LIQUID_PARTS=[];lv=[];lf=[];lmi=[]
for obj,side,cols,top_start in WALLS:
    offset=len(lv);LIQUID_PARTS.append((obj,offset))
    lv.extend(tuple(v.co) for v in obj.data.vertices)
    internal_start=150*cols+150*TOP_COLS
    for i,poly in enumerate(obj.data.polygons):
        if internal_start<=i<internal_start+150*3 and (i-internal_start)%3==0:continue
        lf.append(tuple(offset+x for x in poly.vertices));lmi.append(poly.material_index)
    obj.hide_render=True
    obj.hide_set(True)
offset=len(lv);LIQUID_PARTS.append((DRAIN,offset));lv.extend(tuple(v.co) for v in DRAIN.data.vertices)
for i,poly in enumerate(DRAIN.data.polygons):
    if 150*DRAIN_COLS<=i<150*DRAIN_COLS+150*3 and (i-150*DRAIN_COLS)%3!=0:continue
    lf.append(tuple(offset+x for x in poly.vertices));lmi.append(0)
LIQUID=mesh('One continuous wind-driven parting liquid volume',lv,lf,water)
LIQUID.data.materials.append(face_water)
for poly,mi in zip(LIQUID.data.polygons,lmi):poly.material_index=mi
DRAIN.hide_render=True;DRAIN.hide_set(True)


# Close sea sheet disappears naturally as the parted mesh opens. A transparent
# visibility switch here avoids retaining a shallow water plane in the dry lane.
v=[];f=[];N=45
for j in range(N+1):
    for i in range(N+1):
        sy=.286+j/N*(.745-.286)
        sy+=(j/N)**8*(.004*math.sin(i/N*math.pi*5+.3)+.0015*math.sin(i/N*math.pi*13))
        q=ground_at(i/N,sy,SEA_LEVEL);q.z=ocean_surface(q.x,q.y);v.append(tuple(q))
for j in range(N):
    for i in range(N):
        a=j*(N+1)+i;f.append((a,a+1,a+N+2,a+N+1))
closed=mesh('Unparted sea sheet',v,f,water)
CLOSED_XY=[(q[0],q[1]) for q in v]

def update(progress,phase=0):
    prepare_ocean(phase)
    FACE_FLOW.inputs[1].default_value=(.3*math.cos(phase),.38*math.sin(phase),.6*math.sin(phase))
    if progress<=.001:
        for vertex,(x,y) in zip(closed.data.vertices,CLOSED_XY):vertex.co.z=ocean_surface(x,y,phase)
        closed.data.update()
    DRAIN.hide_render=progress<=.001 or progress>=.999
    if True:
        for j in range(151):
            for k in range(DRAIN_COLS+1):DRAIN.data.vertices[j*(DRAIN_COLS+1)+k].co=drain_point(j,k,progress,phase)
            for si,side in enumerate([-1,1]):
                q=water_point(side,j,0,progress,phase)
                DRAIN.data.vertices[drain_top_count+j*2+si].co=(q[0],q[1],BED_HEIGHTS[j]-.4)
        DRAIN.data.update()
        update_foam_attribute(DRAIN)
    for obj,side,cols,top_start in WALLS:
        obj.hide_render=True
        for j in range(151):
            low=drain_fraction(progress,j)
            for k in range(cols+1):obj.data.vertices[j*(cols+1)+k].co=water_point(side,j,low+(1-low)*k/cols,progress,phase)
            for k in range(TOP_WIDTH):
                q=Vector(water_point(side,j,1,progress,phase));q.x+=side*top_offset(k,BASE_WIDTHS[j])
                q.z=ocean_surface(q.x,q.y,phase)
                obj.data.vertices[top_start+j*TOP_WIDTH+k].co=q
            q=water_point(side,j,0,progress,phase)
            b=top_start+151*TOP_WIDTH+j*2
            obj.data.vertices[b].co=(q[0],q[1],BED_HEIGHTS[j]-.3)
            obj.data.vertices[b+1].co=(q[0]+side*(SEA_SPAN+BASE_WIDTHS[j]*.3),q[1],BED_HEIGHTS[j]-.3)
        obj.data.update()
        update_foam_attribute(obj)
    for obj,side,indices,zfraction,radius in FOAM_CURVES:
        local=part_progress(progress,sum(indices)/len(indices))
        obj.hide_render=local<.08
        for p,j in zip(obj.data.splines[0].points,indices):p.co=(*water_point(side,j,zfraction,progress,phase),1)
        obj.data.bevel_depth=radius*max(.1,local)
    for obj,side,params,jc in FOAM_PATCHES:
        obj.hide_render=part_progress(progress,jc)<.2 or params[0][1]>.1
        for vertex,(jj,zz) in zip(obj.data.vertices,params):
            q=Vector(water_point(side,jj,zz,progress,phase));q.x-=side*.035;vertex.co=q
        obj.data.update()
    for obj,side,j,offset,rad in DROPLETS:
        local=part_progress(progress,j)
        obj.hide_render=local<.15
        u=(phase/(2*math.pi)+j*.137+rad*10)%1
        fade=math.sin(math.pi*u)**2
        drift=Vector((side*.45*u,.28*u,.8*math.sin(math.pi*u)))
        obj.location=Vector(water_point(side,j,1,progress,phase))+offset*local+drift*local
        obj.scale=(rad*fade,rad*fade,rad*1.6*fade)
    DRAIN.hide_render=True
    for obj,offset in LIQUID_PARTS:
        for i,v in enumerate(obj.data.vertices):LIQUID.data.vertices[offset+i].co=v.co
    LIQUID.data.update();update_foam_attribute(LIQUID)
    for obj,side,j in MISTS:
        local=part_progress(progress,j)
        obj.hide_render=local<.2
        obj.location=Vector(water_point(side,j,1,progress,phase))+Vector((-side*.3,0,.15))
    closed.hide_render=True
    bpy.context.view_layer.update()

update(1)
alignment={
    'camera':{'location':list(cam.location),'eulerRadians':list(cam.rotation_euler),'lensMm':cam.data.lens,'sensorWidthMm':cam.data.sensor_width,'aspect':[393,852]},
    'dryPolygon':DRY_POLYGON,
    'projectedSeaFeet':[[project(water_point(s,j,0,1,0)) for j in range(0,151,10)] for s in [-1,1]],
    'shoreFootNormalized':.765,'crowdRowsNormalized':[.867,.950],
    'oceanSurfaceLevel':SEA_LEVEL,'deepSeabedLevel':SEA_FLOOR,
    'technicalNote':'Sea-foot boundaries include a dry margin outside the full validated six-point drop polygon. Character feet are rendered by separate assets.'
}
def emit_projection_samples():
    # Samples are emitted by the SAME geometry functions, FFT phase and camera
    # used for rendering. The read-only verifier reconstructs no old wave math.
    feet=[];shore=[];phase_zero_lip=[]
    for phase_i in range(24):
        phase=phase_i/24*2*math.pi;prepare_ocean(phase)
        for side in [-1,1]:
            for j in range(241):
                jf=j/2
                feet.append({'side':side,'phaseIndex':phase_i,'row':jf,'point':project(water_point(side,jf,0,1,phase))})
            for k in range(TOP_WIDTH):
                q=Vector(water_point(side,150,1,0,phase));q.x+=side*top_offset(k,BASE_WIDTHS[150]);q.z=ocean_surface(q.x,q.y)
                point=project(q);shore.append(point)
                if phase_i==0:phase_zero_lip.append(point)
    alignment['nativeProjectionSamples']={'method':'Actual water_point/FFT field and render camera, 24 phases',
        'seaFeet':feet,'closedShoreTop':shore,'staffPhaseZeroTopEdge':sorted(phase_zero_lip)}
    alignment['seaShape']={'fixedSurfaceLevel':SEA_LEVEL,'deepSeabedLevel':SEA_FLOOR,
        'nativeOceanModifier':{'spectrum':'PHILLIPS','resolution':9,'spatialSize':64,'windVelocity':16,'waveScale':1.7},
        'staffContactNormalized':[.294,.743],'mosesFeetNormalized':[.265,.765],
        'topology':'One continuous external liquid boundary; no submerged inner refracting interfaces.'}
    prepare_ocean(0)

if MODE in ['clips','deep_clips','geometry_verify']:emit_projection_samples()
(OUT/'alignment.json').write_text(json.dumps(alignment,indent=2))
bpy.ops.wm.save_as_mainfile(filepath=str(OUT/'red_sea_environment.blend'))
if MODE in ['fluid_studies','fluid_fix']:
    scene.render.resolution_x=624;scene.render.resolution_y=1352;scene.cycles.samples=20
    folder=OUT/'fluid-studies-v3';folder.mkdir(exist_ok=True)
    for label,p,phase in ([('front',.44,.4),('open',1,0)] if MODE=='fluid_fix' else [('closed',0,0),('front',.44,.4),('open',1,0)]):
        update(p,phase)
        scene.render.filepath=str(folder/f'{label}.png');bpy.ops.render.render(write_still=True)
elif MODE=='fluid_motion':
    scene.render.resolution_x=312;scene.render.resolution_y=676;scene.cycles.samples=16
    folder=OUT/'fluid-studies-v3/motion';folder.mkdir(parents=True,exist_ok=True)
    for i in range(25):
        p=i/24;phase=math.sin(math.pi*p)*.75
        update(p,phase)
        scene.render.filepath=str(folder/f'{i:04d}.png');bpy.ops.render.render(write_still=True)
elif MODE=='deep_ready_review':
    scene.render.resolution_x=312;scene.render.resolution_y=676;scene.cycles.samples=16
    update(0)
    scene.render.filepath=str(OUT/'deep-sea-ready-review-v2.png');bpy.ops.render.render(write_still=True)
elif MODE=='deep_ready_loop':
    scene.render.resolution_x=312;scene.render.resolution_y=676;scene.cycles.samples=16
    for i in range(24):
        update(0,i/24*2*math.pi)
        scene.render.filepath=str(OUT/f'frames/sea_opening/{i:04d}.png');bpy.ops.render.render(write_still=True)
    shutil.copyfile(OUT/'frames/sea_opening/0000.png',OUT/'frames/sea_ready/0000.png')
    shutil.copyfile(OUT/'frames/sea_opening/0000.png',OUT/'frames/sea_opening/0024.png')
elif MODE=='deep_opening_patch':
    scene.render.resolution_x=312;scene.render.resolution_y=676;scene.cycles.samples=16
    for i in range(64):
        t=i/63*2.6
        if t<=1:
            if i==24:
                shutil.copyfile(OUT/'frames/sea_opening/0000.png',OUT/'frames/sea_opening/0024.png');continue
            update(0,i/24*2*math.pi)
        else:
            progress=max(0,min(1,(t-1)/1.6))
            update(progress,0)
        scene.render.filepath=str(OUT/f'frames/sea_opening/{i:04d}.png');bpy.ops.render.render(write_still=True)
    shutil.copyfile(OUT/'frames/sea_opening/0000.png',OUT/'frames/sea_ready/0000.png')
    shutil.copyfile(OUT/'frames/sea_idle/0000.png',OUT/'frames/sea_opening/0063.png')
elif MODE in ['preview','deep_preview']:
    scene.render.filepath=str(OUT/('deep-sea-review-v2.png' if MODE=='deep_preview' else 'open_sea_review.png'))
    bpy.ops.render.render(write_still=True)
elif MODE in ['ready_fix','ready_fix_cpu']:
    scene.render.resolution_x=312;scene.render.resolution_y=676;scene.cycles.samples=16
    if MODE=='ready_fix':
        try:
            prefs=bpy.context.preferences.addons['cycles'].preferences
            prefs.compute_device_type='METAL';prefs.refresh_devices()
            available=False
            for d in prefs.devices:
                d.use=d.type=='METAL'
                available=available or d.use
            if available:scene.cycles.device='GPU'
        except Exception as error:
            print('Metal unavailable; using CPU:',error)
    update(0)
    ready=OUT/'frames/sea_ready/0000.png'
    scene.render.filepath=str(ready);bpy.ops.render.render(write_still=True)
    for i in range(25):shutil.copyfile(ready,OUT/f'frames/sea_opening/{i:04d}.png')
elif MODE in ['clips','deep_clips']:
    scene.render.resolution_x=300;scene.render.resolution_y=650;scene.cycles.samples=12
    clips={'sea_ready':{'frames':'frames/sea_ready/*.png','durationSeconds':1,'loop':True},'sea_opening':{'frames':'frames/sea_opening/*.png','durationSeconds':2.6,'loop':False},'sea_idle':{'frames':'frames/sea_idle/*.png','durationSeconds':2,'loop':True}}
    for key in clips:(OUT/'frames'/key).mkdir(parents=True,exist_ok=True)
    update(0);scene.render.filepath=str(OUT/'frames/sea_ready/0000.png');bpy.ops.render.render(write_still=True)
    for i in range(64):
        t=i/63*2.6
        if t<=1:
            if i==0 or i==24:
                shutil.copyfile(OUT/'frames/sea_ready/0000.png',OUT/f'frames/sea_opening/{i:04d}.png')
            else:
                update(0,i/24*2*math.pi)
                scene.render.filepath=str(OUT/f'frames/sea_opening/{i:04d}.png');bpy.ops.render.render(write_still=True)
            continue
        p=max(0,min(1,(t-1)/1.6))
        update(p,p*2*math.pi)
        scene.render.filepath=str(OUT/f'frames/sea_opening/{i:04d}.png');bpy.ops.render.render(write_still=True)
    for i in range(48):
        update(1,i/48*2*math.pi)
        scene.render.filepath=str(OUT/f'frames/sea_idle/{i:04d}.png');bpy.ops.render.render(write_still=True)
    # Canonical endpoint avoids render-stamp/rounding differences between two
    # independent renders of the exact same update(1,0) scene.
    shutil.copyfile(OUT/'frames/sea_idle/0000.png',OUT/'frames/sea_opening/0063.png')
    for key,c in clips.items():
        c.update({'cellWidth':300,'cellHeight':650,'frameCount':1 if key=='sea_ready' else 64 if key=='sea_opening' else 48})
    manifest={'clips':clips,'cameraAspect':[393,852],'staffContactSeconds':1.0,'readyLoopCellCount':24,
              'openingWaterStartSeconds':1.0,'introIdleMatch':'Both use update(1,0).',
              'idleCycle':'Blender FFT height/foam fields sampled along two forward-moving time windows with C1 cosine crossfade; period two seconds.',
              'readyAlias':'Opening cells 0–23 form a complete 2π closed-sea loop; cell 24 repeats phase zero for staff contact.',
              'oceanSurfaceLevel':SEA_LEVEL,'deepSeabedLevel':SEA_FLOOR,
              'estimatedDecodedRgbaBytes':300*650*4*(1+64+48)}
    (OUT/'source-manifest.json').write_text(json.dumps(manifest,indent=2))
