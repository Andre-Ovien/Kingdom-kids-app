"""Package the real native frames into a 12-second, three-level visual review."""
import json,pathlib,subprocess
from PIL import Image,ImageDraw,ImageFont
OUT=pathlib.Path(__file__).resolve().parent
REVIEW=OUT/'native-review'
rows=json.loads((REVIEW/'native-review-timings.json').read_text())
font='/System/Library/Fonts/Avenir Next.ttc'
label=ImageFont.truetype(font,18)
parts=[]
for row in rows:
 level=row['level']; start=max(0,round(row['impact_seconds']*30)-5)
 # Capture retains the landed pose after recording the real completion cue.
 start=min(start,row['native_frames']-120)
 part=OUT/f'native-level-{level}-fall.mp4';parts.append(part)
 cmd=['/opt/homebrew/bin/ffmpeg','-y','-v','error','-f','rawvideo','-pixel_format','rgb24','-video_size','390x874','-framerate','30','-i','pipe:0','-frames:v','120','-c:v','libx264','-preset','medium','-crf','18','-pix_fmt','yuv420p','-movflags','+faststart',str(part)]
 encoder=subprocess.Popen(cmd,stdin=subprocess.PIPE)
 for index in range(start,start+120):
  frame=Image.open(REVIEW/f'level{level}'/f'frame_{index:04d}.png').convert('RGB')
  padded=Image.new('RGB',(390,874),(23,37,54));padded.paste(frame,(0,0))
  text=f'Level {level}'; draw=ImageDraw.Draw(padded);box=draw.textbbox((0,0),text,font=label)
  draw.text(((390-(box[2]-box[0]))/2,846),text,font=label,fill='white')
  encoder.stdin.write(padded.tobytes())
 encoder.stdin.close()
 if encoder.wait()!=0: raise RuntimeError(f'Native level {level} encoding failed')
concat=OUT/'native-review-parts.txt';concat.write_text(''.join("file '"+str(p)+"'\n" for p in parts))
subprocess.run(['/opt/homebrew/bin/ffmpeg','-y','-v','error','-f','concat','-safe','0','-i',str(concat),'-c','copy','-movflags','+faststart',str(OUT/'goliath-blender-native-all-three.mp4')],check=True)
# Focused crops retain each level's actual actor size and source pixels.
stages=[('Standing','standing'),('Knee buckle','buckle'),('Contact','contact'),('Landed','settled')]
sheet=Image.new('RGB',(390*len(stages),380*3),(250,247,237))
landed=Image.new('RGB',(390*3,874),(23,37,54))
for row in rows:
 level=row['level']; tx=row['target']['x']/320*390; ty=row['target']['y']/420*844
 width=min(390*.78*.75,(tx-8)/.451,(382-tx)/.549);top=ty-width/.75*.115
 crop_top=round(top-20)
 for col,(name,stage) in enumerate(stages):
  frame=Image.open(REVIEW/f'level{level}-{stage}.png').convert('RGB')
  crop=frame.crop((0,crop_top,390,crop_top+350))
  x=col*390;y=(level-1)*380
  sheet.paste(crop,(x,y+30));ImageDraw.Draw(sheet).text((x+10,y+5),f'Level {level} · {name}',font=label,fill=(23,37,54))
 frame=Image.open(REVIEW/f'level{level}-settled.png').convert('RGB');landed.paste(frame,((level-1)*390,0));ImageDraw.Draw(landed).text(((level-1)*390+150,848),f'Level {level}',font=label,fill='white')
sheet.save(OUT/'all-three-native-contact-sheet.jpg',quality=94)
landed.save(OUT/'all-three-native-landed.jpg',quality=94)
print('Packaged 12-second native clip, all-three contact sheet and full-view landed stills')
