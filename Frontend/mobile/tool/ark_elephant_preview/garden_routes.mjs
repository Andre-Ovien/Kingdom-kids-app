import { AnimalLocomotionPath, angleDelta } from './animal_locomotion.mjs?review=varied-starts-v1';

const p = (x, z) => ({ x, y: 0, z });
const gap = .08;
export const approvedApproach = Object.freeze([
  p(4, 12), p(3, 12.55), p(2, 13.10), p(0, 12.5), p(0, 11), p(0, 9.5),
].map(Object.freeze));
export const gardenLayout = Object.freeze({
  bounds: { minX: -14, maxX: 14, minZ: 3.5, maxZ: 25 },
  ark: { minX: -9.1, maxX: 9.1, minZ: -3.5, maxZ: 3.5 },
  // Actual normalized saved Noah, including staff, at (-2.7, 0, 9.3).
  noah: { minX: -3.35, maxX: -2.14, minZ: 9.02, maxZ: 9.58 },
  rails: [
    { minX: -1.7, maxX: -1.48, minZ: 2.6, maxZ: 9.05 },
    { minX: 1.48, maxX: 1.7, minZ: 2.6, maxZ: 9.05 },
  ],
});

export class GardenRouteError extends Error {
  constructor(message) { super(message); this.name = 'GardenRouteError'; }
}

export function interiorEndpoint(bodyLength, legacy = false) {
  if (typeof bodyLength === 'object' && bodyLength !== null) {
    const { minZ, maxZ } = bodyLength;
    if (![minZ, maxZ].every(Number.isFinite) || minZ >= maxZ) throw new GardenRouteError('The native straight gait needs valid longitudinal bounds.');
    // Facing -Z reverses the model's local bounds. Keep the entire sampled
    // walk behind the doorway, while retaining 8 cm before the inner face of
    // Ark_Cabin_Back (saved center -2.2, thickness .28).
    const endpoint = 2.25 + minZ;
    if (endpoint - maxZ < -2.06 + .08) throw new GardenRouteError('This animal’s straight gait cannot fit fully inside the reviewed cabin.');
    return endpoint;
  }
  if (!Number.isFinite(bodyLength) || bodyLength <= 0 || bodyLength > 4.2) throw new GardenRouteError('This animal cannot fit fully inside the reviewed cabin.');
  return legacy ? Math.min(-1, 2.5 - bodyLength - .25) : 2.5 - bodyLength / 2 - .25;
}

export function approachFixture(requested) {
  switch (requested) {
    case 'left': return { id: requested, start: p(-5, 14), heading: Math.atan2(1, .55) };
    case 'right': return { id: requested, start: p(5, 14), heading: Math.atan2(-1, .55) };
    case 'far-left': return { id: requested, start: p(-8, 16), heading: Math.atan2(1, .35) };
    case 'far-right': return { id: requested, start: p(8, 16), heading: Math.atan2(-1, .35) };
    case 'center': return { id: requested, start: p(0, 15), heading: Math.PI };
    case 'away': return { id: requested, start: p(0, 15), heading: 0 };
    case 'away-left': return { id: requested, start: p(-5, 15), heading: 0 };
    case 'away-right': return { id: requested, start: p(5, 15), heading: 0 };
    default: return { id: 'default', start: p(4, 12), heading: Math.atan2(-1, .55) };
  }
}

function rectangle(position, heading, footprint, extra = 0) {
  const side = { x: Math.cos(heading), z: -Math.sin(heading) };
  const forward = { x: Math.sin(heading), z: Math.cos(heading) };
  const halfWidth = footprint.width / 2 + gap + extra;
  const halfLength = footprint.length / 2 + gap + extra;
  return { position, side, forward, halfWidth, halfLength, corners: [-1, 1].flatMap(a => [-1, 1].map(b => ({
    x: position.x + a * side.x * halfWidth + b * forward.x * halfLength,
    z: position.z + a * side.z * halfWidth + b * forward.z * halfLength,
  }))) };
}

function overlapsBox(rect, box) {
  const other = [p(box.minX, box.minZ), p(box.minX, box.maxZ), p(box.maxX, box.minZ), p(box.maxX, box.maxZ)];
  return [rect.side, rect.forward, { x: 1, z: 0 }, { x: 0, z: 1 }].every(axis => {
    const a = rect.corners.map(value => value.x * axis.x + value.z * axis.z);
    const b = other.map(value => value.x * axis.x + value.z * axis.z);
    return Math.max(...a) >= Math.min(...b) && Math.max(...b) >= Math.min(...a);
  });
}

