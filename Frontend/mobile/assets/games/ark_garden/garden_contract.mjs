import { AnimalLocomotionPath } from './animal_locomotion.mjs';

export const gardenAnimalIds = Object.freeze([
  'elephant', 'sheep', 'zebra', 'donkey', 'deer', 'rabbit', 'dove', 'lion', 'camel', 'giraffe',
]);
export const gardenOrigin = Object.freeze({ x: 23, z: 3.5 });
export const gardenView = Object.freeze({ center:{x:0,y:4,z:7},offset:{x:7,y:8,z:30},halfHeight:9.5,panoramaWidth:70 });

export function fromCoursePoint(value) {
  if (!value || !['x', 'y', 'z'].every(key => Number.isFinite(value[key]))) throw new Error('A garden route needs finite coordinates.');
  return { x: value.x - gardenOrigin.x, y: value.z, z: value.y - gardenOrigin.z };
}

export function toCoursePoint(value) {
  return { x: value.x + gardenOrigin.x, y: value.z + gardenOrigin.z, z: value.y };
}

export function gardenAnimalPath(animal) {
  const curves = animal.approach_curves?.map(curve => curve.map(fromCoursePoint));
  if (!curves?.length || !animal.route?.length || !Number.isFinite(animal.speed_units_per_second) || animal.speed_units_per_second <= 0) {
    throw new Error('Every animal needs its own native pace and complete curved boarding route.');
  }
  const route = animal.route.map(fromCoursePoint);
  if (Math.hypot(route[0].x - curves[0][0].x, route[0].z - curves[0][0].z) > 1e-6
    || Math.hypot(route[1].x - curves.at(-1).at(-1).x, route[1].z - curves.at(-1).at(-1).z) > 1e-6) {
    throw new Error('The curved garden route and staircase must share their endpoints.');
  }
  const path = new AnimalLocomotionPath({ curves, samples: 256, tail: route.slice(2).map((point, index) => ({
    ...point, phase: index === route.length - 3 ? 'interior' : index === route.length - 4 ? 'door' : 'stairs',
  })) });
  return path;
}

export function validateGardenCourse(config) {
  const garden = config?.garden;
  if (config?.mode !== 'ark_garden' || garden?.version !== 2 || garden.tick_ms !== 100
    || !Number.isInteger(garden.time_limit_ticks) || garden.time_limit_ticks < 100 || garden.time_limit_ticks > 6000
    || garden.world?.width !== 46 || garden.world?.height !== 33.5
    || !Array.isArray(garden.animals) || garden.animals.length !== gardenAnimalIds.length) {
    throw new Error('The garden requires the complete ten-animal version-two course.');
  }
  const seen = new Set();
  for (const animal of garden.animals) {
    if (!gardenAnimalIds.includes(animal.species) || seen.has(animal.id) || animal.id !== animal.species
      || !Number.isFinite(animal.body_width_units) || animal.body_width_units <= 0
      || !Number.isFinite(animal.body_length_units) || animal.body_length_units <= 0
      || !Number.isFinite(animal.body_rear_units) || animal.body_rear_units <= 0 || animal.body_rear_units >= animal.body_length_units) {
      throw new Error('The course must reference ten distinct animals with checked body dimensions.');
    }
    const path = gardenAnimalPath(animal);
    const maxGate=Math.max(0,path.approachLength-(animal.body_length_units-animal.body_rear_units)-.06);
    if(!Number.isFinite(animal.queue_gate_distance_units)||animal.queue_gate_distance_units<0||animal.queue_gate_distance_units>maxGate+1e-7)throw new Error('An animal’s queue gate must remain before the shared stairs.');
    if (path.length / animal.speed_units_per_second > garden.time_limit_ticks * .1) throw new Error(`${animal.label} cannot reach the Ark before the configured timer expires.`);
    seen.add(animal.id);
  }
  return config;
}

export function nativeGardenAnimal(animal, manifest) {
  const native = manifest?.animals?.[animal.species];
  if (!native || native.asset !== `${animal.species}-review.glb`
    || !/^[a-f0-9]{64}$/.test(native.asset_sha256 ?? '')
    || !Number.isFinite(native.height_units) || native.height_units <= 0
    || !Number.isFinite(native.normalization_factor) || native.normalization_factor <= 0
    || !native.gait_envelope || !Number.isFinite(native.gait_envelope.width)
    || !Number.isFinite(native.gait_envelope.length)
    || !native.clips?.walk || !native.clips?.left || !native.clips?.right
    || Math.abs(animal.speed_units_per_second - native.speed_units_per_second) > 1e-7
    || animal.body_width_units < native.gait_envelope.width - 1e-7
    || animal.body_length_units < native.gait_envelope.length - 1e-7
    || Math.abs(animal.body_rear_units + native.gait_envelope.straight.minZ) > 1e-7) {
    throw new Error('The gameplay course must match each animal’s checked native export and gait.');
  }
  return { ...native, ...animal };
}

/** A renderer samples the host's clock; it never submits or awards completion. */
export function gardenPoseAt(animal, path, tapTick, renderTick, distanceUnits) {
  if (!Number.isFinite(renderTick) || renderTick < 0) throw new Error('The garden render clock must be finite.');
  const tapped = Number.isFinite(tapTick) && tapTick >= 0 && tapTick <= renderTick;
  const elapsed = tapped ? (renderTick - tapTick) * .1 : 0;
  if (distanceUnits !== undefined && (!Number.isFinite(distanceUnits) || distanceUnits < 0)) throw new Error('Host movement distance must be finite and nonnegative.');
  const travelled = tapped ? Math.min(path.length, distanceUnits ?? elapsed * animal.speed_units_per_second) : 0;
  return { ...path.sample(travelled), travelled, elapsed, tapped,
    animationSeconds: travelled / animal.speed_units_per_second };
}

export function rendererClockTick(state, elapsedSeconds) {
  if (!Number.isFinite(state.tick) || !Number.isFinite(state.renderTick ?? state.tick) || !Number.isFinite(elapsedSeconds) || elapsedSeconds < 0) throw new Error('The host clock needs finite values.');
  const base = state.renderTick ?? state.tick;
  // No more than one authoritative tenth-second is predicted. A backgrounded
  // WebView or stalled host cannot silently keep the game advancing.
  return base + (state.paused || state.finished ? 0 : Math.min(1, elapsedSeconds * 10));
}

export function gardenRenderDistance(from,to,elapsedSeconds,paused) {
  if(![from,to,elapsedSeconds].every(Number.isFinite)||from<0||to<0||elapsedSeconds<0)throw new Error('Garden distance interpolation needs finite nonnegative values.');
  // Completion uses the same final100ms interpolation as every other tick.
  // An explicit pause holds the current visual pose, without an extra step.
  return paused?from:from+(to-from)*Math.min(1,elapsedSeconds/.1);
}

export function clampGardenPan(value, visibleHalfWidth, panoramaHalfWidth = 35) {
  if (![value, visibleHalfWidth, panoramaHalfWidth].every(Number.isFinite) || visibleHalfWidth <= 0 || panoramaHalfWidth <= 0) throw new Error('Garden panning needs finite view dimensions.');
  const limit = Math.max(0, panoramaHalfWidth - visibleHalfWidth);
  return Math.max(-limit, Math.min(limit, value));
}
