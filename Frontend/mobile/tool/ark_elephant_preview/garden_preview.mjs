import * as THREE from 'three';
import { GLTFLoader } from './vendor/loaders/GLTFLoader.js';
import { AnimalGaitBlend } from './animal_locomotion.mjs';
import { selectAnimalGaits, validateAnimalGaitDurations } from './animal_preview_config.mjs';
import { validateGardenCourse, nativeGardenAnimal, gardenAnimalPath, gardenPoseAt, rendererClockTick, gardenRenderDistance, clampGardenPan, gardenView } from './garden_contract.mjs';
import { assetSha256 } from './garden_asset_integrity.mjs';
import { GardenTraffic } from './garden_traffic.mjs';

const canvas = document.querySelector('#view');
const status = document.querySelector('#status');
const message = document.querySelector('#garden-message');
const hosted = new URL(location.href).searchParams.has('host');
document.body.classList.toggle('hosted', hosted);
const scene = new THREE.Scene();
const renderer = new THREE.WebGLRenderer({ canvas, alpha: true, antialias: true });
renderer.setPixelRatio(Math.min(devicePixelRatio || 1, 1.5));
renderer.outputColorSpace = THREE.SRGBColorSpace;
renderer.toneMapping = THREE.ACESFilmicToneMapping;
renderer.toneMappingExposure = 1.1;
renderer.shadowMap.enabled = true;
renderer.shadowMap.type = THREE.PCFSoftShadowMap;
const camera = new THREE.OrthographicCamera(-20, 20, 9, -9, .1, 220);
const center = new THREE.Vector3(gardenView.center.x,gardenView.center.y,gardenView.center.z);
const offset = new THREE.Vector3(gardenView.offset.x,gardenView.offset.y,gardenView.offset.z);
const viewRight = new THREE.Vector3(offset.z, 0, -offset.x).normalize();
scene.add(new THREE.HemisphereLight(0xd7edff, 0x7c8754, 2.1));
const sun = new THREE.DirectionalLight(0xfff0d0, 3);
sun.position.set(-10, 18, 12);
sun.castShadow = true;
sun.shadow.mapSize.set(1024, 1024);
Object.assign(sun.shadow.camera, { left: -28, right: 28, top: 30, bottom: -24, near: 1, far: 90 });
sun.shadow.bias = -.0008; sun.shadow.normalBias = .03;
scene.add(sun);
const floor = new THREE.Mesh(new THREE.PlaneGeometry(100,100), new THREE.ShadowMaterial({ color: 0x24372a, opacity: .22 }));
floor.rotation.x = -Math.PI / 2; floor.receiveShadow = true;
scene.add(floor);
const loader = new GLTFLoader();
let config, actors = [], fixedModels = [], backdrop, pan = 0, ready = false, disposed = false;
let framePending = false, frameHandle, previousRenderTick;
let state = { tick: 0, renderTick: 0, taps: {}, paused: true };
let stateAt = performance.now(), localStartedAt, localPauseAt, localPausedTime = 0;
let localClockHandle, generation = 0;
let fromDistances = {};
let localTraffic;
const emittedEntered = new Set();
const pendingNativeAssets = new Set();

function emit(type, fields = {}) {
  const payload = JSON.stringify({ type, ...fields });
  if (window.KingdomArkBridge?.postMessage) window.KingdomArkBridge.postMessage(payload);
  window.dispatchEvent(new CustomEvent('kingdom-ark-event', { detail: JSON.parse(payload) }));
}

function prepareClip(source) {
  if (!source) return undefined;
  const clip = source.clone();
  const first = Math.min(...clip.tracks.map(track => track.times[0]));
  for (const track of clip.tracks) for (let i = 0; i < track.times.length; i++) track.times[i] -= first;
  return clip.resetDuration();
}

function prepareMeshes(asset) {
  const remove = [];
  asset.traverse(object => {
    if (object.isCamera || object.isLight || object.name.replace(/[ _]/g, '').toLowerCase() === 'animalreviewground') remove.push(object);
    if (!object.isMesh) return;
    object.castShadow = true; object.receiveShadow = true;
    for (const material of Array.isArray(object.material) ? object.material : [object.material]) if (material) material.envMapIntensity = .45;
  });
  remove.forEach(object => object.removeFromParent());
}