export function gardenPoseIsClear(position, heading, footprint, layout = gardenLayout, extra = 0) {
  if (!['width', 'length'].every(key => Number.isFinite(footprint[key]) && footprint[key] > 0) || !Number.isFinite(heading) || !['x', 'y', 'z'].every(key => Number.isFinite(position[key])) || position.y !== 0) return false;
  const rect = rectangle(position, heading, footprint, extra);
  if (rect.corners.some(value => value.x < layout.bounds.minX || value.x > layout.bounds.maxX || value.z < layout.bounds.minZ || value.z > layout.bounds.maxZ)) return false;
  if ([layout.ark, ...layout.rails].some(box => overlapsBox(rect, box))) return false;
  if (!Number.isFinite(layout.noah.radius)) return !overlapsBox(rect, layout.noah);
  const delta = { x: layout.noah.x - position.x, z: layout.noah.z - position.z };
  const side = Math.abs(delta.x * rect.side.x + delta.z * rect.side.z);
  const front = Math.abs(delta.x * rect.forward.x + delta.z * rect.forward.z);
  return Math.hypot(Math.max(0, side - rect.halfWidth), Math.max(0, front - rect.halfLength)) > layout.noah.radius;
}

function quintic(from, heading, to, endHeading, startHandle, endHandle) {
  const a = { x: Math.sin(heading), z: Math.cos(heading) };
  const b = { x: Math.sin(endHeading), z: Math.cos(endHeading) };
  return [from, p(from.x + a.x * startHandle, from.z + a.z * startHandle),
    p(from.x + a.x * startHandle * 2, from.z + a.z * startHandle * 2),
    p(to.x - b.x * endHandle * 2, to.z - b.z * endHandle * 2),
    p(to.x - b.x * endHandle, to.z - b.z * endHandle), to];
}

function freeTurn(from, heading, to, startHandle, endHandle, lateral) {
  const forward = { x: Math.sin(heading), z: Math.cos(heading) };
  // Seventh degree adds two independent lateral controls. The first/last
  // three collinear controls still give zero endpoint curvature. This allows
  // a center animal to walk outward and make a broad U-turn without a cusp.
  return [from,
    p(from.x + forward.x * startHandle, from.z + forward.z * startHandle),
    p(from.x + forward.x * startHandle * 2, from.z + forward.z * startHandle * 2),
    p(lateral, Math.min(24, from.z + 7)), p(lateral, Math.max(12, from.z - 2)),
    p(to.x, to.z + endHandle * 2), p(to.x, to.z + endHandle), to];
}

const midpoint = (a, b) => p((a.x + b.x) / 2, (a.z + b.z) / 2);
function split(points) {
  const left = [points[0]], right = [points.at(-1)];
  let row = points;
  while (row.length > 1) {
    row = row.slice(1).map((value, i) => midpoint(row[i], value));
    left.push(row[0]); right.unshift(row.at(-1));
  }
  return [left, right];
}
function derivative(points) {
  const n = points.length - 1;
  return points.slice(1).map((value, i) => p(n * (value.x - points[i].x), n * (value.z - points[i].z)));
}
function choose(n, k) {
  let value = 1;
  for (let i = 1; i <= k; i++) value = value * (n - i + 1) / i;
  return value;
}
function crossBounds(first, second) {
  const m = first.length - 1, n = second.length - 1;
  const coefficients = Array(m + n + 1).fill(0);
  for (let i = 0; i <= m; i++) for (let j = 0; j <= n; j++) {
    coefficients[i + j] += choose(m, i) * choose(n, j) / choose(m + n, i + j)
      * (first[i].z * second[j].x - first[i].x * second[j].z);
  }
  return Math.max(...coefficients.map(Math.abs));
}

/** Certifies the whole curve, relative to a supplied rigid body envelope.
 * A Bezier curve and its derivative stay within their control hulls. An
 * interval's center displacement plus bounded tangent rotation inflates a
 * reference rectangle to contain every body pose in that interval. Curvature
 * is bounded from the derivative/cross-product Bernstein hulls. Unresolved
 * intervals are rejected instead of accepted through a sampling gap.
 * This proves route-envelope clearance, not animated-mesh/terrain contact.
 */
