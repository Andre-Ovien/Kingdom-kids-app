// Read-only loader/animation diagnostic. No renderer, browser, or Blender.
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { animalPreviewProfile, selectAnimalGaits, animalPreviewHeight, animalPreviewSpeed, validateAnimalGaitDurations, animalFlightClearance } from './animal_preview_config.mjs';
import { AnimalGaitBlend } from './animal_locomotion.mjs';
import { measureGaitEnvelope } from './gait_envelope.mjs';
import { planGardenApproach, approachFixture, interiorEndpoint } from './garden_routes.mjs';

const threeUrl = new URL('./vendor/three.module.js', import.meta.url).href;
const moduleUrl = source => 'data:text/javascript;base64,' + Buffer.from(source).toString('base64');
const utilsSource = (await readFile(new URL('./vendor/utils/BufferGeometryUtils.js', import.meta.url), 'utf8')).replace("from 'three'", `from '${threeUrl}'`);
const loaderSource = (await readFile(new URL('./vendor/loaders/GLTFLoader.js', import.meta.url), 'utf8')).replace("from 'three'", `from '${threeUrl}'`).replace("from '../utils/BufferGeometryUtils.js'", `from '${moduleUrl(utilsSource)}'`);
const THREE = await import(threeUrl);
const { GLTFLoader } = await import(moduleUrl(loaderSource));
export { THREE };
export async function loadNativeAsset(filename, ignoreTextures = false) {
  const bytes = await readFile(new URL(`./assets/${filename}`, import.meta.url));
  const loader = new GLTFLoader();
  if (ignoreTextures) loader.register(() => ({ name: 'read-only-bounds', loadTexture: () => Promise.resolve(new THREE.Texture()) }));
  return loader.parseAsync(bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength), '');
}

export function prepareNativeClip(source) {
  if (!source) return undefined;
  const clip = source.clone();
  const first = Math.min(...clip.tracks.map(track => track.times[0]));
  for (const track of clip.tracks) for (let i = 0; i < track.times.length; i++) track.times[i] -= first;
  return clip.resetDuration();
}

