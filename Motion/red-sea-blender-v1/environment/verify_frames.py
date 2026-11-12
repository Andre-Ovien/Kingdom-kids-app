"""Read-only sequence checks without external Python dependencies."""
from pathlib import Path
import hashlib
import json
import struct
import zlib

ROOT = Path(__file__).resolve().parent

def png_info(path):
    data=path.read_bytes()
    if data[:8]!=b'\x89PNG\r\n\x1a\n':raise ValueError(f'Invalid PNG: {path}')
    width,height,bits,color,*_=struct.unpack('>IIBBBBB',data[16:29])
    return {'width':width,'height':height,'bits':bits,'colorType':color,
            'sha256':hashlib.sha256(data).hexdigest(),'bytes':len(data)}

def rgba_alpha_range(path):
    data=path.read_bytes();offset=8;blocks=[];header=None
    while offset<len(data):
        size=struct.unpack('>I',data[offset:offset+4])[0]
        kind=data[offset+4:offset+8];chunk=data[offset+8:offset+8+size]
        if kind==b'IHDR':header=struct.unpack('>IIBBBBB',chunk)
        if kind==b'IDAT':blocks.append(chunk)
        offset+=size+12
        if kind==b'IEND':break
    w,h,bits,color,_,_,interlace=header
    if bits!=8 or color!=6 or interlace!=0:raise ValueError('Expected noninterlaced 8-bit RGBA PNG')
    raw=zlib.decompress(b''.join(blocks));stride=w*4;previous=bytearray(stride)
    minimum=255;maximum=0
    for y in range(h):
        off=y*(stride+1);filter_type=raw[off];row=bytearray(raw[off+1:off+1+stride])
        for x in range(stride):
            a=row[x-4] if x>=4 else 0;b=previous[x];c=previous[x-4] if x>=4 else 0
            if filter_type==1:prediction=a
            elif filter_type==2:prediction=b
            elif filter_type==3:prediction=(a+b)//2
            elif filter_type==4:
                p=a+b-c;pa=abs(p-a);pb=abs(p-b);pc=abs(p-c)
                prediction=a if pa<=pb and pa<=pc else b if pb<=pc else c
            else:prediction=0
            row[x]=(row[x]+prediction)&255
        alpha=row[3::4];minimum=min(minimum,min(alpha));maximum=max(maximum,max(alpha));previous=row
    return [minimum,maximum]

manifest=json.loads((ROOT/'source-manifest.json').read_text())
report={'clips':{},'errors':[]}
for name,clip in manifest['clips'].items():
    frames=sorted(ROOT.glob(clip['frames']));expected=clip['frameCount']
    if len(frames)!=expected:report['errors'].append(f'{name}: expected {expected}, found {len(frames)}')
    infos=[png_info(p) for p in frames]
    if any((i['width'],i['height'])!=(clip['cellWidth'],clip['cellHeight']) for i in infos):
        report['errors'].append(f'{name}: frame dimensions differ')
    report['clips'][name]={'count':len(frames),'dimensions':[clip['cellWidth'],clip['cellHeight']],
                           'totalPngBytes':sum(i['bytes'] for i in infos),
                           'firstAlphaRange':rgba_alpha_range(frames[0]),
                           'lastAlphaRange':rgba_alpha_range(frames[-1])}
    if report['clips'][name]['firstAlphaRange']!=[255,255] or report['clips'][name]['lastAlphaRange']!=[255,255]:
        report['errors'].append(f'{name}: transparency found')
opening=ROOT/'frames/sea_opening/0063.png';idle=ROOT/'frames/sea_idle/0000.png'
report['openingIdleSamePngBytes']=opening.read_bytes()==idle.read_bytes()
if not report['openingIdleSamePngBytes']:report['errors'].append('Intro endpoint differs from idle first frame')
if manifest.get('readyLoopCellCount'):
    loop_count=manifest['readyLoopCellCount']
    loop=[ROOT/f'frames/sea_opening/{i:04d}.png' for i in range(loop_count)]
    hashes={png_info(p)['sha256'] for p in loop}
    report['readyLoop']={'cellCount':loop_count,'distinctFrames':len(hashes),
                         'staffContactPhaseZero':loop[0].read_bytes()==(ROOT/'frames/sea_opening/0024.png').read_bytes()}
    if len(hashes)<2:report['errors'].append('Closed-sea ready loop has no animated frames')
    if not report['readyLoop']['staffContactPhaseZero']:report['errors'].append('Closed sea does not return to phase zero at staff contact')
report['estimatedDecodedRgbaBytes']=manifest['estimatedDecodedRgbaBytes']
(ROOT/'frame-verification.json').write_text(json.dumps(report,indent=2))
print(json.dumps(report,indent=2))
if report['errors']:raise SystemExit(1)
