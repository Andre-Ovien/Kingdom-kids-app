import test from 'node:test';
import assert from 'node:assert/strict';
import { AnimalLocomotionPath, AnimalLocomotion, AnimalGaitBlend, angleDelta } from './animal_locomotion.mjs';

const near = (actual, expected, tolerance = 1e-8) => assert.ok(Math.abs(actual - expected) <= tolerance, `${actual} != ${expected}`);
const closePoint = (actual, expected) => ['x', 'y', 'z'].forEach(axis => near(actual[axis], expected[axis]));
function path() {
  const tail = [];
  for (let i = 0; i < 13; i++) tail.push({ x: 0, y: (i + 1) * .33, z: 9 - i * .5, phase: 'stairs' });
  tail.push({ x: 0, y: 4.3, z: 2.5, phase: 'door' }, { x: 0, y: 4.3, z: -1, phase: 'interior' });
  return new AnimalLocomotionPath({ approach: [
    { x: 4, y: 0, z: 12 }, { x: 3, y: 0, z: 12.55 },
    { x: 2, y: 0, z: 13.10 }, { x: 0, y: 0, z: 12.5 },
    { x: 0, y: 0, z: 11 }, { x: 0, y: 0, z: 9.5 },
  ], tail });
}

test('ground curve has exact endpoints and reaches the stair heading with zero curvature', () => {
  const route = path();
  closePoint(route.sample(0).position, { x: 4, y: 0, z: 12 });
  closePoint(route.curveAt(1).position, { x: 0, y: 0, z: 9.5 });
  near(route.curveAt(0).curvature, 0);
  near(route.curveAt(1).curvature, 0);
  near(angleDelta(route.curveAt(1).heading, Math.PI), 0);
  const before = route.sample(route.approachLength - 1e-5);
  const after = route.sample(route.approachLength + 1e-5);
  near(angleDelta(before.heading, after.heading), 0, 1e-6);
  near(before.curvature, 0, 1e-5);
  assert.equal(after.curvature, 0);
  for (let i = 0; i <= 1000; i++) {
    const sample = route.curveAt(i / 1000);
    assert.ok(Number.isFinite(sample.heading) && Number.isFinite(sample.curvature));
    assert.equal(sample.position.y, 0);
  }
});

test('idle, first walking frame and repeat start keep the same position and heading', () => {
  const motion = new AnimalLocomotion({ path: path(), speed: .35 });
  const original = { ...motion.frame.position };
  const heading = motion.heading;
  motion.advance(100);
  closePoint(motion.frame.position, original);
  assert.equal(motion.start(), true);
  motion.advance(0);
  near(motion.heading, heading);
  closePoint(motion.frame.position, original);
  motion.advance(.1);
  assert.equal(motion.start(), false);
  near(motion.distance, .035);
  assert.ok(Math.abs(angleDelta(motion.heading, heading)) < .01);
});

test('arc-length speed and heading are independent of frame subdivisions across the join', () => {
  const a = new AnimalLocomotion({ path: path(), speed: .35 });
  const b = new AnimalLocomotion({ path: path(), speed: .35 });
  a.start(); b.start();
  a.advance(25);
  for (let i = 0; i < 2500; i++) b.advance(.01);
  near(a.distance, 8.75);
  near(b.distance, 8.75);
  closePoint(a.frame.position, b.frame.position);
  near(angleDelta(a.heading, b.heading), 0);
  assert.equal(a.frame.phase, 'stairs');
});

test('heading follows each arc tangent without a corner snap or angle-wrap spin', () => {
  const motion = new AnimalLocomotion({ path: path(), speed: .35 });
  motion.start();
  let maximumRate = 0;
  let previous = motion.heading;
  while (motion.distance < motion.path.approachLength + .2) {
    motion.advance(.01);
    const rate = Math.abs(motion.heading - previous) / .01;
    maximumRate = Math.max(maximumRate, rate);
    near(angleDelta(motion.heading, motion.frame.heading), 0);
    assert.ok(rate < 1.2);
    previous = motion.heading;
  }
  assert.ok(maximumRate > .01);
  near(angleDelta(-Math.PI + .01, Math.PI - .01), .02);
});

