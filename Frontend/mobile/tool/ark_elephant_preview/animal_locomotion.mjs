const clamp = (value, min, max) => Math.max(min, Math.min(max, value));
const distance = (a, b) => Math.hypot(b.x - a.x, b.y - a.y, b.z - a.z);
const point = value => ({ x: value.x, y: value.y, z: value.z });
const lerp = (a, b, amount) => ({
  x: a.x + (b.x - a.x) * amount,
  y: a.y + (b.y - a.y) * amount,
  z: a.z + (b.z - a.z) * amount,
});

export function angleDelta(target, current) {
  return Math.atan2(Math.sin(target - current), Math.cos(target - current));
}

function bezier(points, amount) {
  let row = points.map(point);
  while (row.length > 1) row = row.slice(1).map((value, index) => lerp(row[index], value, amount));
  return row[0];
}

function derivative(points) {
  const degree = points.length - 1;
  return points.slice(1).map((value, index) => ({
    x: (value.x - points[index].x) * degree,
    y: (value.y - points[index].y) * degree,
    z: (value.z - points[index].z) * degree,
  }));
}

/** Geometry and arc length only: no renderer, animal species, or animation state. */
export class AnimalLocomotionPath {
  constructor({ approach, curves, tail, samples = 256 }) {
    const controls = curves ?? [approach];
    if (!Array.isArray(controls) || !controls.length || controls.some(value => !Array.isArray(value) || value.length < 3) || !Array.isArray(tail) || tail.length < 1 || !Number.isInteger(samples) || samples < 32 || samples > 4096) throw new Error('A locomotion path needs curves and a tail.');
    if ([...controls.flat(), ...tail].some(value => !['x', 'y', 'z'].every(axis => Number.isFinite(value[axis])))) throw new Error('Locomotion coordinates must be finite.');
    this.curves = [];
    let length = 0;
    let previous;
    for (const values of controls) {
      const points = values.map(point);
      if (previous && distance(previous, points[0]) > 1e-8) throw new Error('Ground curves must share their junction.');
      const record = { points, firstDerivative: derivative(points), start: length, length: 0, table: [{ t: 0, distance: 0 }] };
      record.secondDerivative = derivative(record.firstDerivative);
      previous = points[0];
      for (let i = 1; i <= samples; i++) {
        const t = i / samples;
        const current = bezier(points, t);
        record.length += distance(previous, current);
        record.table.push({ t, distance: record.length });
        previous = current;
      }
      length += record.length;
      this.curves.push(record);
    }
    // Preserve the original single-curve inspection contract.
    this.approach = this.curves[0].points;
    this.firstDerivative = this.curves[0].firstDerivative;
    this.secondDerivative = this.curves[0].secondDerivative;
    this.table = this.curves[0].table;
    this.approachLength = length;
    this.lines = [];
    for (const endpoint of tail) {
      const to = point(endpoint);
      const span = distance(previous, to);
      if (span <= 1e-8) throw new Error('Locomotion waypoints must be separate.');
      this.lines.push({ from: previous, to, start: length, length: span, phase: endpoint.phase });
      length += span;
      previous = to;
    }
    this.length = length;
  }

  curveAt(t, curveIndex = 0) {
    const curve = this.curves[curveIndex];
    const tangent = bezier(curve.firstDerivative, t);
    const second = bezier(curve.secondDerivative, t);
    const planarSpeed = Math.hypot(tangent.x, tangent.z);
    if (planarSpeed <= 1e-8) throw new Error('The ground curve needs nonzero planar tangents.');
    return {
      position: bezier(curve.points, t),
      heading: Math.atan2(tangent.x, tangent.z),
      planarSpeed,
      curvature: (tangent.z * second.x - tangent.x * second.z) / planarSpeed ** 3,
      phase: 'approach', arrived: false,
    };
  }

  sample(travelled) {
    const at = clamp(travelled, 0, this.length);
    if (at < this.approachLength) {
      const index = this.curves.findIndex(value => at < value.start + value.length);
      const curve = this.curves[index];
      const local = at - curve.start;
      let low = 0;
      let high = curve.table.length - 1;
      while (high - low > 1) {
        const middle = (low + high) >> 1;
        if (curve.table[middle].distance <= local) low = middle;
        else high = middle;
      }
      const a = curve.table[low];
      const b = curve.table[high];
      const ratio = (local - a.distance) / (b.distance - a.distance);
      return this.curveAt(a.t + (b.t - a.t) * ratio, index);
    }
    const line = this.lines.find(value => at < value.start + value.length) ?? this.lines.at(-1);
    const delta = { x: line.to.x - line.from.x, z: line.to.z - line.from.z };
    return {
      position: lerp(line.from, line.to, clamp((at - line.start) / line.length, 0, 1)),
      heading: Math.atan2(delta.x, delta.z), curvature: 0,
      phase: line.phase, arrived: at >= this.length,
    };
  }
}

