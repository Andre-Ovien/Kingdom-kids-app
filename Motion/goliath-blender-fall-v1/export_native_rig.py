"""Export the exact Dart renderer mesh without a Flutter engine or UI build.

The renderer source is evaluated by Dart after replacing only its platform types
with value-only doubles. No triangulation, UVs, weights, or source artwork are
approximated. The resulting temporary Dart file is an audit aid, not app code.
"""
import pathlib, subprocess
ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = pathlib.Path(__file__).resolve().parent
source = (ROOT/'Frontend/mobile/lib/features/games/presentation/goliath_mesh_renderer.dart').read_text()
start = source.index('class GoliathMeshPainter')
end = source.index('class _MeshSection', start)
source = source[:start] + source[end:]
source = source.replace("import 'dart:ui' as ui;", "import 'dart:convert';\nimport 'dart:io';")
source = source.replace("import 'package:flutter/material.dart';", '')
source = source.replace("import 'goliath_motion_model.dart';", "import '../../Frontend/mobile/lib/features/games/presentation/goliath_motion_model.dart';")
stubs = '''
class Offset {
  const Offset(this.dx,this.dy);
  final double dx,dy;
  Offset operator +(Offset p)=>Offset(dx+p.dx,dy+p.dy);
  Offset operator -(Offset p)=>Offset(dx-p.dx,dy-p.dy);
  Offset operator *(double f)=>Offset(dx*f,dy*f);
  Offset operator /(double f)=>Offset(dx/f,dy/f);
  double get distanceSquared=>dx*dx+dy*dy;
  double get distance=>math.sqrt(distanceSquared);
  @override bool operator ==(Object p)=>p is Offset&&dx==p.dx&&dy==p.dy;
  @override int get hashCode=>Object.hash(dx,dy);
}
class Size {
  const Size(this.width,this.height);
  final double width,height;
  @override bool operator ==(Object p)=>p is Size&&width==p.width&&height==p.height;
  @override int get hashCode=>Object.hash(width,height);
}
class Rect {
  const Rect.fromLTWH(this.left,this.top,this.width,this.height);
  factory Rect.fromPoints(Offset a,Offset b)=>Rect.fromLTWH(math.min(a.dx,b.dx),math.min(a.dy,b.dy),(a.dx-b.dx).abs(),(a.dy-b.dy).abs());
  final double left,top,width,height;
  double get right=>left+width;
  double get bottom=>top+height;
  bool overlaps(Rect r)=>left<r.right&&right>r.left&&top<r.bottom&&bottom>r.top;
  Rect expandToInclude(Rect r)=>Rect.fromLTWH(math.min(left,r.left),math.min(top,r.top),math.max(right,r.right)-math.min(left,r.left),math.max(bottom,r.bottom)-math.min(top,r.top));
}
void main(List<String> args) {
  final mesh=GoliathSkinMesh();
  List<List<double>> outline(List<GoliathPoint> p)=>[for(final v in p)[v.x,v.y]];
  final data={
    'source':'Exact native Dart UV mesh and weights',
    'artwork':'Frontend/mobile/assets/images/games/goliath-angry-v2.png',
    'reconstruction':'Frontend/mobile/assets/images/games/goliath-body-rig-v3.png',
    'aspect':GoliathMotionModel.aspectRatio,
    'ground':GoliathMotionModel.groundY,
    'joints':{for(final e in GoliathMotionModel.restJoints.entries)e.key.name:[e.value.x,e.value.y]},
    'radii':{for(final e in GoliathMotionModel.collisionRadii.entries)e.key.name:e.value},
    'bones':[for(var i=0;i<_bones.length;i++){'name':_Bone.values[i].name,'from':_bones[i].$1.name,'to':_bones[i].$2.name}],
    'vertices':[for(final p in mesh._rest)[p.dx,p.dy]],
    'weights':[for(final ws in mesh._weights)[for(final w in ws)[w.bone.index,w.weight]]],
    'sections':[for(final s in mesh._sections){'original':s.original.toList(),'reconstructed':s.reconstructed.toList(),'shield':s.shield}],
    'outlines':{
      'head':outline(GoliathMotionModel.headOutline),
      'chest':outline(GoliathMotionModel.chestOutline),
      'pelvis':outline(GoliathMotionModel.apronOutline),
      'leftShin':outline(GoliathMotionModel.leftShinOutline),
      'rightShin':outline(GoliathMotionModel.rightShinOutline),
      'leftFoot':outline(GoliathMotionModel.footOutlines[GoliathJoint.leftAnkle]!),
      'rightFoot':outline(GoliathMotionModel.footOutlines[GoliathJoint.rightAnkle]!),
      'leftHand':outline(GoliathMotionModel.palmOutline),
      'leftForearm':outline(GoliathMotionModel.leftForearmOutline),
      'rightForearm':outline(GoliathMotionModel.shieldOutline),
    }
  };
  File(args[0]).writeAsStringSync(jsonEncode(data));
  print('Exported ${mesh.vertexCount} original vertices and ${mesh.triangleCount} original triangles');
}
'''
(OUT/'native_mesh_export.dart').write_text(source+stubs)
subprocess.run(['/opt/homebrew/bin/dart',str(OUT/'native_mesh_export.dart'),str(OUT/'native-rig.json')],check=True,cwd=ROOT)
