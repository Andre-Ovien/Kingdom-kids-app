"""Package unchanged Blender frames into an eight-second proof and timeline."""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont
import json
import subprocess

ROOT=Path(__file__).resolve().parent.parent
frames=ROOT/'review/reference-study'
paths=[frames/f'{i:03d}.png' for i in range(192)]
missing=[str(path) for path in paths if not path.exists()]
if missing:
    raise RuntimeError(f'Missing Blender frames: {missing}')
dimensions={Image.open(path).size for path in paths}
assert dimensions=={(256,456)}, dimensions
proof=ROOT/'review/reference-motion-proof.mp4'
subprocess.run([
    '/opt/homebrew/bin/ffmpeg','-hide_banner','-loglevel','error','-y',
    '-framerate','24','-i',str(frames/'%03d.png'),'-frames:v','192',
    '-c:v','libx264','-preset','fast','-crf','17','-pix_fmt','yuv420p',
    '-movflags','+faststart',str(proof),
],check=True)
probe=json.loads(subprocess.check_output([
    '/opt/homebrew/bin/ffprobe','-v','error','-select_streams','v:0',
    '-show_entries','stream=width,height,r_frame_rate,nb_frames,duration',
    '-of','json',str(proof),
]))['streams'][0]
assert probe['nb_frames']=='192' and probe['r_frame_rate']=='24/1', probe
assert float(probe['duration'])==8.0, probe
times=[0,.5,1.0,1.7,2.32,3.33,4.3,4.88,5.48,5.75,6.13,6.57,7.15,7.96]
columns=7;cell_w=192;cell_h=342;label_h=28
sheet=Image.new('RGB',(columns*cell_w,2*(cell_h+label_h)),(36,7,22))
draw=ImageDraw.Draw(sheet)
try:font=ImageFont.truetype('/System/Library/Fonts/Supplemental/Arial.ttf',17)
except OSError:font=ImageFont.load_default()
for i,seconds in enumerate(times):
    index=min(191,round(seconds*24));x=(i%columns)*cell_w;y=(i//columns)*(cell_h+label_h)
    frame=Image.open(paths[index]).convert('RGB').resize((cell_w,cell_h),Image.Resampling.LANCZOS)
    sheet.paste(frame,(x,y));draw.text((x+8,y+cell_h+5),f'{index/24:.2f}s',font=font,fill=(255,240,249))
sheet.save(ROOT/'review/reference-motion-contact-sheet.jpg',quality=94)
manifest={
    'status':'Review only; runtime promotion held',
    'source':'source/reference-white-red-present.blend',
    'proof':'review/reference-motion-proof.mp4',
    'frameCount':192,'fps':24,'durationSeconds':8,
    'width':256,'height':456,
    'timings':{'lidLaunch':5.48,'panelOpening':5.67,'boxOpen':6.62,
               'burst':6.22,'badgeStart':6.3,'badgeEnd':7.1},
    'dynamicBadge':'Flutter overlays earned medal and copy; no prize/text baked',
    'sourceClipIsRuntimeAsset':False,
    'verification':probe,
}
(ROOT/'review/reference-review-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print(json.dumps({'proof':str(proof),'contactSheet':str(ROOT/'review/reference-motion-contact-sheet.jpg'),'verified':probe},indent=2))