/** Shared animal root motion. Idle/start/replay share the first path tangent. */
export class AnimalLocomotion {
  constructor({ path, speed }) {
    if (!Number.isFinite(speed) || speed <= 0) throw new Error('Locomotion speed must be positive.');
    this.path = path;
    this.speed = speed;
    this.reset();
  }
  reset() {
    this.distance = 0;
    this.running = false;
    this.paused = false;
    this.frame = this.path.sample(0);
    this.heading = this.frame.heading;
  }
  start() {
    if (this.running || this.frame.arrived) return false;
    this.running = true;
    return true;
  }
  advance(seconds) {
    if (!Number.isFinite(seconds) || seconds < 0) throw new Error('Locomotion time must be finite and nonnegative.');
    if (!this.running || this.paused || seconds === 0) return this.frame;
    this.distance = Math.min(this.path.length, this.distance + seconds * this.speed);
    this.frame = this.path.sample(this.distance);
    // Unwrap the continuous tangent across +/-pi; no route-corner orientation.
    this.heading += angleDelta(this.frame.heading, this.heading);
    if (this.frame.arrived) this.running = false;
    return this.frame;
  }
}

/** Phase-locked real gait variants. Missing clips never become invented turns. */
export class AnimalGaitBlend {
  constructor({ walk, left, right, period, stanceWidth, turnCurvature, blendSeconds = .3 }) {
    if (!walk || !Number.isFinite(period) || period <= 0 || !Number.isFinite(stanceWidth) || stanceWidth <= 0 || !Number.isFinite(blendSeconds) || blendSeconds <= 0) throw new Error('A gait blend needs a walk period and stance width.');
    this.actions = { walk, left, right };
    this.period = period;
    this.stanceWidth = stanceWidth;
    this.turnCurvature = turnCurvature ?? .6 / stanceWidth;
    this.hasTurnCurvatureOverride = turnCurvature !== undefined;
    if (!Number.isFinite(this.turnCurvature) || this.turnCurvature <= 0) throw new Error('Gait steering needs a positive curvature range.');
    this.blendSeconds = blendSeconds;
    this.weights = { walk: 1, left: 0, right: 0 };
    this.reset();
  }
  get missingTurns() {
    return ['left', 'right'].filter(name => !this.actions[name]);
  }
  reset() {
    this.weights = { walk: 1, left: 0, right: 0 };
    for (const [name, action] of Object.entries(this.actions)) {
      if (!action) continue;
      if (!Number.isFinite(action.getClip().duration) || action.getClip().duration <= 0) throw new Error('Real gait clips must have a positive duration.');
      action.reset().play();
      action.setEffectiveTimeScale(action.getClip().duration / this.period);
      action.setEffectiveWeight(this.weights[name]);
    }
  }
  steer(curvature, seconds) {
    if (!Number.isFinite(curvature) || !Number.isFinite(seconds) || seconds < 0) throw new Error('Steering inputs must be finite.');
    // Walkers use the .7/1.3 stride difference. A paired hop can instead
    // specify a broader presentation range for its own native lean clips.
    const amount = clamp(this.hasTurnCurvatureOverride
      ? Math.abs(curvature) / this.turnCurvature
      : Math.abs(curvature) * this.stanceWidth / .6, 0, 1);
    const target = {
      left: curvature > 0 && this.actions.left ? amount : 0,
      right: curvature < 0 && this.actions.right ? amount : 0,
    };
    const alpha = 1 - Math.exp(-seconds / this.blendSeconds);
    this.weights.left += (target.left - this.weights.left) * alpha;
    this.weights.right += (target.right - this.weights.right) * alpha;
    this.weights.walk = Math.max(0, 1 - this.weights.left - this.weights.right);
    for (const [name, action] of Object.entries(this.actions)) {
      if (action) action.setEffectiveWeight(this.weights[name]);
    }
    return { ...this.weights };
  }
}
