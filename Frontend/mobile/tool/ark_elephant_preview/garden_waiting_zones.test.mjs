import test from 'node:test';
import assert from 'node:assert/strict';
import {AnimalLocomotionPath} from './animal_locomotion.mjs';
import {certifyGardenCurves} from './garden_routes.mjs';
import {waitingPrefixBounds} from './garden_waiting_zones.mjs';

const p=(x,z)=>({x,y:0,z});
const line=(a,b)=>Array.from({length:6},(_,i)=>p(a.x+(b.x-a.x)*i/5,a.z+(b.z-a.z)*i/5));
const body={body_width_units:1,body_length_units:3,body_rear_units:1};
const path=curves=>new AnimalLocomotionPath({curves,tail:[{x:0,y:.33,z:9}]});
const layout={bounds:{minX:-20,maxX:20,minZ:0,maxZ:30},ark:{minX:15,maxX:16,minZ:1,maxZ:2},
  noah:{minX:17,maxX:18,minZ:1,maxZ:2},rails:[]};

test('asymmetric body prefix bounds contain every checked pose across a curved route',()=>{
  const route=path([[p(-10,20),p(-8,20),p(-6,20),p(-2,18),p(0,16),p(0,14)]]);
  const gate=route.approachLength*.7,boxes=waitingPrefixBounds(route,gate,body);
  for(let i=0;i<=300;i++) {
    const frame=route.sample(gate*i/300),f={x:Math.sin(frame.heading),z:Math.cos(frame.heading)},s={x:f.z,z:-f.x};
    const corners=[-body.body_rear_units-.06,body.body_length_units-body.body_rear_units+.06]
      .flatMap(length=>[-body.body_width_units/2-.06,body.body_width_units/2+.06]
        .map(side=>p(frame.position.x+f.x*length+s.x*side,frame.position.z+f.z*length+s.z*side)));
    assert.ok(boxes.some(box=>corners.every(c=>c.x>=box.minX-1e-8&&c.x<=box.maxX+1e-8&&c.z>=box.minZ-1e-8&&c.z<=box.maxZ+1e-8)));
  }
});

test('owner route rejects a later waiting prefix even when its idle position is safe',()=>{
  const waiter=path([line(p(-8,14),p(0,14))]);
  const owner=[line(p(-3,22),p(-3,8))],footprint={width:1,length:2};
  assert.ok(certifyGardenCurves(owner,footprint,.5,{...layout,rails:waitingPrefixBounds(waiter,0,body)}));
  assert.equal(certifyGardenCurves(owner,footprint,.5,{...layout,rails:waitingPrefixBounds(waiter,5,body)}),undefined);
});

test('a waiting bound never accepts a gate at or beyond the stair entry',()=>{
  const route=path([line(p(-8,14),p(0,14))]);
  assert.throws(()=>waitingPrefixBounds(route,route.approachLength,body),/before the stairs/);
  assert.throws(()=>waitingPrefixBounds(route,-1,body),/before the stairs/);
});