test('pause freezes motion; replay restores initial pose and endpoint only boards fully inside', () => {
  const motion = new AnimalLocomotion({ path: path(), speed: .35 });
  motion.start(); motion.advance(12);
  const before = { ...motion.frame.position };
  const travelled = motion.distance;
  motion.paused = true; motion.advance(90);
  near(motion.distance, travelled);
  closePoint(motion.frame.position, before);
  motion.paused = false;
  motion.advance((motion.path.length - motion.distance - .01) / motion.speed);
  assert.equal(motion.frame.arrived, false);
  motion.advance(1);
  assert.equal(motion.frame.arrived, true);
  assert.equal(motion.running, false);
  closePoint(motion.frame.position, { x: 0, y: 4.3, z: -1 });
  motion.reset();
  closePoint(motion.frame.position, { x: 4, y: 0, z: 12 });
  near(motion.heading, motion.path.sample(0).heading);
  assert.equal(motion.running, false);
});

class Action {
  constructor(duration) { this.duration = duration; this.time = 0; this.resets = 0; this.timeScale = 1; this.weight = 0; }
  getClip() { return { duration: this.duration }; }
  reset() { this.resets++; this.time = 0; return this; }
  play() { return this; }
  setEffectiveTimeScale(value) { this.timeScale = value; return this; }
  setEffectiveWeight(value) { this.weight = value; return this; }
  step(seconds) { this.time = (this.time + seconds * this.timeScale) % this.duration; }
}

test('real left/right gait weights are smooth, valid and normalized without resetting phase', () => {
  const actions = { walk: new Action(2.042), left: new Action(2), right: new Action(1.98) };
  const blend = new AnimalGaitBlend({ ...actions, period: 2.042, stanceWidth: 2.5 });
  const originalResets = Object.values(actions).map(action => action.resets);
  for (let i = 0; i < 1000; i++) {
    const weights = blend.steer(i < 300 ? .1 : i < 600 ? -.1 : 0, .017);
    near(weights.walk + weights.left + weights.right, 1);
    for (const weight of Object.values(weights)) assert.ok(Number.isFinite(weight) && weight >= 0 && weight <= 1);
    for (const action of Object.values(actions)) action.step(.017);
    near(actions.walk.time / actions.walk.duration, actions.left.time / actions.left.duration);
    near(actions.walk.time / actions.walk.duration, actions.right.time / actions.right.duration);
  }
  assert.deepEqual(Object.values(actions).map(action => action.resets), originalResets);
  assert.ok(blend.weights.walk > .999);
  blend.reset();
  assert.equal(actions.walk.time, 0);
  assert.equal(actions.left.time, 0);
  assert.equal(actions.right.time, 0);
});

test('missing real turn clips are explicit and never replaced with fabricated turn poses', () => {
  const walk = new Action(2);
  const blend = new AnimalGaitBlend({ walk, period: 2, stanceWidth: 2.5 });
  assert.deepEqual(blend.missingTurns, ['left', 'right']);
  assert.deepEqual(blend.steer(1, 2), { walk: 1, left: 0, right: 0 });
  const partial = new AnimalGaitBlend({ walk, left: new Action(2), period: 2, stanceWidth: 2.5 });
  assert.deepEqual(partial.missingTurns, ['right']);
  assert.deepEqual(partial.steer(-1, 2), { walk: 1, left: 0, right: 0 });
});

test('nonfinite routes, clocks and gait periods fail before corrupting movement', () => {
  assert.throws(() => new AnimalLocomotionPath({ approach: [
    { x: NaN, y: 0, z: 0 }, { x: 1, y: 0, z: 1 }, { x: 2, y: 0, z: 2 },
  ], tail: [{ x: 3, y: 0, z: 3 }] }));
  assert.throws(() => new AnimalLocomotion({ path: path(), speed: NaN }));
  assert.throws(() => new AnimalLocomotion({ path: path(), speed: .35 }).advance(-1));
  assert.throws(() => new AnimalGaitBlend({ walk: new Action(0), period: 2, stanceWidth: 2 }));
  assert.throws(() => new AnimalGaitBlend({ walk: new Action(2), period: 2, stanceWidth: NaN }));
  assert.throws(() => new AnimalGaitBlend({ walk: new Action(2), period: 2, stanceWidth: .8, turnCurvature: 0 }));
});

test('paired-hop native lean clips use an explicit broad-turn range without changing default stride steering', () => {
  const hop = new AnimalGaitBlend({ walk: new Action(2 / 3), left: new Action(2 / 3), right: new Action(2 / 3), period: 2 / 3, stanceWidth: .63, turnCurvature: .45 });
  near(hop.steer(.225, 20).left, .5);
  near(hop.steer(-.45, 20).right, 1);
  assert.ok(hop.actions.walk.time === 0 && hop.actions.left.time === 0);
  const legacy = new AnimalGaitBlend({ walk: new Action(2), left: new Action(2), period: 2, stanceWidth: .63 });
  near(legacy.steer(.225, 20).left, .225 * .63 / .6);
});
