import test from 'node:test';
import assert from 'node:assert/strict';
import { animalPreviewProfile, selectAnimalGaits, animalPreviewHeight, animalPreviewSpeed, animalFlightClearance } from './animal_preview_config.mjs';
import { AnimalLocomotionPath, AnimalLocomotion, AnimalGaitBlend } from './animal_locomotion.mjs';

test('only allowlisted animal queries change the default saved animal', () => {
  const elephant = animalPreviewProfile();
  assert.equal(elephant.asset, 'elephant-review.glb');
  for (const request of ['elephant', 'lion', '../sheep', '../zebra', '__proto__', 'constructor', null, 'Sheep']) {
    assert.equal(animalPreviewProfile(request), elephant);
  }
  assert.equal(animalPreviewProfile('sheep').asset, 'sheep-review.glb');
  for (const id of ['zebra', 'donkey', 'deer', 'rabbit', 'dove']) assert.equal(animalPreviewProfile(id).asset, `${id}-review.glb`);
});

test('dove selects its own flap and native bank clips, with flight speed and whole-wing stair clearance', () => {
  const profile = animalPreviewProfile('dove');
  const own = { walk: { name: 'flap-wings-animation' }, left: { name: 'DoveTurnLeft' }, right: { name: 'DoveTurnRight' } };
  assert.deepEqual(selectAnimalGaits([{ name: 'idle-animation' }, { name: 'legs-up-animation' }, ...Object.values(own)], profile), own);
  assert.equal(animalPreviewSpeed(profile, 2.3142), 1.2);
  const bounds = { length: 1.076919002270623, minY: -.1574226095704321, maxY: .8922048402162865 };
  const clearance = animalFlightClearance(profile, bounds);
  assert.ok(clearance.lowestAboveSteps >= .08 && clearance.highestAboveDeck < 4.12);
  assert.throws(() => animalFlightClearance({ ...profile, flightAltitude: .65 }, bounds), /more clearance/);
  assert.equal(animalFlightClearance(animalPreviewProfile('sheep'), bounds), undefined);
});

test('forthcoming animals require their intentional source gait and only their own turn names', () => {
  for (const [id, walkName, height, pace] of [
    ['zebra', 'WalkSlow', 3.0, 2.44938],
    ['donkey', 'Walk', 1.9, 2.8305732],
    ['deer', 'Walk', 2.1, 2.8305732],
    ['rabbit', 'Running', .9, 19.707256],
  ]) {
    const profile = animalPreviewProfile(id);
    const wrongWalk = { name: walkName === 'Walk' ? 'WalkSlow' : 'Walk' };
    const otherTurns = ['Elephant', 'Sheep', 'Zebra', 'Donkey', 'Deer', 'Rabbit']
      .filter(label => label !== profile.label)
      .flatMap(label => [{ name: `${label}TurnLeft` }, { name: `${label}TurnRight` }]);
    assert.deepEqual(selectAnimalGaits([wrongWalk, ...otherTurns], profile), {
      walk: undefined, left: undefined, right: undefined,
    });
    const own = {
      walk: { name: `${profile.label}Rig|${walkName}` },
      left: { name: `${profile.label}TurnLeft` },
      right: { name: `${profile.label}TurnRight` },
    };
    assert.deepEqual(selectAnimalGaits([...otherTurns, ...Object.values(own)], profile), own);
    assert.equal(animalPreviewHeight(profile, { x: 1, y: 4, z: 5 }), height);
    assert.equal(animalPreviewSpeed(profile, .3), pace * .3);
    assert.throws(() => animalPreviewHeight(profile, { x: 10, y: 1, z: 5 }), /too wide/);
  }
});

