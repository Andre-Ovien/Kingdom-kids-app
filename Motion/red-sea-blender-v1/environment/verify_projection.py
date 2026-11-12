"""Read-only checks of emitted native geometry; no guessed wave reconstruction."""
import json
from pathlib import Path
root=Path(__file__).resolve().parent
a=json.loads((root/'alignment.json').read_text())
s=a['nativeProjectionSamples']
def left_boundary(y):
    if y<=.43:return .43-(y-.33)/.1*.135
    return .295-(y-.43)/.27*.15
margins=[]
for sample in s['seaFeet']:
    x,y=sample['point']
    if .33<=y<=.70:
        bound=left_boundary(y)
        margins.append(bound-x if sample['side']<0 else x-(1-bound))
shore_y=[q[1] for q in s['closedShoreTop'] if 0<=q[0]<=1]
contact_x,contact_y=a['seaShape']['staffContactNormalized']
contact_shore=None
lip=s['staffPhaseZeroTopEdge']
for (xa,ya),(xb,yb) in zip(lip,lip[1:]):
    if xa<=contact_x<=xb and xb>xa:
        contact_shore=ya+(yb-ya)*(contact_x-xa)/(xb-xa);break
report={'checkedFootSamples':len(margins),'method':s['method'],
        'fullDryPolygonFootMinMargin':min(margins),'seaFeetOutsideFullPolygon':min(margins)>0,
        'animatedClosedShoreScreenYRange':[min(shore_y),max(shore_y)],
        'mosesFeetNormalized':a['seaShape']['mosesFeetNormalized'],
        'mosesDryClearanceY':.765-max(shore_y),
        'staffContactNormalized':[contact_x,contact_y],
        'closedTopEdgeYAtStaffContact':contact_shore,
        'staffOnSeaSideOfTopEdge':contact_shore is not None and contact_y<=contact_shore,
        'staffContactTopEdgeClearancePixelsAt844':(contact_shore-contact_y)*844,
        'oceanSurfaceLevel':a['oceanSurfaceLevel'],'deepSeabedLevel':a['deepSeabedLevel']}
assert report['seaFeetOutsideFullPolygon'],report
assert report['mosesDryClearanceY']>0,report
assert report['staffOnSeaSideOfTopEdge'],report
(root/'projection-verification.json').write_text(json.dumps(report,indent=2))
print(json.dumps(report,indent=2))
