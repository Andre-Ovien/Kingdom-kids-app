import test from 'node:test';
import assert from 'node:assert/strict';
import {GardenTraffic} from './garden_traffic.mjs';
import {toCoursePoint} from './garden_contract.mjs';

function animal(id,x) {
  const curves=[[{x,y:0,z:12},{x:x*.8,y:0,z:13},{x:0,y:0,z:12.5},{x:0,y:0,z:9.5}]];
  return{id,species:id,speed_units_per_second:1,body_width_units:.8,body_length_units:1.8,body_rear_units:.9,
    queue_gate_distance_units:1,approach_curves:curves.map(curve=>curve.map(toCoursePoint)),
    route:[curves[0][0],curves[0].at(-1),{x:0,y:.33,z:9},{x:0,y:4.3,z:2.5},{x:0,y:4.3,z:1}].map(toCoursePoint)};
}

test('tapped animals wait before the shared corridor and enter only after the prior tail is inside',()=>{
  const traffic=new GardenTraffic([animal('first',-4),animal('second',4)]),taps={first:0,second:0};
  let firstArrival;
  for(let tick=1;tick<1000;tick++) {
    const at=traffic.advanceTo(tick,taps);
    if(at.arrivals.first!==undefined&&firstArrival===undefined)firstArrival=tick;
    if(firstArrival===undefined)assert.ok(at.distances.second<=1+1e-9);
    if(at.completed)break;
  }
  const at=traffic.snapshot();
  assert.equal(at.completed,true);assert.ok(at.arrivals.second>at.arrivals.first);
  assert.equal(at.corridorOwner,undefined);
});

test('future taps do not move an animal, and replay ordering follows the first accepted tap',()=>{
  const traffic=new GardenTraffic([animal('first',-4),animal('second',4)]);
  const at=traffic.advanceTo(20,{first:100,second:0});
  assert.equal(at.distances.first,0);assert.ok(at.distances.second>1);
  const done=traffic.advanceTo(1000,{first:100,second:0});
  assert.equal(done.completed,true);assert.ok(done.arrivals.second<done.arrivals.first);
  assert.throws(()=>traffic.advanceTo(1001,{first:101,second:0}),/first tap cannot be changed/);
});

test('a paused tick freezes both queued and moving animals without resetting progress',()=>{
  const traffic=new GardenTraffic([animal('first',-4),animal('second',4)]);
  const before=traffic.advanceTo(25,{first:0,second:0});
  assert.deepEqual(traffic.advanceTo(25,{first:0,second:0}),before);
  assert.ok(traffic.advanceTo(26,{first:0,second:0}).distances.first>before.distances.first);
});
