"""Verify and pack the approved wrapped gift, preserving exact straight RGBA."""
from pathlib import Path
import json
from PIL import Image, ImageChops, ImageDraw, ImageFont

ROOT=Path(__file__).resolve().parent.parent
runtime=ROOT/'runtime';review=ROOT/'review'
manifest=json.loads((runtime/'box_reveal.json').read_text())
atlas=Image.new('RGBA',(3520,2816),(0,0,0,0));boxes=[]
for i in range(80):
    frame=Image.open(runtime/f'gift-{i:03d}.png').convert('RGBA')
    if frame.size!=(352,352):raise ValueError(f'Frame {i} has wrong dimensions')
    boxes.append(frame.getchannel('A').getbbox())
    atlas.paste(frame,((i%10)*352,(i//10)*352))
    backdrop=Image.new('RGBA',frame.size,(12,25,37,255));backdrop.alpha_composite(frame)
    backdrop.convert('RGB').save(review/f'motion-{i:03d}.jpg',quality=94)
atlas.save(runtime/'box_reveal_atlas.webp',lossless=True,method=6,exact=True)
poster=Image.open(runtime/'gift-079.png').convert('RGBA')
poster.save(runtime/'box_reveal_poster.webp',lossless=True,method=6,exact=True)
decoded=Image.open(runtime/'box_reveal_atlas.webp').convert('RGBA')
exact=all(channel.getbbox() is None for channel in ImageChops.difference(atlas,decoded).split())
unclipped=all(box and box[0]>0 and box[1]>0 and box[2]<352 and box[3]<352 for box in boxes)
report={'frames':80,'atlasDimensions':[3520,2816],'fps':20,'durationSeconds':4,
        'decodedMiB':3520*2816*4/1024**2,'encodedAtlasBytes':(runtime/'box_reveal_atlas.webp').stat().st_size,
        'posterBytes':(runtime/'box_reveal_poster.webp').stat().st_size,
        'allFramesUnclippedWithTransparentMargins':unclipped,'exactRgbaDecode':exact,
        'alphaBoundsUnion':[min(b[0] for b in boxes),min(b[1] for b in boxes),max(b[2] for b in boxes),max(b[3] for b in boxes)]}
(runtime/'verification.json').write_text(json.dumps(report,indent=2)+'\n')
sheet=Image.new('RGB',(1408,776),(12,25,37));draw=ImageDraw.Draw(sheet);font=ImageFont.load_default(size=18)
for tile,i in enumerate([0,18,30,35,40,47,59,79]):
    x=(tile%4)*352;y=(tile//4)*388
    sheet.paste(Image.open(review/f'motion-{i:03d}.jpg'),(x,y));draw.text((x+12,y+361),f'{i/20:.2f}s / frame {i:02d}',font=font,fill=(247,217,163))
sheet.save(review/'gift-contact-sheet.jpg',quality=94)
print(json.dumps(report,indent=2))
if not exact or not unclipped:raise SystemExit('Asset verification failed; do not copy runtime files')
