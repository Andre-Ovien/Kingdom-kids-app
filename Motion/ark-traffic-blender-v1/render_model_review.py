"""One Blender review still: all original models and their modeled setting."""
from pathlib import Path
import sys
import bpy
from mathutils import Vector

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import author_ark_traffic as author

rigs = author.build()
scene = bpy.context.scene
scene.render.resolution_x, scene.render.resolution_y = 1600, 1200
scene.render.film_transparent = False
placements = {'elephant': (-1.72, -.84, 0), 'goat': (1.06, -.64, 0),
              'tortoise': (-1.10, 1.24, 0), 'rabbit': (1.42, 1.30, 0)}
for rig in rigs:
    rig.location = placements[rig['species']]
    rig.animation_data.action = None
    for pb in rig.pose.bones:
        pb.location = (0, 0, 0)
        pb.rotation_euler = (0, 0, 0)
grass = author.material('Review meadow', (.38,.62,.30))
author.rounded_box('Review meadow stage', (0,1,-.20), (5.5,5.4,.20), grass, .18)
water=author.material('Review rich river',(.10,.50,.62),.24)
author.rounded_box('Review blue river behind the animals',(0,2.7,.006),(4.5,.72,.015),water,.30)
rock=author.material('Review rounded river pebbles',(.42,.47,.34))
for i in range(12):
    author.sphere('Review bank pebble',(-4.1+i*.69,2.03+(i%2)*1.34,.08),(.16,.10,.08),rock,segments=12)
before = set(bpy.data.objects)
author.ark_model(.5,.31)
ark_parts = set(bpy.data.objects)-before
root=bpy.data.objects.new('Review small ark group',None)
bpy.context.collection.objects.link(root)
for obj in ark_parts: obj.parent=root
root.scale=(.72,.72,.72)
root.location=(.8,1.0,0)
for i,(x,y,s) in enumerate(((.18,.31,.74),(.90,.23,.68),(.83,.70,.50))):
    author.tree('Review living meadow tree %s'%i,x,y,s)
wood=author.material('Review bridge cedar',(.66,.43,.21))
for i in range(8):
    author.rounded_box('Review bridge individual plank',(-2.7,2.45+i*.16,.075),(.45,.072,.075),wood,.025)
for side in(-1,1):
    for i in range(4):
        author.rounded_box('Review bridge post',(-2.7+side*.44,2.45+i*.38,.34),(.026,.026,.32),wood,.012)
    author.beam_between('Review bridge rail',(-2.7+side*.44,2.4,.66),(-2.7+side*.44,3.65,.66),.048,.045,wood)
cam=scene.camera
cam.location=(5.2,-8.6,8.3)
cam.rotation_euler=(Vector((0,1.0,.65))-cam.location).to_track_quat('-Z','Y').to_euler()
cam.data.ortho_scale=7.8
scene.render.filepath=str(HERE/'review'/'original-animals-and-ark-v2.png')
bpy.ops.render.render(write_still=True)
# Review staging stays in its own source file; production source is clean.
bpy.ops.wm.save_as_mainfile(filepath=str(HERE/'ark-model-review.blend'))
