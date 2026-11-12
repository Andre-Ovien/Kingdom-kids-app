import * as THREE from 'three';
import { GLTFLoader } from './vendor/loaders/GLTFLoader.js';
import { AnimalLocomotionPath, AnimalLocomotion, AnimalGaitBlend } from './animal_locomotion.mjs?review=varied-starts-v1';
import { animalPreviewProfile, selectAnimalGaits, animalPreviewHeight, animalPreviewSpeed, validateAnimalGaitDurations, animalFlightClearance } from './animal_preview_config.mjs?review=varied-starts-v1';
import { approachFixture, planGardenApproach, interiorEndpoint } from './garden_routes.mjs?review=varied-starts-v1';
import { measureGaitEnvelope } from './gait_envelope.mjs?review=varied-starts-v1';

// Isolated, local review scene. No app repository, profile, API submission,
// catalogue entry, reward, or ten-animal completion rule is involved here.
const canvas = document.querySelector('#view');
const status = document.querySelector('#status');
const startButton = document.querySelector('#start');
const pauseButton = document.querySelector('#pause');
const replayButton = document.querySelector('#replay');
const garden = document.querySelector('#garden');
const animalProfile = animalPreviewProfile(new URL(window.location.href).searchParams.get('animal'));
let fixture = approachFixture(new URL(window.location.href).searchParams.get('approach'));
const approvedDefault = fixture.id === 'default' && ['elephant', 'sheep'].includes(animalProfile.id);
if (fixture.id === 'default' && !approvedDefault) fixture = { ...approachFixture('right'), id: 'default' };
document.title = `Ark · ${animalProfile.label} development preview`;
document.querySelector('#scene').setAttribute('aria-label', `Noah's Ark ${animalProfile.id} boarding preview`);
document.querySelector('.badge').textContent = `Development preview · one ${animalProfile.id}${fixture.id === 'default' ? '' : ` · ${fixture.id}`}`;
startButton.textContent = `Tap ${animalProfile.id}`;
const scene = new THREE.Scene();
const renderer = new THREE.WebGLRenderer({ canvas, alpha: true, antialias: true });
renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 1.5));
renderer.outputColorSpace = THREE.SRGBColorSpace;
renderer.toneMapping = THREE.ACESFilmicToneMapping;
renderer.toneMappingExposure = 1.1;
renderer.shadowMap.enabled = true;
renderer.shadowMap.type = THREE.PCFSoftShadowMap;
const camera = new THREE.OrthographicCamera(-18, 18, 9, -9, .1, 160);
const cameraTarget = new THREE.Vector3(0, 3, 3);
const cameraOffset = new THREE.Vector3(16, 10, 27);
const cameraPan = 0;
scene.add(new THREE.HemisphereLight(0xd7edff, 0x7c8754, 2.1));
const sun = new THREE.DirectionalLight(0xfff0d0, 3.0);
sun.position.set(-10, 18, 12);
sun.castShadow = true;
sun.shadow.mapSize.set(1024, 1024);
Object.assign(sun.shadow.camera, { left: -25, right: 25, top: 24, bottom: -20, near: 1, far: 75 });
sun.shadow.bias = -.0008;
sun.shadow.normalBias = .03;
scene.add(sun);
const shadowFloor = new THREE.Mesh(
  new THREE.PlaneGeometry(100, 100),
  new THREE.ShadowMaterial({ color: 0x24372a, opacity: .22 }),
);
shadowFloor.rotation.x = -Math.PI / 2;
shadowFloor.receiveShadow = true;
scene.add(shadowFloor);

let animal;
let mixer;
let walkAction;
let walkClip;
let ready = false;
let walking = false;
let paused = false;
let entered = false;
let locomotion;
let gaitBlend;
let lastTime;
let scheduled = false;
let bodyLength = 0;
let walkSpeed = .35;
const route = [new THREE.Vector3(fixture.start.x, 0, fixture.start.z), new THREE.Vector3(0, 0, 9.5)];
// Saved Ark has thirteen .33-high, .5-deep treads. These are actual world
// coordinates, converted from Blender Z-up to glTF Y-up.
for (let i = 0; i < 13; i++) route.push(new THREE.Vector3(0, (i + 1) * .33, 9 - i * .5));
route.push(new THREE.Vector3(0, 4.3, 2.5), new THREE.Vector3(0, 4.3, -1));