function posedBounds(asset) {
  asset.updateMatrixWorld(true);
  asset.traverse(object => { if (object.isSkinnedMesh) { object.skeleton.update(); object.computeBoundingBox(); object.computeBoundingSphere(); } });
  return new THREE.Box3().setFromObject(asset);
}

function normalize(asset, height, excludeStaff = false) {
  asset.updateMatrixWorld(true);
  const box = new THREE.Box3();
  asset.traverse(object => { if (object.isMesh && !(excludeStaff && /staff/i.test(object.name))) box.union(new THREE.Box3().setFromObject(object)); });
  const size = box.getSize(new THREE.Vector3()), middle = box.getCenter(new THREE.Vector3());
  if (![size.x,size.y,size.z].every(value => Number.isFinite(value) && value > 0)) throw new Error('A saved model has invalid posed dimensions.');
  const factor = height / size.y;
  const normalizer = new THREE.Group(); normalizer.add(asset); normalizer.scale.setScalar(factor);
  normalizer.position.set(-middle.x * factor, -box.min.y * factor, -middle.z * factor);
  const root = new THREE.Group(); root.add(normalizer);
  root.userData = { factor, dimensions: size.clone().multiplyScalar(factor) };
  return root;
}

async function loadAsset(filename, expectedHash) {
  const response = await fetch(`./assets/${filename}`, { cache: 'no-store' });
  if (!response.ok) throw new Error(`The saved ${filename.replace('-review.glb','')} model is unavailable.`);
  const bytes = await response.arrayBuffer();
  if (expectedHash && await assetSha256(bytes) !== expectedHash) throw new Error('The course and native model exports do not match. Rebuild the course before playing.');
  return loader.parseAsync(bytes, new URL('./assets/', location.href).href);
}

function updateCamera() {
  pan = clampGardenPan(pan, camera.right);
  const target = center.clone().addScaledVector(viewRight, pan);
  camera.position.copy(target).add(offset); camera.lookAt(target);
  // Ark, Noah, animals, and the panorama stay in the same world. Panning only
  // moves the viewpoint; it never edits any model or independently drags art.
}

function resize() {
  if(disposed)return;
  const width = canvas.clientWidth, height = canvas.clientHeight;
  renderer.setSize(width, height, false);
  const halfHeight = gardenView.halfHeight, aspect = width / Math.max(1,height);
  camera.left = -halfHeight * aspect; camera.right = halfHeight * aspect;
  camera.top = halfHeight; camera.bottom = -halfHeight;
  camera.updateProjectionMatrix(); updateCamera(); requestRender();
}

function requestRender() {
  if (framePending || disposed || document.hidden) return;
  framePending = true; frameHandle = requestAnimationFrame(renderFrame);
}

function acceptState(next) {
  if (!config || !next || !Number.isInteger(next.tick) || next.tick < 0
    || !Number.isFinite(next.renderTick ?? next.tick) || !next.taps || typeof next.taps !== 'object') throw new Error('The host sent an invalid garden state.');
  for (const [id, tick] of Object.entries(next.taps)) if (!actors.some(actor => actor.data.id === id) || !Number.isInteger(tick) || tick < 0 || tick > next.tick) throw new Error('The host sent an invalid animal tap.');
  if (next.distances) for (const actor of actors) {
    const distance = next.distances[actor.data.id];
    if (!Number.isFinite(distance) || distance < 0 || distance > actor.path.length + 1e-6) throw new Error('The host sent an invalid movement distance.');
  }
  fromDistances = Object.fromEntries(actors.map(actor=>[actor.data.id,actor.pose?.travelled ?? 0]));
  state = { ...next, renderTick: next.renderTick ?? next.tick };
  stateAt = performance.now(); requestRender();
}

