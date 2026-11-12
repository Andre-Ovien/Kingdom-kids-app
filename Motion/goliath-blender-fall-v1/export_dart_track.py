"""Generate the mobile track from Blender's evaluated 120 Hz joint bake.
A 60 Hz track is linearly sampled at the model's 120 Hz fixed step. Every
joint shares the same interpolation fraction; no limb moves independently.
"""
import hashlib,json,pathlib
OUT=pathlib.Path(__file__).resolve().parent; ROOT=OUT.parents[1]
data_path=OUT/'blender-fall-joints.json'; data=json.loads(data_path.read_text())
path=ROOT/'Frontend/mobile/lib/features/games/presentation/goliath_blender_fall_track.dart'
text=['// Generated from Blender 4.5.9 LTS; do not hand-edit sample coordinates.', '// Source: Motion/goliath-blender-fall-v1/goliath-controlled-fall.blend', '// Regenerate: author_goliath_fall.py, then export_dart_track.py.', '// Joint order matches GoliathJoint; original artwork UVs remain unchanged.', f'// Bake SHA256: {hashlib.sha256(data_path.read_bytes()).hexdigest()}', '', 'class GoliathBlenderFallTrack {', '  GoliathBlenderFallTrack._();', '  static const framesPerSecond = 60;', f"  static const durationSeconds = {data['duration']};", f"  static const settledAtSeconds = {data['settled_at']};", f"  static const coordinatesPerFrame = {len(data['joint_order'])*2};", '']
for side in ['right','left']:
 text.append(f'  static const {side} = <List<double>>[')
 for frame in data['directions'][side][::2]:
  text.append('    ['+','.join(format(v,'.8f').rstrip('0').rstrip('.') if v else '0' for v in frame)+'],')
 text.extend(['  ];',''])
text.append('}');path.write_text('\n'.join(text)+'\n')
print(f'Exported {path.name}: {path.stat().st_size} bytes; 145 shared joint frames per side')