function materialSetup(root) {
  root.traverse(object => {
    if (!object.isMesh) return;
    object.castShadow = true;
    object.receiveShadow = true;
    for (const material of Array.isArray(object.material) ? object.material : [object.material]) {
      if (material) material.envMapIntensity = .45;
    }
  });
}

function stripReviewObjects(asset) {
  const removed = [];
  asset.traverse(object => {
    if (object.isCamera || object.isLight || object.name.replace(/[ _]/g, '').toLowerCase() === 'animalreviewground') removed.push(object);
  });
  for (const object of removed) object.removeFromParent();
}

function preparedClip(source) {
  if (!source) return undefined;
  const clip = source.clone();
  const firstKeyTime = Math.min(...clip.tracks.map(track => track.times[0]));
  for (const track of clip.tracks) {
    for (let i = 0; i < track.times.length; i++) track.times[i] -= firstKeyTime;
  }
  return clip.resetDuration();
}

function normalizedFigure(asset, height, excludeStaff = false) {
  asset.updateMatrixWorld(true);
  const bounds = new THREE.Box3();
  asset.traverse(object => {
    if (object.isMesh && !(excludeStaff && /staff/i.test(object.name))) {
      bounds.union(new THREE.Box3().setFromObject(object));
    }
  });
  const size = bounds.getSize(new THREE.Vector3());
  if (!Number.isFinite(size.y) || size.y <= 0) throw new Error('The exported figure has invalid bounds.');
  const factor = height / size.y;
  const center = bounds.getCenter(new THREE.Vector3());
  const normalizer = new THREE.Group();
  normalizer.add(asset);
  normalizer.scale.setScalar(factor);
  normalizer.position.set(-center.x * factor, -bounds.min.y * factor, -center.z * factor);
  const placement = new THREE.Group();
  placement.add(normalizer);
  placement.userData.normalizedSize = size.clone().multiplyScalar(factor);
  placement.userData.normalizationFactor = factor;
  scene.add(placement);
  return placement;
}

function updateCamera() {
  const target = cameraTarget.clone();
  target.x += cameraPan;
  camera.position.copy(target).add(cameraOffset);
  camera.lookAt(target);
  garden.style.backgroundPosition = `${50 + cameraPan * 2}% 50%`;
}

function resize() {
  const width = canvas.clientWidth;
  const height = canvas.clientHeight;
  renderer.setSize(width, height, false);
  const aspect = width / Math.max(1, height);
  const halfHeight = 9.5;
  camera.left = -halfHeight * aspect;
  camera.right = halfHeight * aspect;
  camera.top = halfHeight;
  camera.bottom = -halfHeight;
  camera.updateProjectionMatrix();
  updateCamera();
  requestRender();
}

function requestRender() {
  if (scheduled || document.hidden) return;
  scheduled = true;
  requestAnimationFrame(frame);
}

function placeAnimal() {
  const position = locomotion.frame.position;
  animal.position.set(position.x, position.y + (animalProfile.flightAltitude ?? 0), position.z);
  animal.rotation.y = locomotion.heading + animalProfile.forwardYaw;
}

function advance(seconds) {
  const movement = locomotion.advance(seconds);
  gaitBlend.steer(movement.curvature, seconds);
  placeAnimal();
  if (movement.arrived) {
    // Real wall geometry provides depth occlusion while entering. Remove the
    // model only after its entire body has clearance inside the doorway.
    animal.visible = false;
    walking = false;
    entered = true;
    status.textContent = `${animalProfile.label} is inside the Ark.`;
    pauseButton.disabled = true;
    replayButton.disabled = false;
  } else {
    status.textContent = movement.phase === 'interior' ? animalProfile.locomotion === 'flight' ? 'Flying through the open doorway…' : 'Walking through the open doorway…'
      : movement.phase !== 'approach' ? animalProfile.locomotion === 'flight' ? 'Flying up to the doorway…' : 'Walking up the staircase…'
      : gaitBlend.missingTurns.length ? 'Curved approach · real turn clips pending.'
      : animalProfile.locomotion === 'flight' ? 'Flying to the Ark…' : 'Walking around the approach…';
  }
}