function renderFrame(now) {
  if(disposed)return;
  framePending = false;
  const newlyEntered = [];
  const tick = rendererClockTick(state, Math.max(0,(now - stateAt)/1000));
  const delta = previousRenderTick === undefined ? 0 : Math.max(0, Math.min(.2,(tick - previousRenderTick)*.1));
  previousRenderTick = tick;
  for (const actor of actors) {
    const id = actor.data.id;
    const distance = state.distances ? gardenRenderDistance(fromDistances[id],state.distances[id],Math.max(0,(now-stateAt)/1000),state.paused) : undefined;
    const at = gardenPoseAt(actor.data, actor.path, state.taps[id], tick, distance);
    actor.root.position.set(at.position.x, at.position.y + (actor.data.flight_altitude ?? 0), at.position.z);
    actor.root.rotation.y = at.heading + (actor.data.forward_yaw ?? 0);
    actor.root.visible = !at.arrived;
    const movedSeconds = Math.abs(at.travelled-(actor.pose?.travelled ?? at.travelled))/actor.data.speed_units_per_second;
    const flying=(actor.data.flight_altitude??0)>0;
    actor.gait.steer(at.tapped && movedSeconds>0 ? at.curvature : 0, flying ? delta : state.distances ? movedSeconds : delta);
    // Mixer time is derived from actual root travel, keeping pause, replay,
    // and host state correction in phase with the animal's own native clips.
    const animationSeconds=flying?tick*.1:at.animationSeconds;
    for (const action of Object.values(actor.actions)) if (action) action.time = animationSeconds % action.getClip().duration;
    actor.mixer.update(0);
    actor.pose = at;
    if (at.arrived && !emittedEntered.has(actor.data.id)) {
      newlyEntered.push(actor.data.id);
    }
  }
  if (!hosted && config) updateLocalHud();
  renderer.render(scene, camera);
  // The host may show the result only after the final boarding frame draws.
  // A failed render must leave arrivals unacknowledged for a safe retry.
  for (const id of newlyEntered) {
    emittedEntered.add(id);
    emit('animalEntered', { id, visualOnly: true });
  }
  if (!state.paused && now - stateAt < 100) requestRender();
}

