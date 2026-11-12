import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { gardenAnimalIds, toCoursePoint, fromCoursePoint, gardenAnimalPath, gardenPoseAt, rendererClockTick, gardenRenderDistance, clampGardenPan, validateGardenCourse, nativeGardenAnimal } from './garden_contract.mjs';
import { sha256Fallback } from './garden_asset_integrity.mjs';

const route = [
  {x:4,y:0,z:12},{x:0,y:0,z:9.5},{x:0,y:.33,z:9},{x:0,y:4.3,z:2.5},{x:0,y:4.3,z:1},
].map(toCoursePoint);
const curves = [[{x:4,y:0,z:12},{x:3,y:0,z:13},{x:0,y:0,z:13},{x:0,y:0,z:9.5}].map(toCoursePoint)];
const animal = id=>({id,species:id,label:id,speed_units_per_second:1,body_width_units:1,body_length_units:2,body_rear_units:1,queue_gate_distance_units:0,route,approach_curves:curves});
const course = ()=>({mode:'ark_garden',garden:{version:2,tick_ms:100,time_limit_ticks:2400,world:{width:46,height:33.5},animals:gardenAnimalIds.map(animal)}});

test('native coordinate translation preserves the authored Ark doorway and stair height',()=>{
  const point={x:0,y:4.3,z:2.5};
  assert.deepEqual(toCoursePoint(point),{x:23,y:6,z:4.3});
  assert.deepEqual(fromCoursePoint(toCoursePoint(point)),point);
});

test('ten distinct animals and full curves are required before a garden can start',()=>{
  assert.equal(validateGardenCourse(course()).garden.animals.length,10);
  const missing=course();missing.garden.animals.pop();assert.throws(()=>validateGardenCourse(missing),/ten-animal/);
  const duplicate=course();duplicate.garden.animals[9]=duplicate.garden.animals[0];assert.throws(()=>validateGardenCourse(duplicate),/distinct/);
  const mismatch=course();mismatch.garden.animals[0]={...mismatch.garden.animals[0],route:route.map((point,i)=>i===1?{...point,x:24}:point)};
  assert.throws(()=>validateGardenCourse(mismatch),/share their endpoints/);
  const impossible=course();impossible.garden.time_limit_ticks=100;assert.throws(()=>validateGardenCourse(impossible),/before the configured timer/);
});

test('queued authoritative distance freezes the native gait and completion requires full entry',()=>{
  const a=animal('elephant'),path=gardenAnimalPath(a);
  const paused=gardenPoseAt(a,path,0,300,2);
  const later=gardenPoseAt(a,path,0,500,2);
  assert.deepEqual(paused.position,later.position);
  assert.equal(paused.animationSeconds,later.animationSeconds);
  assert.equal(later.arrived,false);
  assert.equal(gardenPoseAt(a,path,undefined,500,path.length).arrived,false);
  assert.equal(gardenPoseAt(a,path,0,500,path.length-.001).arrived,false);
  assert.equal(gardenPoseAt(a,path,0,500,path.length).arrived,true);
});

test('host prediction is bounded and pause/background state cannot advance time',()=>{
  assert.equal(rendererClockTick({tick:10},.05),10.5);
  assert.equal(rendererClockTick({tick:10},60),11);
  assert.equal(rendererClockTick({tick:10,paused:true},60),10);
  assert.equal(rendererClockTick({tick:10,finished:true},60),10);
  assert.equal(clampGardenPan(50,20),15);
  assert.equal(clampGardenPan(-50,20),-15);
  assert.equal(clampGardenPan(10,40),0);
});

test('the final distance settles over100ms and pauses preserve the current visible pose',()=>{
  const a=animal('elephant'),path=gardenAnimalPath(a),before=path.length-.1;
  assert.equal(gardenRenderDistance(before,path.length,0,false),before);
  assert.equal(gardenPoseAt(a,path,0,500,gardenRenderDistance(before,path.length,.05,false)).arrived,false);
  assert.equal(gardenPoseAt(a,path,0,500,gardenRenderDistance(before,path.length,.1,false)).arrived,true);
  assert.equal(gardenRenderDistance(before,path.length,5,true),before);
});

test('course movement calibration must agree with the checked native model manifest',()=>{
  const a=animal('elephant');
  const native={asset:'elephant-review.glb',asset_sha256:'a'.repeat(64),height_units:3.3,normalization_factor:.3,
    speed_units_per_second:1,gait_envelope:{width:1,length:2,straight:{minZ:-1}},clips:{walk:'Walk',left:'Left',right:'Right'}};
  assert.equal(nativeGardenAnimal(a,{animals:{elephant:native}}).asset,'elephant-review.glb');
  assert.throws(()=>nativeGardenAnimal({...a,speed_units_per_second:2},{animals:{elephant:native}}),/checked native export/);
  assert.throws(()=>nativeGardenAnimal({...a,body_width_units:.9},{animals:{elephant:native}}),/checked native export/);
});

test('LAN-safe asset integrity matches SHA-256 for vectors and binary data across padding boundaries',()=>{
  for(const input of ['', 'abc', 'a'.repeat(55), 'a'.repeat(56), 'a'.repeat(64), 'a'.repeat(1000)]) {
    const bytes=new TextEncoder().encode(input);
    assert.equal(sha256Fallback(bytes),createHash('sha256').update(bytes).digest('hex'));
  }
  const bytes=new Uint8Array(8193);for(let i=0;i<bytes.length;i++)bytes[i]=(i*37)%256;
  assert.equal(sha256Fallback(bytes),createHash('sha256').update(bytes).digest('hex'));
});
