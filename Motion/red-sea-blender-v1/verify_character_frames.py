"""Verify exported whole-character frames before runtime atlas packing."""
from pathlib import Path
import json
from PIL import Image, ImageChops

ROOT=Path(__file__).resolve().parent
manifest=json.loads((ROOT/'character-source-manifest.json').read_text())
expected={'moses_ready':1,'moses_action':63}
for idx in range(3):
    expected.update({f'traveller_{idx}_{clip}':count for clip,count in
                     [('idle',1),('turn',8),('walk',24),('back',1)]})
assert set(manifest['clips'])==set(expected),'Incomplete character clip contract'
report={'clips':{},'totalFrames':0,'turnWalkSeams':{}}
assert (ROOT/'frames/moses_ready/000.png').read_bytes()==(ROOT/'frames/moses_action/000.png').read_bytes(),'Moses ready/action-start mismatch'
for name,count in expected.items():
    clip=manifest['clips'][name]
    paths=sorted(ROOT.glob(clip['frames']))
    assert clip['frameCount']==count==len(paths),(name,count,len(paths))
    assert clip['durationSeconds']>0,(name,'duration')
    dimensions=(320,384) if name.startswith('moses') else (128,192)
    ax,ay=clip['footAnchor']
    assert 0<=ax<dimensions[0] and 0<=ay<dimensions[1],(name,'anchor')
    assert 0<clip['bodyHeight']<=dimensions[1],(name,'body height')
    union=None
    for path in paths:
        with Image.open(path) as im:
            assert im.mode=='RGBA' and im.size==dimensions,(name,path,im.mode,im.size)
            alpha=im.getchannel('A');box=alpha.getbbox()
            assert box is not None,(name,path,'empty')
            assert box[0]>0 and box[1]>0 and box[2]<dimensions[0] and box[3]<dimensions[1],(name,path,'clipped',box)
            if union is None:union=box
            else:union=(min(union[0],box[0]),min(union[1],box[1]),max(union[2],box[2]),max(union[3],box[3]))
    report['clips'][name]={'frameCount':count,'cellSize':dimensions,'footAnchor':[ax,ay],'alphaBounds':union}
    report['totalFrames']+=count
for idx in range(3):
    paths=[ROOT/f'frames/traveller_{idx}_{c}/{n}.png' for c,n in [('turn','007'),('walk','000'),('back','000')]]
    imgs=[Image.open(p).convert('RGBA') for p in paths]
    assert all(all(hi==0 for lo,hi in ImageChops.difference(imgs[0],im).getextrema()) for im in imgs[1:]),(idx,'turn/walk/back pose mismatch')
    report['turnWalkSeams'][str(idx)]='pixel-identical turn end, walk start and rear idle'
(ROOT/'review/character-frame-verification.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