async function configure(payload) {
  const course = validateGardenCourse(payload.config ?? payload);
  const token = ++generation;
  ready = false; status.textContent = 'Loading the ten saved animal models…';
  clearModels(); config = course;
  try {
    const manifestResponse = await fetch('./garden_native_assets.json',{cache:'no-store'});
    if (!manifestResponse.ok) throw new Error('The checked native animal manifest is not ready yet.');
    const manifest = await manifestResponse.json();
    if (!/^[a-f0-9]{64}$/.test(manifest.ark_sha256 ?? '') || !/^[a-f0-9]{64}$/.test(manifest.noah_sha256 ?? '')) throw new Error('The saved Ark and Noah need their checked export manifest.');
    const loaded = await Promise.allSettled([loadAsset('ark-review.glb', manifest.ark_sha256), loadAsset('noah-review.glb', manifest.noah_sha256)]);
    if(loaded.some(result=>result.status==='rejected')) {
      disposeNativeModels(loaded.filter(result=>result.status==='fulfilled').map(result=>result.value.scene));
      throw loaded.find(result=>result.status==='rejected').reason;
    }
    const [ark,noah] = loaded.map(result=>result.value);
    if (token !== generation || disposed) {disposeNativeModels([ark.scene,noah.scene]);return;}
    prepareMeshes(ark.scene); prepareMeshes(noah.scene);
    noah.scene.traverse(object => {
      if (!object.isMesh) return;
      for (const material of Array.isArray(object.material) ? object.material : [object.material]) {
        if (material?.name.replace(/_/g,' ').toLowerCase() === 'deep grape woven outer robe') material.color.setRGB(.18,.07,.27);
      }
    });
    const noahRoot = normalize(noah.scene,1.8,true); noahRoot.position.set(-2.7,0,9.3);
    fixedModels = [ark.scene,noahRoot]; fixedModels.forEach(model => scene.add(model));
    // Limit simultaneous parsers to reduce WebView peak memory on the phone.
    for (const courseAnimal of course.garden.animals) {
      const data = nativeGardenAnimal(courseAnimal,manifest);
      const asset = await loadAsset(data.asset,data.asset_sha256);
      if (token !== generation || disposed) {disposeNativeModels([asset.scene]);return;}
      pendingNativeAssets.add(asset.scene);
      prepareMeshes(asset.scene);
      const profile = { label:data.label, walkName:data.clips.walk, turnNames:{left:data.clips.left,right:data.clips.right}, expectedGaitDuration:data.gait_duration };
      const gaits = Object.fromEntries(Object.entries(selectAnimalGaits(asset.animations,profile)).map(([key,clip])=>[key,prepareClip(clip)]));
      if (!gaits.walk || !gaits.left || !gaits.right) throw new Error(`${data.label} needs its own saved walking and both turning animations.`);
      validateAnimalGaitDurations(gaits,profile);
      const mixer = new THREE.AnimationMixer(asset.scene);
      const actions = Object.fromEntries(Object.entries(gaits).map(([key,clip])=>[key,mixer.clipAction(clip)]));
      actions.walk.reset().play(); mixer.update(0);
      posedBounds(asset.scene);
      const root = normalize(asset.scene,data.height_units);
      if (Math.abs(root.userData.factor - data.normalization_factor) > 1e-5) throw new Error(`${data.label}'s saved pose does not match the checked course scale.`);
      const gait = new AnimalGaitBlend({ ...actions,period:gaits.walk.duration,stanceWidth:root.userData.dimensions.x,turnCurvature:data.turn_curvature });
      const actor = { data, root, mixer, actions, gait, path:gardenAnimalPath(data) };
      actors.push(actor); scene.add(root);pendingNativeAssets.delete(asset.scene);
      status.textContent = `${actors.length} / 10 animals ready…`;
    }
    const texture = await new THREE.TextureLoader().loadAsync('./assets/garden.png');
    texture.colorSpace = THREE.SRGBColorSpace;
    if (token !== generation || disposed) { texture.dispose(); return; }
    backdrop = new THREE.Mesh(new THREE.PlaneGeometry(70,70*texture.image.height/texture.image.width),new THREE.MeshBasicMaterial({map:texture,depthWrite:false,toneMapped:false}));
    updateCamera(); backdrop.quaternion.copy(camera.quaternion);
    backdrop.position.copy(center).addScaledVector(offset.clone().normalize(),-80);
    backdrop.renderOrder = -1; scene.add(backdrop);
    ready = true; emittedEntered.clear(); previousRenderTick = undefined;
    acceptState({tick:0,renderTick:0,taps:{},paused:true});
    addAccessibleAnimals(); document.querySelector('#start').disabled = false;
    status.textContent = 'Swipe to find the animals, then tap them to help them aboard.';
    window.__arkGardenPreview = { config,actors,scene,camera,fixedModels,backdrop,viewRight,sourceFiles:['ark-review.glb','noah-review.glb',...actors.map(actor=>actor.data.asset)] };
    emit('ready',{ animalIds:actors.map(actor=>actor.data.id),version:2 });
  } catch (error) {
    if (token !== generation) return;
    ready = false; clearModels(); status.textContent = error.message;
    emit('failure',{message:error.message}); requestRender(); throw error;
  }
}

function disposeNativeModels(roots) {
  const geometries = new Set(),materials = new Set(),textures = new Set(),skeletons = new Set(),images = new Set();
  for (const root of roots) root.traverse(object=>{
    if (!object.isMesh) return;
    if(object.isSkinnedMesh&&object.skeleton)skeletons.add(object.skeleton);
    if (object.geometry) geometries.add(object.geometry);
    for (const material of Array.isArray(object.material) ? object.material : [object.material]) {
      if (!material) continue;
      materials.add(material);
      for (const value of Object.values(material)) if (value?.isTexture) textures.add(value);
    }
  });
  geometries.forEach(geometry=>geometry.dispose());
  textures.forEach(texture=>{texture.dispose();const image=texture.source?.data;if(typeof image?.close==='function')images.add(image);});
  images.forEach(image=>image.close());skeletons.forEach(skeleton=>skeleton.dispose());
  materials.forEach(material=>material.dispose());
}