for (const id of process.argv.slice(2)) {
  const profile = animalPreviewProfile(id);
  assert.equal(profile.id, id, 'Choose an allowlisted review animal.');
  // Node has no browser image decoder. Keep actual geometry/skin/animation
  // parsing, but substitute Texture objects when embedded images are assigned.
  // Image payloads are checked independently; visual texture review is pending.
  const asset = await loadNativeAsset(profile.asset, true);
  const remove = [];
  asset.scene.traverse(object => { if (object.isCamera || object.isLight || object.name.replace(/[ _]/g, '').toLowerCase() === 'animalreviewground') remove.push(object); });
  for (const object of remove) object.removeFromParent();
  const meshes = [];
  asset.scene.traverse(object => {
    if (!object.isSkinnedMesh) return;
    const weights = object.geometry.getAttribute('skinWeight');
    const joints = object.geometry.getAttribute('skinIndex');
    assert.ok(weights && joints, 'The native body must retain its skin weights and joints.');
    let weightError = 0;
    for (let i = 0; i < weights.count; i++) {
      const values = [weights.getX(i), weights.getY(i), weights.getZ(i), weights.getW(i)];
      assert.ok(values.every(value => Number.isFinite(value) && value >= 0), 'Native skin weights must be finite and nonnegative.');
      weightError = Math.max(weightError, Math.abs(values.reduce((sum, value) => sum + value, 0) - 1));
      for (const joint of [joints.getX(i), joints.getY(i), joints.getZ(i), joints.getW(i)]) {
        assert.ok(Number.isInteger(joint) && joint >= 0 && joint < object.skeleton.bones.length, 'A native mesh has an invalid joint index.');
      }
    }
    assert.ok(weightError < 1e-5, 'The native skin weights must stay normalized.');
    const materials = (Array.isArray(object.material) ? object.material : [object.material]).map(material => {
      assert.ok(material.color.toArray().every(Number.isFinite), 'Native material colors must stay finite.');
      return { name: material.name, color: material.color.toArray(),
        hasDiffuseMap: !!material.map, hasNormalMap: !!material.normalMap, roughness: material.roughness };
    });
    meshes.push({ name: object.name, joints: object.skeleton.bones.length,
      vertices: weights.count, triangles: (object.geometry.index?.count ?? weights.count) / 3, maxWeightError: weightError, materials });
  });
  assert.ok(meshes.length, 'The native export must contain a skinned animal body.');
  const gaits = Object.fromEntries(Object.entries(selectAnimalGaits(asset.animations, profile)).map(([key, clip]) => [key, prepareNativeClip(clip)]));
  assert.ok(gaits.walk, 'The required native walk is missing.');
  validateAnimalGaitDurations(gaits, profile);
  const loops = {};
  for (const [name, clip] of Object.entries(gaits)) {
    if (!clip) continue;
    let error = 0;
    for (const track of clip.tracks) {
      const n = track.getValueSize(); const first = Array.from(track.values.slice(0, n)); const last = Array.from(track.values.slice(-n));
      const direct = Math.max(...first.map((v, i) => Math.abs(v - last[i])));
      const reverse = Math.max(...first.map((v, i) => Math.abs(v + last[i])));
      error = Math.max(error, track.name.endsWith('quaternion') ? Math.min(direct, reverse) : direct);
    }
    assert.ok(error < 1e-5, `${clip.name} does not close.`);
    loops[name] = { name: clip.name, duration: clip.duration, loopError: error };
  }
  const mixer = new THREE.AnimationMixer(asset.scene);
  const actions = Object.fromEntries(Object.entries(gaits).map(([key, clip]) => [key, clip ? mixer.clipAction(clip) : undefined]));
  actions.walk.reset().play(); mixer.update(0); asset.scene.updateMatrixWorld(true);
  asset.scene.traverse(object => { if (object.isSkinnedMesh) { object.skeleton.update(); object.computeBoundingBox(); object.computeBoundingSphere(); } });
  const standingBounds = new THREE.Box3().setFromObject(asset.scene);
  const size = standingBounds.getSize(new THREE.Vector3());
  const height = animalPreviewHeight(profile, size); const factor = height / size.y; const normalized = size.clone().multiplyScalar(factor);
  const gaitEnvelope = measureGaitEnvelope({ THREE, asset: asset.scene, mixer, gaits, actions, standingBounds, factor });
  const flightClearance = animalFlightClearance(profile, gaitEnvelope);
  let gaitInterior;
  try { gaitInterior = { endpointZ: interiorEndpoint(gaitEnvelope.straight), fitsCabinDepth: true }; }
  catch (error) { gaitInterior = { fitsCabinDepth: false, rejected: error.message }; }
  const approaches = Object.fromEntries(['left', 'right', 'far-left', 'far-right', 'center', 'away', 'away-left', 'away-right'].map(id => {
    try {
      const planned = planGardenApproach({ ...approachFixture(id), footprint: gaitEnvelope, turnCurvature: profile.turnCurvature });
      return [id, { curves: planned.curves.length, clearance: planned.clearance }];
    } catch (error) { return [id, { rejected: error.message }]; }
  }));
  const blend = new AnimalGaitBlend({ ...actions, period: gaits.walk.duration, stanceWidth: normalized.x, turnCurvature: profile.turnCurvature });
  for (let i = 0; i < 1200; i++) {
    const weights = blend.steer(i < 600 ? .5 : -.5, .01); mixer.update(.01);
    assert.ok(Math.abs(weights.walk + weights.left + weights.right - 1) < 1e-12);
    for (const action of Object.values(actions)) if (action) assert.ok(Math.abs(action.time / action.getClip().duration - actions.walk.time / gaits.walk.duration) < 1e-8);
  }
  // Record named foot controller spans in world space to verify inside/outside
  // direction independently of anatomical name suffixes.
  const feet = []; asset.scene.traverse(object => { if (/^(Front|Back)Foot[LR]$|^IK(Front|Back)Leg[._]?[LR]$|^(Front|Back)Paw_[LR]$/.test(object.name)) feet.push(object); });
  const spans = {};
  for (const [kind, action] of Object.entries(actions)) {
    if (!action) continue;
    mixer.stopAllAction(); action.reset().setEffectiveWeight(1).setEffectiveTimeScale(1).play();
    const samples = Object.fromEntries(feet.map(foot => [foot.name, []]));
    for (let i = 0; i <= 48; i++) {
      action.time = Math.min(action.getClip().duration - 1e-7, i / 48 * action.getClip().duration); mixer.update(0); asset.scene.updateMatrixWorld(true);
      for (const foot of feet) samples[foot.name].push(foot.getWorldPosition(new THREE.Vector3()));
    }
    spans[kind] = Object.fromEntries(feet.map(foot => {
      const positions = samples[foot.name]; const z = positions.map(value => value.z);
      return [foot.name, { x: positions.reduce((sum, value) => sum + value.x, 0) / positions.length, forwardSpan: Math.max(...z) - Math.min(...z) }];
    }));
  }
  console.log(JSON.stringify({ animal: id, meshes, clips: loops, missingTurns: blend.missingTurns, normalizedDimensions: normalized.toArray(), normalizationFactor: factor, gaitEnvelope, flightClearance, approaches, gaitInterior, walkSpeed: animalPreviewSpeed(profile, factor), legacyInteriorEndpointZ: Math.min(-1, 2.5 - normalized.z - .25), centeredBodyClearEndpointZ: 2.5 - normalized.z / 2 - .25, footSpans: spans }, null, 2));
}
