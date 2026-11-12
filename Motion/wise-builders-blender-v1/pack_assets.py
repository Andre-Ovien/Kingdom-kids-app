"""Pack unchanged keyed Blender renders into bounded mobile texture atlases."""
import json
from pathlib import Path
from PIL import Image

HERE=Path(__file__).resolve().parent;REPO=HERE.parents[1]
OUT=REPO/'Frontend/mobile/assets/images/games/wise_builders'
groups={'collapse':12,**{f'storm-{kind}':8 for kind in ('rain','wind','rain_and_wind')}}
for kind,count in groups.items():
    atlas=Image.new('RGBA',(256*count,256))
    for index in range(1,count+1):atlas.alpha_composite(Image.open(HERE/'frames'/f'{kind}-{index}.png').convert('RGBA'),((index-1)*256,0))
    atlas.save(OUT/f'{kind}.png',optimize=True)
proof=[]
standing=Image.open(OUT/'standing.png').convert('RGBA');rock=Image.open(OUT/'rock.png').convert('RGBA')
for index in range(1,13):
    canvas=Image.new('RGBA',(512,256),'#c9dfb0');canvas.alpha_composite(rock);canvas.alpha_composite(standing)
    canvas.alpha_composite(Image.open(HERE/'frames'/f'collapse-{index}.png').convert('RGBA'),(256,0))
    weather=Image.open(HERE/'frames'/f'storm-rain_and_wind-{1+(index-1)%8}.png').convert('RGBA')
    canvas.alpha_composite(weather);canvas.alpha_composite(weather,(256,0));proof.append(canvas.convert('RGB'))
proof[0].save(HERE/'review-storm-motion.gif',save_all=True,append_images=proof[1:],duration=250,loop=0)
manifest={'version':1,'native_source':'Motion/wise-builders-blender-v1/wise-builders-source.blend',
          'provenance':'Original Blender architecture, carved rock and loose sand, 12 keyed safe-collapse frames and 8 keyed wind/rain frames. No occupants.',
          'cell':256,'collapse_frames':12,'weather_frames':8,'decoded_budget_bytes':36*1024*1024,
          'assets':[path.name for path in OUT.glob('*.png')]}
(OUT/'manifest.json').write_text(json.dumps(manifest,indent=2))
template=(HERE/'preview.template.html').read_text()
(HERE/'preview.html').write_text(template)
print(f'Packed {len(manifest["assets"])} Builders textures, native-motion GIF and interactive review.')
