"""Eight diagnostic Blender frames before a full directional export."""
from pathlib import Path
import sys
import bpy
from mathutils import Vector

HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE))
import author_ark_traffic as author
bpy.ops.wm.open_mainfile(filepath=str(HERE/'ark-traffic-source.blend'))
bpy.context.window.scene=bpy.data.scenes['Ark animal studio']
scene=bpy.context.scene
scene.render.resolution_x=scene.render.resolution_y=512
scene.render.film_transparent=False
rigs=[o for o in scene.objects if o.type=='ARMATURE' and 'species' in o]
grass=author.material('Walk review grass',(.35,.59,.29))
author.rounded_box('Walk review planted ground',(0,0,-.08),(3,3,.08),grass,.02)
cam=scene.camera
cam.location=(0,-6.5,4.6)
cam.rotation_euler=(Vector((.12,0,.73))-cam.location).to_track_quat('-Z','Y').to_euler()
cam.data.ortho_scale=2.95
folder=HERE/'review'/'walk-study'
folder.mkdir(parents=True,exist_ok=True)
for species in('elephant','goat'):
    author.set_species(rigs,species)
    for index,frame in enumerate((1,3,5,7)):
        scene.frame_set(frame)
        scene.render.filepath=str(folder/('%s-pose-%s.png'%(species,index)))
        bpy.ops.render.render(write_still=True)
