// Author gameplay/manifest JSON from actual saved GLBs. Never edits a model,
// calls Blender, starts a service, or installs the app.
import assert from 'node:assert/strict';
import {readFile,writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {loadNativeAsset,prepareNativeClip,THREE} from './check_native_asset.mjs';
import {selectAnimalGaits,validateAnimalGaitDurations,animalPreviewHeight,animalPreviewSpeed,animalFlightClearance} from './animal_preview_config.mjs';
import {gardenSpeciesProfile,measureNativeStancePace} from './garden_species.mjs';
import {measureGaitEnvelope} from './gait_envelope.mjs';
import {gardenLayout,planGardenApproach,interiorEndpoint,certifyGardenCurves} from './garden_routes.mjs';
import {AnimalLocomotionPath} from './animal_locomotion.mjs';
import {waitingPrefixBounds} from './garden_waiting_zones.mjs';
import {gardenAnimalIds,gardenAnimalPath,toCoursePoint,validateGardenCourse} from './garden_contract.mjs';
import {GardenTraffic} from './garden_traffic.mjs';

const sha=async filename=>createHash('sha256').update(await readFile(new URL(`./assets/${filename}`,import.meta.url))).digest('hex');
const scatteredSlots={rabbit:[-82,18],elephant:[-63,18.9],lion:[-45,19.2],deer:[-27,18.3],
  sheep:[-10,18.6],dove:[8,18.7],giraffe:[26,18.3],camel:[45,18.7],donkey:[62,19.2],zebra:[80,18.6]};
const starts=Object.fromEntries(Object.entries(scatteredSlots).map(([id,[degrees,radius]])=>{
  const angle=degrees*Math.PI/180;return[id,[radius*Math.sin(angle),9.5+radius*Math.cos(angle)]];
}));
const layout={...gardenLayout,bounds:{minX:-23,maxX:23,minZ:3.5,maxZ:30}};
// Slow native gaits begin nearer the Ark. Faster species remain scattered
// across the wider garden; no gait rate or approved single-animal review changes.
const nearbyStarts={elephant:{x:-5,z:12,heading:1.068},lion:{x:5,z:13.5,heading:-1.068},
  giraffe:{x:-9,z:15,heading:1.068}};
const routeFootprint=animal=>({width:animal.body_width_units,
  length:2*Math.max(animal.body_rear_units,animal.body_length_units-animal.body_rear_units)});
const curvatureLimit=(animal,profile)=>Math.min(profile.turn_curvature??.6/animal.body_width_units,
  1/Math.max(1.3,routeFootprint(animal).length*.35));
const native={};
const diagnostics=[];
const signatures={};
let cached;
try{cached=JSON.parse(await readFile(new URL('./garden_model_audit.json',import.meta.url)));}catch{}
for(const id of gardenAnimalIds) {
  const profile=gardenSpeciesProfile(id),assetHash=await sha(profile.asset);
  const signature=JSON.stringify({height:profile.height,maxWidth:profile.maxWidth,forwardYaw:profile.forwardYaw,
    walkName:profile.walkName,turnNames:profile.turnNames,expectedGaitDuration:profile.expectedGaitDuration,
    turnCurvature:profile.turnCurvature,sourceStanceSpeed:profile.sourceStanceSpeed,feet:profile.feet});
  signatures[id]=signature;
  if(cached?.signatures?.[id]===signature&&cached.native?.[id]?.asset_sha256===assetHash) {
    native[id]=cached.native[id];diagnostics.push(cached.diagnostics.find(value=>value.id===id));
    console.log(`${id}: native asset checks retained with identical export hash`);continue;
  }
  const asset=await loadNativeAsset(profile.asset,true);
  const removed=[];
  asset.scene.traverse(object=>{if(object.isCamera||object.isLight||object.name.replace(/[ _]/g,'').toLowerCase()==='animalreviewground')removed.push(object);});
  removed.forEach(object=>object.removeFromParent());
  let skinned=0;
  asset.scene.traverse(object=>{
    if(!object.isSkinnedMesh)return;skinned++;
    const weights=object.geometry.getAttribute('skinWeight'),joints=object.geometry.getAttribute('skinIndex');
    assert.ok(weights&&joints,'Native skinning is required.');
    for(let i=0;i<weights.count;i++) {
      const values=[weights.getX(i),weights.getY(i),weights.getZ(i),weights.getW(i)];
      assert.ok(values.every(value=>Number.isFinite(value)&&value>=0));
      assert.ok(Math.abs(values.reduce((sum,value)=>sum+value,0)-1)<1e-5,'Native weights must be normalized.');
      assert.ok([joints.getX(i),joints.getY(i),joints.getZ(i),joints.getW(i)].every(joint=>Number.isInteger(joint)&&joint>=0&&joint<object.skeleton.bones.length));
    }
  });
  assert.ok(skinned,'A real skinned native body is required.');
  const gaits=Object.fromEntries(Object.entries(selectAnimalGaits(asset.animations,profile)).map(([key,clip])=>[key,prepareNativeClip(clip)]));
  assert.ok(gaits.walk&&gaits.left&&gaits.right,`${id} needs all three native gait clips.`);
  validateAnimalGaitDurations(gaits,profile);
  const loops={};
  for(const [key,clip] of Object.entries(gaits)) {
    let error=0;
    for(const track of clip.tracks) {
      const count=track.getValueSize(),first=Array.from(track.values.slice(0,count)),last=Array.from(track.values.slice(-count));
      const direct=Math.max(...first.map((v,i)=>Math.abs(v-last[i]))),reverse=Math.max(...first.map((v,i)=>Math.abs(v+last[i])));
      error=Math.max(error,track.name.endsWith('quaternion')?Math.min(direct,reverse):direct);
    }
    assert.ok(error<1e-5,`${id} ${key} native loop must close.`);loops[key]={name:clip.name,duration:clip.duration,loopError:error};
  }
  const mixer=new THREE.AnimationMixer(asset.scene);
  const actions=Object.fromEntries(Object.entries(gaits).map(([key,clip])=>[key,mixer.clipAction(clip)]));
  actions.walk.reset().play();mixer.update(0);asset.scene.updateMatrixWorld(true);
  asset.scene.traverse(object=>{if(object.isSkinnedMesh){object.skeleton.update();object.computeBoundingBox();object.computeBoundingSphere();}});
  const standingBounds=new THREE.Box3().setFromObject(asset.scene),size=standingBounds.getSize(new THREE.Vector3());
  const height=animalPreviewHeight(profile,size),factor=height/size.y;
  const envelope=measureGaitEnvelope({THREE,asset:asset.scene,mixer,gaits,actions,standingBounds,factor});
  const flight=animalFlightClearance(profile,envelope);
  const calibration=profile.feet?measureNativeStancePace({THREE,asset:asset.scene,mixer,walk:actions.walk,feet:profile.feet}):undefined;
  const speed=calibration?calibration.sourceSpeed*factor:animalPreviewSpeed(profile,factor);
  const endpoint=interiorEndpoint(envelope.straight);
  assert.ok(envelope.width+.16<2.144,'The actual open left leaf and right door need horizontal clearance.');
  assert.ok(envelope.straight.maxY+(profile.flightAltitude??0)<3.9-.08,'The actual door lintel begins3.9m above the route deck.');
  native[id]={asset:profile.asset,asset_sha256:assetHash,height_units:height,normalization_factor:factor,
    dimensions:size.clone().multiplyScalar(factor).toArray(),speed_units_per_second:speed,gait_envelope:envelope,
    clips:Object.fromEntries(Object.entries(gaits).map(([key,clip])=>[key,clip.name])),gait_duration:gaits.walk.duration,
    ...(profile.turnCurvature?{turn_curvature:profile.turnCurvature}:{}),forward_yaw:profile.forwardYaw,
    ...(profile.flightAltitude?{flight_altitude:profile.flightAltitude}:{}),calibration,flight_clearance:flight};
  diagnostics.push({id,loops,dimensions:native[id].dimensions,endpoint,speed,calibration});
  console.log(`${id}: native gait, loop, skinning and doorway checks pass`);
}
await writeFile(new URL('./garden_model_audit.json',import.meta.url),JSON.stringify({version:2,
  scope:'native export diagnostics only; garden placement and traffic not yet activated',native,diagnostics,signatures},null,2)+'\n');

const records=gardenAnimalIds.map(id=>{
  const [x,z]=starts[id],near=nearbyStarts[id];
  const start={x:near?.x??x,y:0,z:near?.z??z},heading=near?.heading??Math.atan2(-x,9.5-z);
  const envelope=native[id].gait_envelope;
  const body={body_width_units:envelope.width,body_length_units:envelope.length,body_rear_units:-envelope.straight.minZ};
  const idleCurve=Array.from({length:6},(_,i)=>({x:start.x+Math.sin(heading)*i/5,y:0,z:start.z+Math.cos(heading)*i/5}));
  const idlePath=new AnimalLocomotionPath({curves:[idleCurve],tail:[{x:0,y:.33,z:9}]});
  return{id,start,heading,native:native[id],body,idleBounds:waitingPrefixBounds(idlePath,0,body)};
});
const animals=records.map(record=>{
  const blocked=records.filter(other=>other!==record).flatMap(other=>other.idleBounds);
  console.log(`${record.id}: certifying scattered start and actual idle body bounds`);
  const planned=planGardenApproach({start:record.start,heading:record.heading,footprint:routeFootprint(record.body),
    turnCurvature:record.native.turn_curvature,layout:{...layout,rails:[...layout.rails,...blocked]}});
  const end=planned.curves.at(-1).at(-1);
  const route=[record.start,end];
  for(let step=0;step<13;step++)route.push({x:0,y:(step+1)*.33,z:9-step*.5});
  route.push({x:0,y:4.3,z:2.75},{x:0,y:4.3,z:2.5},{x:0,y:4.3,z:interiorEndpoint(record.native.gait_envelope.straight)});
  diagnostics.find(value=>value.id===record.id).routeClearance=planned.clearance;
  record.curves=planned.curves;
  const animal={id:record.id,species:record.id,label:gardenSpeciesProfile(record.id).label,
    speed_units_per_second:record.native.speed_units_per_second,...record.body,queue_gate_distance_units:0,
    route:route.map((point,index)=>({...toCoursePoint(point),phase:index<2?'garden':index===route.length-1?'interior':index===route.length-2?'door':'stairs'})),
    approach_curves:planned.curves.map(curve=>curve.map(toCoursePoint))};
  record.animal=animal;record.path=gardenAnimalPath(animal);
  return animal;
});
const waitingProofs={};
for(const record of records) {
  const animal=record.animal;
  const limit=record.path.approachLength-(animal.body_length_units-animal.body_rear_units)-.06;
  // Park on a closed native gait phase. Other actors may stop anywhere in
  // the prefix, so certify every full owner route against the whole prefix,
  // rather than testing only its endpoint or accepting a sampled gap.
  const stride=record.native.gait_duration*animal.speed_units_per_second;
  let best=0,bestBounds;
  const certifyPrefix=gate=>{
    const boxes=waitingPrefixBounds(record.path,gate,animal);
    for(const other of records.filter(value=>value!==record)) {
      if(!certifyGardenCurves(other.curves,routeFootprint(other.animal),curvatureLimit(other.animal,other.native),
        {...layout,rails:[...layout.rails,...boxes]}))return undefined;
    }
    return boxes;
  };
  bestBounds=certifyPrefix(0);
  assert.ok(bestBounds,`${record.id}: every owner needs a clear route around untapped animals.`);
  for(let cycle=1;cycle*stride<=limit;cycle++) {
    const candidate=cycle*stride,boxes=certifyPrefix(candidate);
    if(!boxes)break;
    best=candidate;bestBounds=boxes;
  }
  animal.queue_gate_distance_units=best;
  waitingProofs[record.id]={gate_distance_units:best,continuous_prefix_boxes:bestBounds.length,
    owner_routes_certified:records.filter(other=>other!==record).map(other=>other.id)};
  console.log(`${record.id}: parallel prefix${best.toFixed(3)}m continuously clear for all other owner routes`);
}
const individualMax=Math.max(...animals.map(animal=>gardenAnimalPath(animal).length/animal.speed_units_per_second));
const replays={};
for(const [name,taps] of Object.entries({
  together:Object.fromEntries(animals.map(animal=>[animal.id,0])),
  reverse:Object.fromEntries([...animals].reverse().map((animal,index)=>[animal.id,index*2])),
  staggered:Object.fromEntries(animals.map((animal,index)=>[animal.id,index*20])),
})) {
  const traffic=new GardenTraffic(animals);let snapshot;
  for(let tick=1;tick<=5700;tick++) {snapshot=traffic.advanceTo(tick,taps);if(snapshot.completed)break;}
  if(!snapshot.completed) {
    console.error(JSON.stringify({replay:name,blocked:traffic.states.filter(state=>state.arrival===undefined).map(state=>({id:state.animal.id,distance:state.distance,gate:state.gate,position:state.frame.position})),owner:snapshot.corridorOwner},null,2));
    throw new Error('The authored garden traffic layout deadlocks or leaves no timer cushion within ten minutes. No course is written.');
  }
  replays[name]={taps,arrivals:snapshot.arrivals,completed_tick:snapshot.tick};
}
const limit=Math.max(3597,...Object.values(replays).map(replay=>replay.completed_tick+300),Math.ceil(individualMax*10)+300);
const config={mode:'ark_garden',garden:{version:2,tick_ms:100,time_limit_ticks:limit,
  world:{width:46,height:33.5},projection:{ground_y_scale:.45,elevation_y_scale:.8},animals}};
validateGardenCourse(config);
const manifest={version:2,scope:'actual native review exports; visual review still required',
  ark_sha256:await sha('ark-review.glb'),noah_sha256:await sha('noah-review.glb'),animals:native,
  scene_alignment:{ark_width:18,door_clear_width:2.144,door_top_above_deck:3.9,deck_height:4.3,stair_rise:.33,stair_run:.5,treads:13},
  proof:{route:'adaptive continuous rigid-envelope certificate including actual idle bodies and every possible pre-queue waiting pose',
    envelope:'49phase samples×7native gait/blend weights,6cmguard; notcontinuousskinningproof',
    traffic:{waiting_areas:'continuous native-body envelope bounds along every entire pre-queue prefix; all other owner routes independently certified clear',waitingProofs,replays},diagnostics}};
await writeFile(new URL('./garden_course_v2.json',import.meta.url),JSON.stringify(config,null,2)+'\n');
await writeFile(new URL('./garden_native_assets.json',import.meta.url),JSON.stringify(manifest,null,2)+'\n');
console.log(`Ten native animals ready; deterministic boarding replays pass, timer${limit}.`);