export function certifyGardenCurves(curves, footprint, maxCurvature, layout = gardenLayout) {
  let intervals = 0;
  let maxBound = 0;
  const certify = (points, depth = 0) => {
    intervals++;
    const halves = split(points), center = halves[0].at(-1);
    const first = derivative(points), second = derivative(first);
    const tangent = split(first)[0].at(-1);
    const norm = Math.hypot(tangent.x, tangent.z);
    if (norm < 1e-12) return false;
    const forward = { x: tangent.x / norm, z: tangent.z / norm };
    const projections = first.map(value => value.x * forward.x + value.z * forward.z);
    const minSpeed = Math.min(...projections);
    const heading = Math.atan2(tangent.x, tangent.z);
    // An actual collision at the midpoint cannot be repaired by subdivision.
    if (!gardenPoseIsClear(center, heading, footprint, layout)) return false;
    if (minSpeed > 1e-12) {
      const angle = Math.max(...first.map(value => Math.atan2(
        Math.abs(value.x * forward.z - value.z * forward.x),
        value.x * forward.x + value.z * forward.z,
      )));
      const displacement = Math.max(...points.map(value => Math.hypot(value.x - center.x, value.z - center.z)));
      const radius = Math.hypot(footprint.width / 2 + gap, footprint.length / 2 + gap);
      const extra = displacement + 2 * radius * Math.sin(angle / 2);
      const bound = crossBounds(first, second) / minSpeed ** 3;
      if (bound <= maxCurvature && gardenPoseIsClear(center, heading, footprint, layout, extra)) {
        maxBound = Math.max(maxBound, bound); return true;
      }
    }
    if (depth >= 14 || intervals > 8192) return false;
    return certify(halves[0], depth + 1) && certify(halves[1], depth + 1);
  };
  if (!Array.isArray(curves) || !curves.length || curves.some(points => !Array.isArray(points)
    || points.some(value => !value || value.y !== 0 || !['x', 'y', 'z'].every(axis => Number.isFinite(value[axis]))))
    || !Number.isFinite(maxCurvature) || maxCurvature <= 0) return undefined;
  try {
    const path = new AnimalLocomotionPath({ curves, tail: [{ x: 0, y: .33, z: 9, phase: 'stairs' }] });
    for (let i = 0; i < curves.length; i++) {
      const start = path.curveAt(0, i), end = path.curveAt(1, i);
      if (i && (Math.abs(angleDelta(start.heading, path.curveAt(1, i - 1).heading)) > 1e-8
        || Math.abs(start.curvature - path.curveAt(1, i - 1).curvature) > 1e-8)) return undefined;
      if (!gardenPoseIsClear(start.position, start.heading, footprint, layout)
        || !gardenPoseIsClear(end.position, end.heading, footprint, layout)
        || !certify(curves[i])) return undefined;
    }
    return { path, intervals, maxCurvatureBound: maxBound };
  } catch { return undefined; }
}

/** Forward-only near-Ark clearing planner. No pivot or orientation reset. */
export function planGardenApproach({ start, heading, footprint, turnCurvature, layout = gardenLayout, preserveApproved = false }) {
  if (!gardenPoseIsClear(start, heading, footprint, layout)) throw new GardenRouteError('This starting pose is outside the clear garden.');
  const goal = p(0, 9.5);
  if (footprint.width + gap * 2 >= 2.96) throw new GardenRouteError('This animal needs a wider stair corridor.');
  if (preserveApproved) {
    if (Math.hypot(start.x - 4, start.z - 12) > 1e-8 || Math.abs(angleDelta(heading, Math.atan2(-1, .55))) > 1e-8) throw new GardenRouteError('The approved route applies only to its original starting pose.');
    return { curves: [approvedApproach.map(value => ({ ...value }))], checked: 'approved default', start, heading };
  }
  // The .7/.1.3 gait variants support a .6 stride difference. Widen turns for
  // the body envelope instead of saturating a gait on an arbitrarily tight arc.
  if (turnCurvature !== undefined && (!Number.isFinite(turnCurvature) || turnCurvature <= 0)) throw new GardenRouteError('The native gait needs a positive turning range.');
  const maxCurvature = Math.min(turnCurvature ?? .6 / footprint.width, 1 / Math.max(1.3, footprint.length * .35));
  const handles = [1.5, 2.5, 3.5, 4.5];
  let best;
  const consider = curves => {
    const certificate = certifyGardenCurves(curves, footprint, maxCurvature, layout);
    if (certificate && (!best || certificate.path.approachLength < best.length)) best = { curves, length: certificate.path.approachLength, certificate };
  };
  for (const a of handles) for (const b of handles) consider([quintic(start, heading, goal, Math.PI, a, b)]);
  if (!best) {
    for (const x of [6, -6, 10, -10, 12, -12]) {
      for (const a of [3, 5, 6]) for (const b of [2.5, 3.5, 4.5]) consider([freeTurn(start, heading, goal, a, b, x)]);
    }
  }
  if (!best) {
    // A free lateral junction permits center/away turns with a nonzero tangent.
    // A single collinear curve cannot reverse heading without a cusp.
    for (const front of [0, 2, 4, 6, 8].map(offset => Math.min(22, Math.max(15, start.z + offset)))) {
      for (const x of [4, -4, 7, -7, 10, -10]) {
        const middle = p(x, front);
        for (const direction of [Math.PI / 2, -Math.PI / 2, Math.PI]) {
          for (const a of handles) for (const b of handles) consider([
            quintic(start, heading, middle, direction, a, b),
            quintic(middle, direction, goal, Math.PI, b, a),
          ]);
        }
      }
      if (best) break;
    }
  }
  if (!best) throw new GardenRouteError('This pose has no supported clear forward route. Choose another garden start.');
  const first = new AnimalLocomotionPath({ curves: best.curves, tail: [{ x: 0, y: .33, z: 9, phase: 'stairs' }] }).sample(0);
  if (Math.abs(angleDelta(first.heading, heading)) > 1e-6) throw new GardenRouteError('The starting heading cannot be preserved.');
  return { curves: best.curves, checked: 'continuous route-envelope and curvature bounds',
    clearance: { intervals: best.certificate.intervals, maxCurvatureBound: best.certificate.maxCurvatureBound, maxCurvature }, start, heading };
}
