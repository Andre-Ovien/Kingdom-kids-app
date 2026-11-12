import { gardenAnimalPath } from './garden_contract.mjs';

const gap = .06, step = .05, epsilon = 1e-9;
function rectangle(frame, animal) {
  const forward = {x:Math.sin(frame.heading),z:Math.cos(frame.heading)};
  const side = {x:forward.z,z:-forward.x};
  const rear = animal.body_rear_units ?? animal.body_length_units/2;
  const front = animal.body_length_units-rear;
  const width = animal.body_width_units/2+gap;
  const corners = [-rear-gap,front+gap].flatMap(length=>[-width,width].map(at=>({
    x:frame.position.x+forward.x*length+side.x*at,
    z:frame.position.z+forward.z*length+side.z*at,
  })));
  return {axes:[forward,side],corners};
}
function overlaps(a,b) {
  return [...a.axes,...b.axes].every(axis=>{
    const first=a.corners.map(point=>point.x*axis.x+point.z*axis.z);
    const second=b.corners.map(point=>point.x*axis.x+point.z*axis.z);
    return Math.max(...first)>Math.min(...second)+epsilon && Math.max(...second)>Math.min(...first)+epsilon;
  });
}

/** Same ordered OBB/5cm movement rule as the native and server v2 replay. */
export class GardenTraffic {
  constructor(animals) {
    this.tick=0;this.owner=undefined;
    this.states=animals.map((animal,order)=>{
      const path=gardenAnimalPath(animal),rear=animal.body_rear_units ?? animal.body_length_units/2;
      return {animal,order,path,distance:0,arrival:undefined,tap:undefined,
        gate:animal.queue_gate_distance_units ?? Math.max(0,path.approachLength-(animal.body_length_units-rear)-gap),frame:path.sample(0)};
    });
  }
  advanceTo(target,taps={}) {
    if(!Number.isInteger(target)||target<this.tick)throw new Error('A traffic replay needs increasing whole ticks.');
    for(const state of this.states)if(Object.hasOwn(taps,state.animal.id)) {
      const tap=taps[state.animal.id];
      if(!Number.isSafeInteger(tap)||tap<0 || state.tap!==undefined && state.tap!==tap)throw new Error('An animal’s first tap cannot be changed.');
      state.tap=tap;
    }
    const priority=[...this.states].sort((a,b)=>(a.tap??target+1)-(b.tap??target+1)||a.order-b.order);
    while(this.tick<target) {
      this.tick++;
      if(this.owner?.arrival!==undefined)this.owner=undefined;
      const rectangles=new Map(this.states.filter(state=>state.arrival===undefined).map(state=>[state.animal.id,rectangle(state.frame,state.animal)]));
      for(const state of priority) {
        if(state.tap===undefined||state.tap>=this.tick||state.arrival!==undefined)continue;
        let desired=Math.min(state.path.length,state.distance+state.animal.speed_units_per_second*.1);
        if(this.owner&&this.owner!==state)desired=Math.min(desired,state.gate);
        while(desired-state.distance>epsilon) {
          const next=Math.min(desired,state.distance+step),frame=state.path.sample(next),shape=rectangle(frame,state.animal);
          if([...rectangles].some(([id,other])=>id!==state.animal.id&&overlaps(shape,other)))break;
          if(next>state.gate+epsilon) {
            if(this.owner&&this.owner!==state)break;
            this.owner=state;
          }
          state.distance=next;state.frame=frame;rectangles.set(state.animal.id,shape);
        }
        if(state.distance+epsilon>=state.path.length) {
          state.distance=state.path.length;state.frame=state.path.sample(state.path.length);state.arrival=this.tick;
          rectangles.delete(state.animal.id);
          if(this.owner===state)this.owner=undefined;
        }
      }
    }
    return this.snapshot();
  }
  snapshot() {
    return {tick:this.tick,
      distances:Object.fromEntries(this.states.map(state=>[state.animal.id,state.distance])),
      arrivals:Object.fromEntries(this.states.filter(state=>state.arrival!==undefined).map(state=>[state.animal.id,state.arrival])),
      completed:this.states.every(state=>state.arrival!==undefined),
      corridorOwner:this.owner?.animal.id};
  }
}
