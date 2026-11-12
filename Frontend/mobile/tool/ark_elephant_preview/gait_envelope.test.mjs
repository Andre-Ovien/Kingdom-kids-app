import test from 'node:test';
import assert from 'node:assert/strict';
import * as THREE from './vendor/three.module.js';
import { measureGaitEnvelope } from './gait_envelope.mjs';

test('gait bounds contain moving geometry beyond standing, include blends, and restore the start pose', () => {
  const asset = new THREE.Group();
  const body = new THREE.Mesh(new THREE.BoxGeometry(1, 1, 2));
  const head = new THREE.Mesh(new THREE.BoxGeometry(.2, .2, .2));
  head.name = 'Head'; head.position.set(0, .3, 1.3);
  asset.add(body, head); asset.updateMatrixWorld(true);
  const standingBounds = new THREE.Box3().setFromObject(asset);
  const mixer = new THREE.AnimationMixer(asset);
  const gait = (name, x, z) => new THREE.AnimationClip(name, 2, [
    new THREE.VectorKeyframeTrack('Head.position', [0, 1, 2], [0, .3, 1.3, x, .3, z, 0, .3, 1.3]),
  ]);
  const gaits = { walk: gait('walk', 0, 1.7), left: gait('left', .8, 2), right: gait('right', -.8, 2) };
  const actions = Object.fromEntries(Object.entries(gaits).map(([name, clip]) => [name, mixer.clipAction(clip)]));
  actions.walk.play(); mixer.update(0);
  const bounds = measureGaitEnvelope({ THREE, asset, mixer, gaits, actions, standingBounds, factor: 1 });
  assert.equal(bounds.poses, 343);
  assert.equal(bounds.blendSamples, 7);
  assert.ok(bounds.width > standingBounds.getSize(new THREE.Vector3()).x);
  assert.ok(bounds.length > standingBounds.getSize(new THREE.Vector3()).z);
  assert.ok(bounds.length > bounds.straight.length);
  assert.ok(bounds.basis.includes('sampled'));
  assert.ok(Math.abs(head.position.x) < 1e-8);
  assert.ok(Math.abs(head.position.z - 1.3) < 1e-6);
  assert.equal(actions.walk.getEffectiveWeight(), 1);
  assert.equal(actions.walk.time, 0);
  assert.throws(() => measureGaitEnvelope({ THREE, asset, mixer, gaits, actions, standingBounds, factor: 1, guard: -1 }), /valid scale/);
});

test('absent native turn clips are excluded from measurement instead of invented', () => {
  const asset = new THREE.Group();
  const body = new THREE.Mesh(new THREE.BoxGeometry(1, 1, 2)); body.name = 'Body'; asset.add(body);
  asset.updateMatrixWorld(true);
  const standingBounds = new THREE.Box3().setFromObject(asset);
  const mixer = new THREE.AnimationMixer(asset);
  const walk = new THREE.AnimationClip('walk', 1, [new THREE.VectorKeyframeTrack('Body.position', [0, 1], [0, 0, 0, 0, 0, 0])]);
  const actions = { walk: mixer.clipAction(walk) };
  const bounds = measureGaitEnvelope({ THREE, asset, mixer, gaits: { walk }, actions, standingBounds, factor: 1 });
  assert.equal(bounds.poses, 49); assert.equal(bounds.blendSamples, 1);
});
