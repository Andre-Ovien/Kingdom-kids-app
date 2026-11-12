// This allowlist belongs only to the saved-model development scene.
// Production garden configuration and completion rules are independent.
const profiles = {
  elephant: Object.freeze({
    id: 'elephant', label: 'Elephant', asset: 'elephant-review.glb',
    walkName: 'Elephant_RigAction', legacyWalkPattern: /walk|stride|gait/i,
    turnNames: Object.freeze({ left: 'ElephantTurnLeft', right: 'ElephantTurnRight' }),
    height: 3.3, narrowerHeight: 3.0, maxWidth: 2.5, forwardYaw: 0,
    // Reviewed stance travel .9 source-world units over 1.5 seconds.
    sourceStanceSpeed: .9 / 1.5,
  }),
  sheep: Object.freeze({
    id: 'sheep', label: 'Sheep', asset: 'sheep-review.glb',
    walkName: 'WalkSlow',
    turnNames: Object.freeze({ left: 'SheepTurnLeft', right: 'SheepTurnRight' }),
    height: 1.4, maxWidth: 2.5, forwardYaw: 0,
    // Mean of the four audited grounded WalkSlow stances. Front/rear stride
    // lengths differ in the source, so a single speed is an approximation.
    sourceStanceSpeed: 2.44938,
  }),
  // These profiles prepare review loading only. Their provisional heights
  // need posed-dimension/clearance checks against the actual native exports.
  zebra: Object.freeze({
    id: 'zebra', label: 'Zebra', asset: 'zebra-review.glb',
    walkName: 'WalkSlow',
    turnNames: Object.freeze({ left: 'ZebraTurnLeft', right: 'ZebraTurnRight' }),
    height: 3.0, maxWidth: 2.5, forwardYaw: 0,
    sourceStanceSpeed: 2.44938,
    expectedGaitDuration: 2,
  }),
  donkey: Object.freeze({
    id: 'donkey', label: 'Donkey', asset: 'donkey-review.glb',
    walkName: 'Walk',
    turnNames: Object.freeze({ left: 'DonkeyTurnLeft', right: 'DonkeyTurnRight' }),
    height: 1.9, maxWidth: 2.5, forwardYaw: 0,
    sourceStanceSpeed: 2.8305732,
    expectedGaitDuration: 35 / 30,
  }),
  deer: Object.freeze({
    id: 'deer', label: 'Deer', asset: 'deer-review.glb',
    walkName: 'Walk',
    turnNames: Object.freeze({ left: 'DeerTurnLeft', right: 'DeerTurnRight' }),
    height: 2.1, maxWidth: 2.5, forwardYaw: 0,
    sourceStanceSpeed: 2.8305732,
    expectedGaitDuration: 35 / 30,
  }),
  rabbit: Object.freeze({
    id: 'rabbit', label: 'Rabbit', asset: 'rabbit-review.glb',
    walkName: 'Running',
    turnNames: Object.freeze({ left: 'RabbitTurnLeft', right: 'RabbitTurnRight' }),
    height: .9, maxWidth: 2.5, forwardYaw: 0,
    // Mean paired paw longitudinal span over the native .6667-second hop.
    // Front/rear planted speeds differ; this is approximate cycle calibration,
    // not a claim that constant root travel plants both pairs exactly.
    sourceStanceSpeed: 19.707256,
    expectedGaitDuration: 16 / 24,
    // Hop turns use native head/body response, not the hoof rigs' .7/1.3
    // stride alteration. Keep their review arcs broad; this is a tuneable
    // presentation limit, not a contact-physics measurement.
    turnCurvature: .45,
  }),
  dove: Object.freeze({
    id: 'dove', label: 'Dove', asset: 'dove-review.glb',
    walkName: 'flap-wings-animation',
    turnNames: Object.freeze({ left: 'DoveTurnLeft', right: 'DoveTurnRight' }),
    height: .55, maxWidth: 2.5, forwardYaw: 0,
    expectedGaitDuration: 1, locomotion: 'flight',
    flightSpeed: 1.2, flightAltitude: 1, turnCurvature: .6,
  }),
};

export function animalPreviewProfile(requested) {
  return typeof requested === 'string' && Object.hasOwn(profiles, requested)
    ? profiles[requested] : profiles.elephant;
}

function sourceName(clip) {
  // Blender can prefix imported actions with their original armature name.
  return clip.name.split('|').at(-1);
}

export function selectAnimalGaits(animations, profile) {
  return {
    walk: animations.find(clip => sourceName(clip) === profile.walkName)
      ?? (profile.legacyWalkPattern
        ? animations.find(clip => profile.legacyWalkPattern.test(clip.name)) : undefined),
    left: animations.find(clip => sourceName(clip) === profile.turnNames.left),
    right: animations.find(clip => sourceName(clip) === profile.turnNames.right),
  };
}

export function validateAnimalGaitDurations(gaits, profile) {
  for (const clip of Object.values(gaits)) {
    if (!clip) continue;
    if (!Number.isFinite(clip.duration) || clip.duration <= 0
      || (profile.expectedGaitDuration && Math.abs(clip.duration - profile.expectedGaitDuration) > .005)) {
      const error = new Error(`${profile.label} animation ${clip.name} needs the expected matching gait duration.`);
      error.name = 'GaitValidationError';
      throw error;
    }
  }
}

export function animalPreviewHeight(profile, size) {
  if (!['x', 'y', 'z'].every(axis => Number.isFinite(size[axis]) && size[axis] > 0)) {
    throw new Error('The exported animal has invalid posed dimensions.');
  }
  let height = profile.height;
  if (size.x / size.y * height > profile.maxWidth) {
    if (!profile.narrowerHeight) throw new Error('The exported animal is too wide for the reviewed Ark doorway.');
    height = Math.min(profile.narrowerHeight, profile.maxWidth * size.y / size.x);
  }
  return height;
}

export function animalPreviewSpeed(profile, normalizationFactor) {
  if (!Number.isFinite(normalizationFactor) || normalizationFactor <= 0) {
    throw new Error('Animal gait calibration needs a positive figure scale.');
  }
  return profile.locomotion === 'flight' ? profile.flightSpeed : profile.sourceStanceSpeed * normalizationFactor;
}

export function animalFlightClearance(profile, envelope) {
  if (profile.locomotion !== 'flight') return undefined;
  const altitude = profile.flightAltitude;
  if (!envelope || ![altitude, envelope.minY, envelope.maxY, envelope.length].every(Number.isFinite)) throw new Error('Flight needs the actual wing-gait bounds.');
  // Bound the rise under any forward wing/body point across a .33-rise,
  // .5-run staircase, including an extra tread and 8 cm horizontal guard.
  const stairRiseAhead = .33 + .66 * (envelope.length / 2 + .08);
  const lowestAboveSteps = altitude + envelope.minY - stairRiseAhead;
  const highestAboveDeck = altitude + envelope.maxY;
  if (lowestAboveSteps < .08 || highestAboveDeck > 4.2 - .08) {
    const error = new Error('The dove’s wing gait needs more clearance over the stairs or inside the doorway.');
    error.name = 'GaitValidationError'; throw error;
  }
  return { altitude, stairRiseAhead, lowestAboveSteps, highestAboveDeck,
    basis: 'sampled whole-wing envelope and conservative tread/door bounds; visual review required' };
}
