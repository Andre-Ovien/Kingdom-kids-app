"""Read-only audit of the native Blender rigs and continuous limb topology."""
from pathlib import Path
import hashlib
import json
import bpy

HERE=Path(__file__).resolve().parent
source=HERE/'ark-traffic-source.blend'
bpy.ops.wm.open_mainfile(filepath=str(source))
studio=bpy.data.scenes['Ark animal studio']
report={'source_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),'animals':{},
        'scenes':[s.name for s in bpy.data.scenes]}
for rig in (obj for obj in studio.objects if obj.type=='ARMATURE'):
    species=rig.get('species')
    if not species: continue
    skins=[obj for obj in rig.children if obj.type=='MESH' and 'continuous leg and planted foot' in obj.name]
    assert len(skins)==4,(species,'four continuous limb skins required')
    limbs={}
    for row in('front','back'):
        for side in('L','R'):
            name=row+'.'+side
            upper,lower,foot=(rig.data.bones[name+s] for s in('','.shin','.foot'))
            assert lower.parent==upper and foot.parent==lower
            assert (upper.tail_local-lower.head_local).length<1e-8
            assert (lower.tail_local-foot.head_local).length<1e-8
            skin=next(obj for obj in skins if obj.name.startswith(name+' '))
            adjacency={i:set() for i in range(len(skin.data.vertices))}
            for edge in skin.data.edges:
                a,b=edge.vertices;adjacency[a].add(b);adjacency[b].add(a)
            reached,pending={0},[0]
            while pending:
                for next_vertex in adjacency[pending.pop()]:
                    if next_vertex not in reached:reached.add(next_vertex);pending.append(next_vertex)
            assert len(reached)==len(skin.data.vertices),'The planted foot must belong to the leg surface'
            assert all(abs(sum(g.weight for g in vertex.groups)-1)<1e-6 for vertex in skin.data.vertices)
            assert any(mod.type=='ARMATURE' and mod.object==rig for mod in skin.modifiers)
            limbs[name]={'connected_vertices':len(reached),'surface_components':1,'weight_sum':1,
                         'joint_heads_match':True}
    assert rig.animation_data and rig.animation_data.action
    report['animals'][species]={'limbs':limbs,'walk_action':rig.animation_data.action.name,
                               'body_meshes':sum(obj.type=='MESH' for obj in rig.children)}
assert set(report['animals'])=={'tortoise','elephant','goat','rabbit'}
(HERE/'review'/'native-rig-validation.json').write_text(json.dumps(report,indent=2))
print(json.dumps({'rigs':4,'continuous_skinned_limbs':16,'matched_anatomical_joints':32}))