function clearModels() {
  disposeNativeModels([...actors.map(actor=>actor.root),...fixedModels,...pendingNativeAssets]);
  pendingNativeAssets.clear();
  for (const actor of actors) { actor.mixer.stopAllAction(); actor.mixer.uncacheRoot(actor.mixer.getRoot()); actor.root.removeFromParent(); }
  fixedModels.forEach(model=>model.removeFromParent());
  if (backdrop) { backdrop.removeFromParent(); backdrop.geometry.dispose(); backdrop.material.map?.dispose(); backdrop.material.dispose(); }
  actors = []; fixedModels = []; backdrop = undefined;
}

function addAccessibleAnimals() {
  const area = document.querySelector('#animal-accessibility'); area.replaceChildren();
  actors.forEach(actor=>{
    const button = document.createElement('button'); button.textContent = `Help ${actor.data.label} aboard`;
    button.addEventListener('click',()=>tapAnimal(actor.data.id)); area.append(button);
  });
}

function tapAnimal(id) {
  if (!ready || state.paused || state.finished || Object.hasOwn(state.taps,id)) return;
  emit('animalTapped',{id});
  if (!hosted) acceptState({...state,taps:{...state.taps,[id]:state.tick}});
}

function localState() {
  if (!localStartedAt || localPauseAt) return;
  const tick = Math.min(config.garden.time_limit_ticks,Math.floor((performance.now()-localStartedAt-localPausedTime)/100));
  const traffic=localTraffic.advanceTo(tick,state.taps);
  const completed=traffic.completed,finished=completed||tick>=config.garden.time_limit_ticks;
  acceptState({...state,...traffic,renderTick:tick,paused:false,finished,completed});
  if (finished) clearInterval(localClockHandle);
}

function start() {
  if (!ready) return;
  if (!hosted) {
    localStartedAt = performance.now(); localPausedTime = 0; localPauseAt = undefined;
    localTraffic=new GardenTraffic(config.garden.animals);
    acceptState({tick:0,renderTick:0,taps:{},distances:localTraffic.snapshot().distances,paused:false});
    clearInterval(localClockHandle); localClockHandle = setInterval(localState,100);
    document.querySelector('#start').disabled = true; document.querySelector('#pause').disabled = false;
  }
  emit('start');
}

function pause(paused = true) {
  if (!ready) return;
  if (!hosted) {
    if (paused && !localPauseAt) localPauseAt = performance.now();
    else if (!paused && localPauseAt) { localPausedTime += performance.now()-localPauseAt; localPauseAt = undefined; }
  }
  acceptState({...state,paused}); previousRenderTick = undefined;
}

function replay() {
  clearInterval(localClockHandle); localStartedAt = undefined; localPauseAt = undefined;
  localTraffic=undefined;
  emittedEntered.clear(); previousRenderTick = undefined;
  actors.forEach(actor=>actor.gait.reset());
  acceptState({tick:0,renderTick:0,taps:{},paused:true});
  document.querySelector('#start').disabled = false; document.querySelector('#pause').disabled = true;
  document.querySelector('#replay').disabled = true; message.hidden = true;
}

function updateLocalHud() {
  const count = actors.filter(actor=>actor.pose?.arrived).length;
  document.querySelector('#count').textContent = `${count} / 10 aboard`;
  const seconds = Math.max(0,Math.ceil((config.garden.time_limit_ticks-state.renderTick)*.1));
  document.querySelector('#clock').textContent = `${Math.floor(seconds/60)}:${String(seconds%60).padStart(2,'0')}`;
  document.querySelector('#pause').textContent = state.paused ? 'Resume' : 'Pause';
  if (state.finished && (!state.completed || count===10)) {
    message.hidden = false; message.textContent = state.completed ? 'All ten animals are safely aboard!' : 'Time is up. Let’s help the animals again!';
    document.querySelector('#replay').disabled = false; document.querySelector('#pause').disabled = true;
  }
}

