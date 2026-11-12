// Conservative continuous bounds of a native actor's pre-queue ground route.
// No mesh edits or fixed-point sampling are used as a clearance proof.
const point=value=>({x:value.x,y:0,z:value.z});
const lerp=(a,b,t)=>({x:a.x+(b.x-a.x)*t,y:0,z:a.z+(b.z-a.z)*t});
function split(points,t=.5) {
  let row=points.map(point);const left=[row[0]],right=[row.at(-1)];
  while(row.length>1){row=row.slice(1).map((value,i)=>lerp(row[i],value,t));left.push(row[0]);right.unshift(row.at(-1));}
  return[left,right];
}
function derivative(points){const degree=points.length-1;return points.slice(1).map((value,i)=>({x:degree*(value.x-points[i].x),y:0,z:degree*(value.z-points[i].z)}));}

export function waitingPrefixBounds(path,gate,animal,{maxExtra=.15,maxDepth=14}={}) {
  if(!Number.isFinite(gate)||gate<0||gate>=path.approachLength)throw new Error('A waiting prefix must end before the stairs.');
  const rear=animal.body_rear_units+.06,front=animal.body_length_units-animal.body_rear_units+.06,width=animal.body_width_units/2+.06;
  const radius=Math.hypot(Math.max(rear,front),width),boxes=[];
  function bound(points,depth=0) {
    const [left,right]=split(points),center=left.at(-1),first=derivative(points),tangent=split(first)[0].at(-1);
    const norm=Math.hypot(tangent.x,tangent.z);
    if(norm<1e-12)throw new Error('The waiting prefix has no forward tangent.');
    const forward={x:tangent.x/norm,z:tangent.z/norm},side={x:forward.z,z:-forward.x};
    const projections=first.map(value=>value.x*forward.x+value.z*forward.z);
    let extra=Infinity;
    if(Math.min(...projections)>1e-12) {
      const angle=Math.max(...first.map(value=>Math.atan2(Math.abs(value.x*forward.z-value.z*forward.x),value.x*forward.x+value.z*forward.z)));
      const displacement=Math.max(...points.map(value=>Math.hypot(value.x-center.x,value.z-center.z)));
      extra=displacement+2*radius*Math.sin(angle/2);
    }
    if(extra>maxExtra) {
      if(depth>=maxDepth)throw new Error('A waiting prefix could not be bounded continuously.');
      bound(left,depth+1);bound(right,depth+1);return;
    }
    const corners=[-rear-extra,front+extra].flatMap(length=>[-width-extra,width+extra].map(at=>({
      x:center.x+forward.x*length+side.x*at,z:center.z+forward.z*length+side.z*at,
    })));
    boxes.push({minX:Math.min(...corners.map(value=>value.x)),maxX:Math.max(...corners.map(value=>value.x)),
      minZ:Math.min(...corners.map(value=>value.z)),maxZ:Math.max(...corners.map(value=>value.z))});
  }
  if(gate===0) {
    const frame=path.sample(0),heading=frame.heading,forward={x:Math.sin(heading),z:Math.cos(heading)},side={x:forward.z,z:-forward.x};
    const corners=[-rear,front].flatMap(length=>[-width,width].map(at=>({x:frame.position.x+forward.x*length+side.x*at,z:frame.position.z+forward.z*length+side.z*at})));
    return[{minX:Math.min(...corners.map(value=>value.x)),maxX:Math.max(...corners.map(value=>value.x)),minZ:Math.min(...corners.map(value=>value.z)),maxZ:Math.max(...corners.map(value=>value.z))}];
  }
  for(const curve of path.curves) {
    if(gate<=curve.start)break;
    if(gate>=curve.start+curve.length){bound(curve.points);continue;}
    const local=gate-curve.start;
    let low=0,high=curve.table.length-1;
    while(high-low>1){const mid=(low+high)>>1;if(curve.table[mid].distance<=local)low=mid;else high=mid;}
    const a=curve.table[low],b=curve.table[high],t=a.t+(b.t-a.t)*(local-a.distance)/(b.distance-a.distance);
    bound(split(curve.points,t)[0]);
  }
  return boxes;
}
