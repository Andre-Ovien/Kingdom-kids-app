import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import '../../Frontend/mobile/lib/features/games/presentation/goliath_motion_model.dart';

double wrap(double v) => math.atan2(math.sin(v), math.cos(v));
double length(GoliathPoint a, GoliathPoint b) => math.sqrt(math.pow((a.x-b.x)*.75,2)+math.pow(a.y-b.y,2));
void main() {
  final results=<Map<String,Object>>[];
  final bonePairs=[
    (GoliathJoint.neck,GoliathJoint.head),(GoliathJoint.head,GoliathJoint.forehead),
    (GoliathJoint.chest,GoliathJoint.neck),(GoliathJoint.chest,GoliathJoint.lumbar),(GoliathJoint.lumbar,GoliathJoint.pelvis),
    (GoliathJoint.leftShoulder,GoliathJoint.leftElbow),(GoliathJoint.leftElbow,GoliathJoint.leftWrist),
    (GoliathJoint.rightShoulder,GoliathJoint.rightElbow),(GoliathJoint.rightElbow,GoliathJoint.rightWrist),
    (GoliathJoint.leftHip,GoliathJoint.leftKnee),(GoliathJoint.leftKnee,GoliathJoint.leftAnkle),
    (GoliathJoint.rightHip,GoliathJoint.rightKnee),(GoliathJoint.rightKnee,GoliathJoint.rightAnkle),
    (GoliathJoint.leftAnkle,GoliathJoint.leftToe),(GoliathJoint.rightAnkle,GoliathJoint.rightToe),
  ];
  for(final target in const [GoliathPoint(160,180),GoliathPoint(225,145),GoliathPoint(148,92),GoliathPoint(0,0)]) {
    final tx=target.x/320*390;
    final width=target.x==0 ? 1.0 : math.min(390*.78*.75,math.min((tx-8)/.451,(382-tx)/.549));
    final left=tx-width*.451;
    for(final direction in [-1.0,1.0]) for(final strength in [.6,1.0,1.4]) {
      final model=target.x==0 ? GoliathMotionModel(idleMotion:false) : GoliathMotionModel(minimumX:(8-left)/width,maximumX:(382-left)/width,idleMotion:false);
      model.strikeHead(direction:direction,strength:strength);
      double maxLengthError=0,maxHipAngle=0,maxFloorError=0,maxStep=0;
      int outside=0;bool supported=false;double headLead=0;
      var before=model.pose;
      for(var i=0;i<720&&!model.isSettled;i++) {
        final p=model.advance(1/120);
        for(final b in bonePairs) maxLengthError=math.max(maxLengthError,(length(p[b.$1],p[b.$2])-length(p.restJoints[b.$1]!,p.restJoints[b.$2]!)).abs());
        final pelvis=p.boneTransform(GoliathJoint.leftHip,GoliathJoint.rightHip).rotationRadians;
        for(final b in [(GoliathJoint.leftHip,GoliathJoint.leftKnee),(GoliathJoint.rightHip,GoliathJoint.rightKnee)]) maxHipAngle=math.max(maxHipAngle,wrap(p.boneTransform(b.$1,b.$2).rotationRadians-pelvis).abs());
        for(final j in GoliathJoint.values) {
          maxFloorError=math.max(maxFloorError,p[j].y+p.groundExtents[j]!-GoliathMotionModel.groundY);
          if(p[j].x<model.minimumX-1e-9||p[j].x>model.maximumX+1e-9) outside++;
          maxStep=math.max(maxStep,length(p[j],before[j]));
        }
        if(i==5) headLead=length(p[GoliathJoint.head],p.restJoints[GoliathJoint.head]!)/(length(p[GoliathJoint.pelvis],p.restJoints[GoliathJoint.pelvis]!)+1e-12);
        if(p.isGrounded&&!p.isSettled) supported=true;
        before=p;
      }
      results.add({'target':'${target.x},${target.y}','requested_direction':direction,'strength':strength,'settled':model.isSettled,'settled_seconds':model.pose.elapsedSeconds,'supported_before_settled':supported,'max_bone_error':maxLengthError,'max_hip_relative_angle':maxHipAngle,'max_floor_penetration':maxFloorError,'max_120hz_step':maxStep,'out_of_bounds_joint_samples':outside,'head_to_hip_travel_ratio_at_50ms':headLead});
    }
  }
  File('Motion/goliath-blender-fall-v1/native-motion-audit.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert(results));
  print('Runs ${results.length}; settled ${results.where((r)=>r['settled']==true).length}; max bone error ${results.map((r)=>r['max_bone_error'] as double).reduce(math.max)}; max floor error ${results.map((r)=>r['max_floor_penetration'] as double).reduce(math.max)}; out of bounds ${results.fold(0,(int s,r)=>s+(r['out_of_bounds_joint_samples'] as int))}');
}
