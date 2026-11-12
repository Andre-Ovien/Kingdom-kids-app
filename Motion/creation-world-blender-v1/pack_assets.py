"""Pack unchanged Blender frames and create a local interactive review."""
import json
from pathlib import Path
from PIL import Image

HERE=Path(__file__).resolve().parent
REPO=HERE.parents[1]
OUT=REPO/'Frontend/mobile/assets/images/games/creation_world'
for kind in ('fish','bird'):
    frames=[Image.open(HERE/'frames'/f'{kind}-{i}.png').convert('RGBA') for i in range(1,9)]
    atlas=Image.new('RGBA',(224*8,224))
    for i,frame in enumerate(frames):atlas.alpha_composite(frame,(224*i,0))
    atlas.save(OUT/f'{kind}.png',optimize=True)
review=[]
for index in range(1,9):
    canvas=Image.new('RGBA',(448,224),'#cce5dd')
    for col,kind in enumerate(('fish','bird')):
        canvas.alpha_composite(Image.open(HERE/'frames'/f'{kind}-{index}.png').convert('RGBA'),(col*224,0))
    review.append(canvas.convert('RGB'))
review[0].save(HERE/'review-creature-motion.gif',save_all=True,append_images=review[1:],duration=125,loop=0)
manifest={'version':1,'provenance':'Original native Blender meshes and keyed fin/wing motion; original Ark quadruped rigs/atlases reused.',
          'native_source':'Motion/creation-world-blender-v1/creation-world-source.blend',
          'motion_frames':8,'motion_cell':224,'animal_source':'assets/images/games/ark_traffic/manifest.json',
          'decoded_budget_bytes':40*1024*1024,'assets':[p.name for p in OUT.glob('*.png')]}
(OUT/'manifest.json').write_text(json.dumps(manifest,indent=2))
template=(HERE/'preview.template.html').read_text()
levels=json.loads((HERE/'world-levels.json').read_text())
(HERE/'preview.html').write_text(template.replace('__LEVELS__',json.dumps(levels)))
print(f'Packed {len(manifest["assets"])} Creation Blender textures, keyed-motion GIF and interactive preview.')