const raycaster = new THREE.Raycaster();
let pointer;
function canvasPoint(event) {
  const bounds = canvas.getBoundingClientRect(); const x = event.clientX-bounds.left,y=event.clientY-bounds.top;
  return !hosted && matchMedia('(orientation: portrait)').matches
    ? {x:y/bounds.height*canvas.clientWidth,y:(1-x/bounds.width)*canvas.clientHeight}
    : {x:x/bounds.width*canvas.clientWidth,y:y/bounds.height*canvas.clientHeight};
}
canvas.addEventListener('pointerdown',event=>{
  const point = canvasPoint(event); pointer = {id:event.pointerId,start:point,last:point,dragged:false}; canvas.setPointerCapture(event.pointerId);
});
canvas.addEventListener('pointermove',event=>{
  if (!pointer || pointer.id !== event.pointerId) return;
  const at = canvasPoint(event);
  if (Math.hypot(at.x-pointer.start.x,at.y-pointer.start.y)>10) pointer.dragged = true;
  if (pointer.dragged) { pan -= (at.x-pointer.last.x)/canvas.clientWidth*(camera.right-camera.left); updateCamera(); requestRender(); }
  pointer.last = at;
});
canvas.addEventListener('pointerup',event=>{
  if (!pointer || pointer.id !== event.pointerId) return;
  if (!pointer.dragged && ready) {
    const at = canvasPoint(event); raycaster.setFromCamera(new THREE.Vector2(at.x/canvas.clientWidth*2-1,-at.y/canvas.clientHeight*2+1),camera);
    const hit = raycaster.intersectObjects(actors.filter(actor=>actor.root.visible).map(actor=>actor.root),true)[0];
    let actor = hit && actors.find(candidate=>{let object=hit.object;while(object){if(object===candidate.root)return true;object=object.parent;}return false;});
    // Small real species remain small relative to Noah. A minimum44px touch
    // area makes the rabbit/dove usable without distorting their model scale.
    if(!actor) {
      let nearest=22;
      for(const candidate of actors) {
        if(!candidate.root.visible||Object.hasOwn(state.taps,candidate.data.id))continue;
        const center=candidate.root.position.clone();center.y+=candidate.data.height_units/2;
        center.project(camera);
        if(center.z<-1||center.z>1)continue;
        const x=(center.x+1)*canvas.clientWidth/2,y=(1-center.y)*canvas.clientHeight/2;
        const distance=Math.hypot(at.x-x,at.y-y);
        if(distance<nearest){nearest=distance;actor=candidate;}
      }
    }
    if (actor) tapAnimal(actor.data.id);
  }
  pointer = undefined;
});
canvas.addEventListener('pointercancel',()=>{pointer=undefined;});
document.querySelector('#start').addEventListener('click',start);
document.querySelector('#pause').addEventListener('click',()=>pause(!state.paused));
document.querySelector('#replay').addEventListener('click',replay);
document.querySelector('#center').addEventListener('click',()=>{pan=0;updateCamera();requestRender();});
window.addEventListener('resize',resize);
document.addEventListener('visibilitychange',()=>{
  if (document.hidden) { pause(true); emit('pause',{reason:'background'}); }
  else { previousRenderTick = undefined; requestRender(); }
});
canvas.addEventListener('webglcontextlost',event=>{event.preventDefault();pause(true);ready=false;clearInterval(localClockHandle);emit('failure',{message:'The 3D view stopped. Reopen the game to reload its models.'});});
function dispose() {
  disposed = true; ready=false; generation++; clearInterval(localClockHandle); cancelAnimationFrame(frameHandle);
  clearModels();floor.geometry.dispose();floor.material.dispose();sun.shadow.map?.dispose();sun.shadow.mapPass?.dispose();renderer.dispose();
}
window.KingdomArkGarden = {configure,start,pause,state:acceptState,replay,dispose};
resize(); emit('bridgeReady',{version:2});
if (!hosted) {
  try { const response=await fetch('./garden_course_v2.json',{cache:'no-store'});if(!response.ok)throw new Error('The complete ten-animal course is not ready yet.');await configure(await response.json()); }
  catch(error) {status.textContent=error.message;}
}