function frame(time) {
  scheduled = false;
  const seconds = lastTime === undefined ? 0 : Math.max(0, (time - lastTime) / 1000);
  lastTime = time;
  if (walking && !paused) {
    advance(seconds);
    mixer.update(seconds);
  }
  renderer.render(scene, camera);
  if (walking && !paused) requestRender();
}

function start() {
  if (!ready || walking || entered) return;
  if (!locomotion.start()) return;
  walking = true;
  paused = false;
  lastTime = undefined;
  // Steering only changes phase-locked weights; it never resets a stride.
  startButton.disabled = true;
  pauseButton.disabled = false;
  pauseButton.textContent = 'Pause';
  status.textContent = animalProfile.locomotion === 'flight' ? 'Flying to the Ark…' : 'Walking to the Ark…';
  requestRender();
}

function replay() {
  if (!ready) return;
  walking = false;
  paused = false;
  entered = false;
  locomotion.reset();
  lastTime = undefined;
  gaitBlend.reset();
  mixer.update(0);
  animal.updateMatrixWorld(true);
  animal.traverse(object => {
    if (object.isSkinnedMesh) object.skeleton.update();
  });
  animal.visible = true;
  placeAnimal();
  startButton.disabled = false;
  pauseButton.disabled = true;
  replayButton.disabled = true;
  status.textContent = gaitBlend.missingTurns.length
    ? `Tap ${animalProfile.id} · real turn clips pending.`
    : `Tap the ${animalProfile.id} to walk aboard.`;
  requestRender();
}

startButton.addEventListener('click', start);
replayButton.addEventListener('click', replay);
pauseButton.addEventListener('click', () => {
  if (!walking) return;
  paused = !paused;
  lastTime = undefined;
  pauseButton.textContent = paused ? 'Resume' : 'Pause';
  if (paused) status.textContent = 'Preview paused.';
  requestRender();
});

const raycaster = new THREE.Raycaster();
let pointer;
function canvasPoint(event) {
  const bounds = canvas.getBoundingClientRect();
  const x = event.clientX - bounds.left;
  const y = event.clientY - bounds.top;
  return window.matchMedia('(orientation: portrait)').matches
    ? { x: y / bounds.height * canvas.clientWidth, y: (1 - x / bounds.width) * canvas.clientHeight }
    : { x: x / bounds.width * canvas.clientWidth, y: y / bounds.height * canvas.clientHeight };
}
canvas.addEventListener('pointerdown', event => {
  const at = canvasPoint(event);
  pointer = { id: event.pointerId, x: at.x, y: at.y, lastX: at.x, dragged: false };
  canvas.setPointerCapture(event.pointerId);
});
canvas.addEventListener('pointermove', event => {
  if (!pointer || pointer.id !== event.pointerId) return;
  const at = canvasPoint(event);
  if (Math.hypot(at.x - pointer.x, at.y - pointer.y) > 10) pointer.dragged = true;
  // This one-scene review uses a fixed photographic garden backdrop. Keep its
  // camera fixed so dragging cannot move the real models against that image.
  pointer.lastX = at.x;
});
canvas.addEventListener('pointerup', event => {
  if (!pointer || pointer.id !== event.pointerId) return;
  if (!pointer.dragged && ready && !walking && !entered) {
    const at = canvasPoint(event);
    raycaster.setFromCamera(new THREE.Vector2(
      at.x / canvas.clientWidth * 2 - 1,
      -at.y / canvas.clientHeight * 2 + 1,
    ), camera);
    if (raycaster.intersectObject(animal, true).length) start();
  }
  pointer = undefined;
});
canvas.addEventListener('pointercancel', () => { pointer = undefined; });
window.addEventListener('resize', resize);
document.addEventListener('visibilitychange', () => {
  lastTime = undefined;
  if (document.hidden && walking && !paused) {
    paused = true;
    pauseButton.textContent = 'Resume';
    status.textContent = 'Preview paused.';
  }
  if (!document.hidden) requestRender();
});
canvas.addEventListener('webglcontextlost', event => {
  event.preventDefault();
  walking = false;
  startButton.disabled = true;
  status.textContent = 'The 3D view stopped. Reload to reopen the preview.';
});

