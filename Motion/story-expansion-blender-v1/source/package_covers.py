"""Package the five original Blender covers and a labeled review contact sheet."""
from pathlib import Path
from PIL import Image,ImageDraw,ImageFont,ImageChops
import json,hashlib

ROOT=Path(__file__).resolve().parent.parent
REPO=ROOT.parent.parent
output=REPO/'Frontend/mobile/assets/images/stories'
stories=[('lost-sheep','The Lost Sheep'),('joseph-colorful-coat','Joseph and His Colorful Coat'),
         ('good-samaritan','The Good Samaritan'),('walls-of-jericho','The Walls of Jericho'),
         ('ruth-and-naomi','Ruth and Naomi')]
sheet=Image.new('RGB',(1200,880),(17,34,30));draw=ImageDraw.Draw(sheet);font=ImageFont.load_default(size=18)
report=[]
for i,(slug,title) in enumerate(stories):
    source=ROOT/'review'/f'{slug}-hero.png';image=Image.open(source).convert('RGB')
    if image.size!=(1024,1024):raise ValueError(f'{slug} is not a 1024-square final render')
    destination=output/f'{slug}-blender-v1.webp'
    image.save(destination,lossless=True,method=6,exact=True)
    decoded=Image.open(destination).convert('RGB')
    exact=all(channel.getbbox() is None for channel in ImageChops.difference(image,decoded).split())
    if not exact:raise ValueError(f'{slug} differs from its original Blender pixels')
    x=(i%3)*400;y=(i//3)*440
    sheet.paste(image.resize((400,400),Image.Resampling.LANCZOS),(x,y))
    draw.text((x+12,y+408),title,font=font,fill=(247,226,176))
    report.append({'slug':slug,'asset':f'assets/images/stories/{slug}-blender-v1.webp',
                   'dimensions':[1024,1024],'encodedBytes':destination.stat().st_size,
                   'sha256':hashlib.sha256(destination.read_bytes()).hexdigest(),
                   'exactDecodedPixels':exact,'sourceBlend':f'source/{slug}.blend'})
sheet.save(ROOT/'review/story-cover-contact-sheet.jpg',quality=95)
(ROOT/'data/cover-manifest.json').write_text(json.dumps({'version':1,'covers':report},indent=2)+'\n')
print(json.dumps(report,indent=2))
