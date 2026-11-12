"""Pack existing Blender pixels; no models, poses or painted art are synthesized."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
from PIL import Image, ImageDraw, ImageChops

HERE=Path(__file__).resolve().parent
MOBILE=HERE.parents[1]/'Frontend'/'mobile'
ASSET_ROOT='assets/images/games/ark_traffic'
CELL=160
SPECIES=('tortoise','elephant','goat','rabbit')


def main(runtime=False):
    output=MOBILE/ASSET_ROOT if runtime else HERE/'review'/'runtime'
    output.mkdir(parents=True,exist_ok=True)
    manifest={'version':1,'animals':{},'backgrounds':{}}
    provenance={'source_blend':'ark-traffic-source.blend','cell':CELL,'source_frames':{},'decoded_bytes':0}
    portraits=[]
    source_manifest=json.loads((HERE/'source-manifest.json').read_text())
    for species in SPECIES:
        atlas=Image.new('RGBA',(CELL*9,CELL*8))
        hashes=[]
        for direction in range(8):
            for frame in range(9):
                path=HERE/'frames'/species/('d%s-f%02d.png'%(direction,frame))
                with Image.open(path) as source:
                    if source.size!=(224,224): raise ValueError('Changed camera cell: '+str(path))
                    bounds=source.getchannel('A').getbbox()
                    if bounds is None or bounds[0]<=0 or bounds[1]<=0 or bounds[2]>=224 or bounds[3]>=224:
                        raise ValueError('Clipped or empty Blender animal: '+str(path))
                    img=source.convert('RGBA').resize((CELL,CELL),Image.Resampling.LANCZOS)
                    atlas.paste(img,(frame*CELL,direction*CELL))
                hashes.append(hashlib.sha256(path.read_bytes()).hexdigest())
            if len(set(hashes[direction*9+1:direction*9+9]))<4:
                raise ValueError('The authored walk did not evaluate: '+species+' view '+str(direction))
        filename=species+'-walk.webp'
        atlas.save(output/filename,'WEBP',lossless=True,method=6)
        anchor=source_manifest['species'][species]['foot_anchor']
        manifest['animals'][species]={'asset':ASSET_ROOT+'/'+filename,'cell':CELL,'directions':8,'frames':9,
            'foot_anchor':[round(v*CELL/224,3) for v in anchor]}
        provenance['source_frames'][species]=hashes
        provenance['decoded_bytes']+=atlas.width*atlas.height*4
        portraits.append((species,atlas.crop((0,0,CELL,CELL))))
        atlas.close()
    for number in(1,2,3):
        with Image.open(HERE/'review'/('level-%s-background.png'%number)) as source:
            path=output/('level-%s-background.webp'%number)
            source.convert('RGB').save(path,'WEBP',quality=93,method=6)
            manifest['backgrounds'][str(number)]=ASSET_ROOT+'/'+path.name
        # Only one level's environment is decoded in a game.
    provenance['decoded_bytes']+=960*1440*4
    atlas=Image.new('RGBA',(CELL*2,CELL))
    gate_frames=[]
    for frame in(0,1):
        with Image.open(HERE/'frames'/'gate'/('gate-f%s.png'%frame)) as img:
            gate_frames.append(img.convert('RGBA').copy())
            atlas.paste(img.convert('RGBA').resize((CELL,CELL),Image.Resampling.LANCZOS),(frame*CELL,0))
    if ImageChops.difference(*gate_frames).getbbox() is None:
        raise ValueError('The Blender gate hinge did not evaluate distinct states')
    atlas.save(output/'gate.webp','WEBP',lossless=True,method=6)
    gate_anchor=source_manifest['gate']['foot_anchor']
    manifest['gate']={'asset':ASSET_ROOT+'/gate.webp','cell':CELL,'directions':1,'frames':2,
        'foot_anchor':[round(v*CELL/224,3) for v in gate_anchor]}
    provenance['decoded_bytes']+=atlas.width*atlas.height*4
    atlas.close()
    if provenance['decoded_bytes']>48*1024**2: raise ValueError('Decoded scene exceeds48MiB')
    (output/'manifest.json').write_text(json.dumps(manifest,indent=2))
    provenance['blend_sha256']=hashlib.sha256((HERE/'ark-traffic-source.blend').read_bytes()).hexdigest()
    provenance['gate_frames_sha256']=[hashlib.sha256((HERE/'frames'/'gate'/('gate-f%s.png'%i)).read_bytes()).hexdigest() for i in(0,1)]
    provenance['background_frames_sha256']={str(i):hashlib.sha256((HERE/'review'/('level-%s-background.png'%i)).read_bytes()).hexdigest() for i in(1,2,3)}
    provenance['runtime_assets']={p.name:{'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'encoded_bytes':p.stat().st_size} for p in output.iterdir()}
    (HERE/'review'/'asset-provenance.json').write_text(json.dumps(provenance,indent=2))
    # This sheet only arranges the original export pixels for visual review.
    sheet=Image.new('RGB',(CELL*4, CELL+34),(231,240,216))
    draw=ImageDraw.Draw(sheet)
    for index,(name,portrait) in enumerate(portraits):
        sheet.paste(portrait,(index*CELL,8),portrait)
        draw.text((index*CELL+12,CELL+8),name,fill=(25,65,55))
    sheet.save(HERE/'review'/'runtime-animal-contact.png')
    print(json.dumps({'output':str(output),'decodedMiB':round(provenance['decoded_bytes']/1024**2,2),
                      'encodedMiB':round(sum(p.stat().st_size for p in output.iterdir())/1024**2,2)}))


if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--runtime',action='store_true')
    main(parser.parse_args().runtime)
