import { animalPreviewProfile } from './animal_preview_config.mjs';

// New garden species do not alter the approved single-animal reference loader.
const additional = {
  lion: {id:'lion',label:'Lion',asset:'lion-review.glb',height:1.3,maxWidth:2.5,forwardYaw:0,
    walkName:'LionWalk',turnNames:{left:'LionTurnLeft',right:'LionTurnRight'},expectedGaitDuration:100/30,
    turnCurvature:.45,feet:['Horse_L_Finger0','Horse_R_Finger0','Horse_L_Toe0','Horse_R_Toe0']},
  camel: {id:'camel',label:'Camel',asset:'camel-review.glb',height:2.3,maxWidth:2.5,forwardYaw:0,
    walkName:'CamelWalk',turnNames:{left:'CamelTurnLeft',right:'CamelTurnRight'},expectedGaitDuration:40/30,
    turnCurvature:.4,feet:['Camelus_Hoof_L','Camelus_Hoof_R','Camelus_Hoof_back_L','Camelus_Hoof_back_R']},
  giraffe: {id:'giraffe',label:'Giraffe',asset:'giraffe-review.glb',height:3.3,maxWidth:2.5,forwardYaw:0,
    walkName:'GiraffeWalk',turnNames:{left:'GiraffeTurnLeft',right:'GiraffeTurnRight'},expectedGaitDuration:100/30,
    turnCurvature:.35,feet:['left_f_foot','right_f_foot','left_r_foot','right_r_foot']},
};

export function gardenSpeciesProfile(id) {
  if(Object.hasOwn(additional,id))return additional[id];
  const profile=animalPreviewProfile(id);
  if(profile.id!==id)throw new Error('Choose one of the ten actual garden species.');
  return profile;
}

/** Average median backwards stance velocity for each species' own low feet.
 * This calibrates root travel approximately; it is not a foot-plant solver.
 */
export function measureNativeStancePace({THREE,asset,mixer,walk,feet,samples=240}) {
  if(!feet?.length)throw new Error('A new species needs its own named foot joints for pace calibration.');
  const records=feet.map(name=>({name,bone:asset.getObjectByName(name),points:[]}));
  if(records.some(record=>!record.bone))throw new Error('The native gait is missing a named foot joint.');
  mixer.stopAllAction();walk.reset().setEffectiveWeight(1).setEffectiveTimeScale(1).play();
  const duration=walk.getClip().duration;
  for(let phase=0;phase<=samples;phase++) {
    walk.time=Math.min(duration-1e-7,phase/samples*duration);mixer.update(0);asset.updateMatrixWorld(true);
    records.forEach(record=>record.points.push(record.bone.getWorldPosition(new THREE.Vector3())));
  }
  const evidence=records.map(record=>{
    const y=record.points.map(point=>point.y),z=record.points.map(point=>point.z);
    const floor=Math.min(...y),rise=Math.max(...y)-floor;
    const speeds=record.points.slice(1).flatMap((point,index)=>{
      const previous=record.points[index],speed=-(point.z-previous.z)/(duration/samples);
      return point.y<=floor+rise*.2 && previous.y<=floor+rise*.2 && speed>0 ? [speed] : [];
    }).sort((a,b)=>a-b);
    if(speeds.length<8)throw new Error('The native gait has insufficient low, backwards-moving stance samples.');
    return {name:record.name,minY:floor,yRange:rise,zSpan:Math.max(...z)-Math.min(...z),stanceSpeed:speeds[Math.floor(speeds.length/2)],stanceSamples:speeds.length};
  });
  walk.reset().play();mixer.update(0);asset.updateMatrixWorld(true);
  return {sourceSpeed:evidence.reduce((sum,foot)=>sum+foot.stanceSpeed,0)/evidence.length,
    evidence,basis:'mean of per-foot median backward velocities while within bottom20% native height range; approximate stance calibration',samples};
}