const loader = new GLTFLoader();
const revision = Date.now();
resize();
try {
  const [arkAsset, noahAsset, animalAsset] = await Promise.all([
    loader.loadAsync(`./assets/ark-review.glb?v=${revision}`),
    loader.loadAsync(`./assets/noah-review.glb?v=${revision}`),
    loader.loadAsync(`./assets/${animalProfile.asset}?v=${revision}`),
  ]);
  stripReviewObjects(arkAsset.scene);
  stripReviewObjects(noahAsset.scene);
  stripReviewObjects(animalAsset.scene);
  materialSetup(arkAsset.scene);
  materialSetup(noahAsset.scene);
  materialSetup(animalAsset.scene);
  // The saved robe's procedural color chain is not represented in glTF.
  // Restore only its actual Blender linear Base Color; retain skin textures,
  // cream panels, red sash, beard, sandals, and wood exactly as exported.
  noahAsset.scene.traverse(object => {
    if (!object.isMesh) return;
    for (const material of Array.isArray(object.material) ? object.material : [object.material]) {
      if (material?.name.replace(/_/g, ' ').toLowerCase() === 'deep grape woven outer robe') {
        material.color.setRGB(.18, .07, .27);
        material.needsUpdate = true;
      }
    }
  });
  scene.add(arkAsset.scene);
  const noah = normalizedFigure(noahAsset.scene, 1.8, true);
  noah.position.set(-2.7, 0, 9.3);
  // Resolve only clips from this loaded animal's own rig. Sheep must use its
  // intentional WalkSlow source action, never another walk or elephant track.
  const sourceGaits = Object.fromEntries(Object.entries(selectAnimalGaits(animalAsset.animations, animalProfile))
    .map(([name, clip]) => [name, preparedClip(clip)]));
  validateAnimalGaitDurations(sourceGaits, animalProfile);
  walkClip = sourceGaits.walk;
  if (walkClip) {
    mixer = new THREE.AnimationMixer(animalAsset.scene);
    walkAction = mixer.clipAction(walkClip);
    walkAction.reset().play();
    mixer.update(0);
    animalAsset.scene.updateMatrixWorld(true);
    animalAsset.scene.traverse(object => {
      if (object.isSkinnedMesh) {
        object.skeleton.update();
        object.computeBoundingBox();
        object.computeBoundingSphere();
      }
    });
  }
  // Bounds and placement must use the actual standing gait pose, never the
  // unanimated bind pose. The mixer clock stays still until the animal tap.
  const standingBounds = new THREE.Box3().setFromObject(animalAsset.scene);
  const posedSize = standingBounds.getSize(new THREE.Vector3());
  const height = animalPreviewHeight(animalProfile, posedSize);
  // Preserve approved default placement and route exactly. New review starts
  // use all the selected animal's native gaits instead of standing bounds.
  const gaitEnvelope = !approvedDefault && walkClip ? measureGaitEnvelope({
    THREE, asset: animalAsset.scene, mixer, gaits: sourceGaits,
    actions: Object.fromEntries(Object.entries(sourceGaits).map(([name, clip]) => [name, clip ? mixer.clipAction(clip) : undefined])),
    standingBounds, factor: height / posedSize.y,
  }) : undefined;
  const flightClearance = animalFlightClearance(animalProfile, gaitEnvelope);
  animal = normalizedFigure(animalAsset.scene, height);
  // Each asset has its own audited source-world stance calibration.
  walkSpeed = animalPreviewSpeed(animalProfile, animal.userData.normalizationFactor);
  bodyLength = animal.userData.normalizedSize.z;
  route[route.length - 1].z = interiorEndpoint(gaitEnvelope?.straight ?? bodyLength, approvedDefault);
  const planned = planGardenApproach({ ...fixture,
    footprint: gaitEnvelope ?? { width: animal.userData.normalizedSize.x, length: bodyLength },
    turnCurvature: animalProfile.turnCurvature,
    preserveApproved: approvedDefault,
  });
  const approach = planned.curves[0];
  const path = new AnimalLocomotionPath({
    curves: planned.curves,
    tail: route.slice(2).map((value, index) => ({
      ...value,
      phase: index === route.length - 3 ? 'interior'
        : index === route.length - 4 ? 'door' : 'stairs',
    })),
  });
  locomotion = new AnimalLocomotion({ path, speed: walkSpeed });
  if (walkClip) {
    const leftClip = sourceGaits.left;
    const rightClip = sourceGaits.right;
    gaitBlend = new AnimalGaitBlend({
      walk: walkAction,
      left: leftClip ? mixer.clipAction(leftClip) : undefined,
      right: rightClip ? mixer.clipAction(rightClip) : undefined,
      period: walkClip.duration,
      stanceWidth: animal.userData.normalizedSize.x,
      turnCurvature: animalProfile.turnCurvature,
    });
    mixer.update(0);
  }
  placeAnimal();
  window.__arkPreview = {
    animalId: animalProfile.id,
    sourceFiles: ['ark-review.glb', 'noah-review.glb', animalProfile.asset],
    clipNames: animalAsset.animations.map(clip => clip.name),
    normalizedAnimalSize: animal.userData.normalizedSize.toArray(),
    normalizedElephantSize: animalProfile.id === 'elephant' ? animal.userData.normalizedSize.toArray() : undefined,
    normalizationFactor: animal.userData.normalizationFactor,
    walkSpeed,
    previewCameraLocked: true,
    approach: approach.map(value => [value.x, value.y, value.z]),
    approachId: fixture.id,
    groundCurves: planned.curves.map(curve => curve.map(value => [value.x, value.y, value.z])),
    routeValidation: planned.checked,
    routeClearance: planned.clearance,
    gaitEnvelope,
    flightClearance,
    routePlanner: { planGardenApproach, approachFixture },
    locomotion, gaitBlend,
    turnClipsAvailable: gaitBlend ? !gaitBlend.missingTurns.length : false,
    missingTurnClips: gaitBlend?.missingTurns ?? ['left', 'right'],
    locomotionTypes: { AnimalLocomotionPath, AnimalLocomotion, AnimalGaitBlend },
    route: route.map(point => point.toArray()),
    scene, camera, animal,
    elephant: animalProfile.id === 'elephant' ? animal : undefined,
    sheep: animalProfile.id === 'sheep' ? animal : undefined,
  };
  if (!walkClip) {
    status.textContent = `Models loaded. The ${animalProfile.id} needs its exported ${animalProfile.walkName} animation.`;
  } else {
    window.__arkPreview.activeWalkClip = walkClip.name;
    window.__arkPreview.walkDuration = walkClip.duration;
    ready = true;
    startButton.disabled = false;
    status.textContent = gaitBlend.missingTurns.length
      ? `Tap ${animalProfile.id} · real turn clips pending.` : `Tap the ${animalProfile.id} to walk aboard.`;
  }
  requestRender();
} catch (error) {
  console.error('Saved-model preview could not load:', error);
  if (animal) animal.visible = false;
  window.__arkPreviewSetupError = { name: error.name, message: error.message };
  status.textContent = ['GardenRouteError', 'GaitValidationError'].includes(error.name)
    ? error.message : `Waiting for the saved ${animalProfile.id}, Ark, and Noah exports. Reload after export.`;
  requestRender();
}
