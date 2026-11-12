"""Pack Blender PNG frames into a runtime atlas and review contact sheets.

Uses bundled Pillow; no external art inputs and no AI image editing.
"""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont
import json
import sys

ROOT=Path(__file__).resolve().parent.parent
review=ROOT/'review'
runtime=ROOT/'runtime'
labels=['0.00s / still','0.88s / anticipation','1.42s / seam glow',
        '1.67s / release','1.92s / opening','2.38s / open',
        '2.96s / hold','3.96s / final']
font=ImageFont.load_default(size=18)
sheet=Image.new('RGB',(1080,1032),(8,20,28))
draw=ImageDraw.Draw(sheet)
for i,path in enumerate(sorted(review.glob('timeline-*.png'))):
    image=Image.open(path).convert('RGB')
    x=(i%4)*270
    y=(i//4)*516
    sheet.paste(image,(x,y))
    draw.text((x+12,y+486),labels[i],font=font,fill=(235,211,163))
sheet.save(review/'timeline-contact-sheet.jpg',quality=94)

if '--runtime' in sys.argv:
    manifest=json.loads((runtime/'manifest.json').read_text())
    manifest['atlases'][0]['asset']='assets/images/milestones/box_reveal_atlas.webp'
    manifest['posterAsset']='assets/images/milestones/box_reveal_poster.webp'
    manifest['boxAnchor']=[.50,.54]
    manifest['floorAnchor']=[.50,.925]
    manifest.pop('boxFloorAnchor',None)
    n=manifest['frameCount']
    size=manifest['cellWidth']
    columns=manifest['columns']
    rows=(n+columns-1)//columns
    atlas=Image.new('RGBA',(columns*size,rows*size),(0,0,0,0))
    footprints=[]
    for i in range(n):
        frame=Image.open(runtime/f'chest-{i:03d}.png').convert('RGBA')
        if frame.size!=(size,size):
            raise ValueError(f'Wrong frame size: {i}: {frame.size}')
        # Normal paste preserves straight-alpha exactly, including soft edge pixels.
        atlas.paste(frame,((i%columns)*size,(i//columns)*size))
        footprints.append(frame.getchannel('A').getbbox())
    atlas.save(runtime/'box_reveal_atlas.webp',lossless=True,method=6,exact=True)
    final=Image.open(runtime/f'chest-{n-1:03d}.png').convert('RGBA')
    final.save(runtime/'box_reveal_poster.webp',lossless=True,method=6,exact=True)
    (runtime/'box_reveal.json').write_text(json.dumps(manifest,indent=2)+'\n')
    (runtime/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    report={'frames':n,'atlasSize':atlas.size,
            'decodedMiB':atlas.width*atlas.height*4/1024**2,
            'encodedAtlasBytes':(runtime/'box_reveal_atlas.webp').stat().st_size,
            'posterBytes':(runtime/'box_reveal_poster.webp').stat().st_size,
            'allFramesTransparentCorners':all(b and b[0]>0 and b[1]>0 and b[2]<size and b[3]<size for b in footprints),
            'alphaBoundingBoxUnion':[min(b[0] for b in footprints),min(b[1] for b in footprints),
                                     max(b[2] for b in footprints),max(b[3] for b in footprints)]}
    from PIL import ImageChops
    decoded=Image.open(runtime/'box_reveal_atlas.webp').convert('RGBA')
    report['losslessDecodedPixelsMatch']=all(channel.getbbox() is None for channel in ImageChops.difference(atlas,decoded).split())
    (runtime/'verification.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))
    # Motion proof with runtime framing; navy is only for review, never in atlas.
    for i in range(n):
        frame=Image.open(runtime/f'chest-{i:03d}.png').convert('RGBA')
        background=Image.new('RGBA',(size,size),(7,20,30,255))
        background.alpha_composite(frame)
        background.convert('RGB').save(review/f'motion-{i:03d}.jpg',quality=94)
    sample_indices=[0,18,28,33,38,47,59,79]
    motion_sheet=Image.new('RGB',(size*4,(size+36)*2),(7,20,30))
    motion_draw=ImageDraw.Draw(motion_sheet)
    for tile,i in enumerate(sample_indices):
        motion_sheet.paste(Image.open(review/f'motion-{i:03d}.jpg'),((tile%4)*size,(tile//4)*(size+36)))
        motion_draw.text(((tile%4)*size+12,(tile//4)*(size+36)+size+8),
                         f'{i/20:.2f}s / frame {i:02d}',font=font,fill=(235,211,163))
    motion_sheet.save(review/'runtime-contact-sheet.jpg',quality=94)