test('sheep selects its own slow gait and never accepts elephant or other source gaits', () => {
  const sheep = animalPreviewProfile('sheep');
  const unrelated = ['Idle', 'Walk', 'Run', 'Elephant_RigAction', 'ElephantTurnLeft', 'ElephantTurnRight'].map(name => ({ name }));
  assert.deepEqual(selectAnimalGaits(unrelated, sheep), { walk: undefined, left: undefined, right: undefined });
  const ownWalk = { name: 'SheepArmature|WalkSlow' };
  const ownLeft = { name: 'SheepTurnLeft' };
  const ownRight = { name: 'SheepTurnRight' };
  assert.deepEqual(selectAnimalGaits([...unrelated, ownWalk, ownLeft, ownRight], sheep), {
    walk: ownWalk, left: ownLeft, right: ownRight,
  });
  const elephantWalk = { name: 'Elephant_RigAction' };
  assert.equal(selectAnimalGaits([{ name: 'Walk' }, elephantWalk], animalPreviewProfile()).walk, elephantWalk);
});

test('each animal retains independent posed size and measured source stride', () => {
  const elephant = animalPreviewProfile();
  const sheep = animalPreviewProfile('sheep');
  const sheepHeight = animalPreviewHeight(sheep, { x: 2, y: 4, z: 5 });
  assert.equal(sheepHeight, 1.4);
  assert.ok(sheepHeight < 1.8);
  assert.equal(animalPreviewHeight(elephant, { x: 2, y: 4, z: 5 }), 3.3);
  assert.equal(animalPreviewHeight(elephant, { x: 4, y: 4, z: 5 }), 2.5);
  assert.throws(() => animalPreviewHeight(sheep, { x: 10, y: 1, z: 5 }), /too wide/);
  assert.throws(() => animalPreviewHeight(sheep, { x: 0, y: 1, z: 5 }), /dimensions/);
  assert.equal(animalPreviewSpeed(elephant, .5), .3);
  assert.equal(animalPreviewSpeed(sheep, .5), 1.22469);
  assert.throws(() => animalPreviewSpeed(sheep, NaN), /positive/);
});

test('missing sheep turn clips preserve straight gait phase while shared motion follows the curve and fully boards', () => {
  const path = new AnimalLocomotionPath({
    approach: [
      { x: 4, y: 0, z: 12 }, { x: 3, y: 0, z: 12.55 },
      { x: 2, y: 0, z: 13.1 }, { x: 0, y: 0, z: 12.5 },
      { x: 0, y: 0, z: 11 }, { x: 0, y: 0, z: 9.5 },
    ],
    tail: [
      { x: 0, y: .33, z: 9, phase: 'stairs' },
      { x: 0, y: 4.3, z: 2.5, phase: 'door' },
      { x: 0, y: 4.3, z: -1, phase: 'interior' },
    ],
  });
  const speed = animalPreviewSpeed(animalPreviewProfile('sheep'), .2);
  const movement = new AnimalLocomotion({ path, speed });
  const action = {
    resets: 0, getClip: () => ({ duration: 2 }),
    reset() { this.resets++; return this; }, play() { return this; },
    setEffectiveTimeScale() { return this; }, setEffectiveWeight(value) { this.weight = value; return this; },
  };
  const blend = new AnimalGaitBlend({ walk: action, period: 2, stanceWidth: .8 });
  assert.deepEqual(blend.missingTurns, ['left', 'right']);
  const initialHeading = movement.heading;
  movement.start(); movement.advance(0);
  assert.equal(movement.heading, initialHeading);
  let previousHeading = movement.heading;
  for (let frame = 0; !movement.frame.arrived && frame < 20000; frame++) {
    const at = movement.advance(.01);
    blend.steer(at.curvature, .01);
    assert.ok(Math.abs(movement.heading - previousHeading) < .03);
    assert.equal(action.weight, 1);
    previousHeading = movement.heading;
  }
  assert.equal(movement.frame.arrived, true);
  assert.deepEqual(movement.frame.position, { x: 0, y: 4.3, z: -1 });
  assert.equal(action.resets, 1);
  movement.reset();
  assert.equal(movement.heading, initialHeading);
});
