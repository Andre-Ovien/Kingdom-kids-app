import test from 'node:test';
import assert from 'node:assert/strict';
import { AnimalLocomotionPath, angleDelta } from './animal_locomotion.mjs';
import { approachFixture, approvedApproach, gardenPoseIsClear, gardenLayout, planGardenApproach, certifyGardenCurves, interiorEndpoint, GardenRouteError } from './garden_routes.mjs';

const envelopes = {
  elephant: { width: 1.3345108746845664, length: 3.935298185940117 },
  sheep: { width: .8522451457019962, length: 2.8042899619395274 },
  zebra: { width: 1.2102529635241486, length: 4.713985369098897 },
  donkey: { width: .8172927292585683, length: 3.1178774706379735 },
  deer: { width: .8866171153078258, length: 3.0598002079843187 },
  rabbit: { width: .8483650975408961, length: 2.679659861419874, turnCurvature: .45 },
  dove: { width: 1.6596398860016341, length: 1.076919002270623, turnCurvature: .6 },
};
const ids = ['left', 'right', 'far-left', 'far-right', 'center', 'away', 'away-left', 'away-right'];
const tail = [{ x: 0, y: .33, z: 9, phase: 'stairs' }];
const near = (a, b, epsilon = 1e-8) => assert.ok(Math.abs(a - b) <= epsilon, `${a} != ${b}`);

test('approved default controls and original starts remain unchanged', () => {
  const expected = [
    { x: 4, y: 0, z: 12 }, { x: 3, y: 0, z: 12.55 }, { x: 2, y: 0, z: 13.1 },
    { x: 0, y: 0, z: 12.5 }, { x: 0, y: 0, z: 11 }, { x: 0, y: 0, z: 9.5 },
  ];
  assert.equal(JSON.stringify(approvedApproach), JSON.stringify(expected));
  for (const species of ['elephant', 'sheep']) {
    const plan = planGardenApproach({ ...approachFixture('default'), footprint: envelopes[species], preserveApproved: true });
    assert.equal(JSON.stringify(plan.curves), JSON.stringify([expected]));
  }
  assert.throws(() => planGardenApproach({ ...approachFixture('left'), footprint: envelopes.sheep, preserveApproved: true }), GardenRouteError);
});

for (const [species, footprint] of Object.entries(envelopes)) {
  test(`${species} native gait envelope supports both sides, far starts, center, and facing away`, () => {
    for (const id of ids) {
      const fixture = approachFixture(id);
      const plan = planGardenApproach({ ...fixture, footprint, turnCurvature: footprint.turnCurvature });
      const route = new AnimalLocomotionPath({ curves: plan.curves, tail });
      const start = route.sample(0), end = route.curveAt(1, route.curves.length - 1);
      assert.deepEqual(start.position, fixture.start);
      near(angleDelta(start.heading, fixture.heading), 0);
      assert.deepEqual(end.position, { x: 0, y: 0, z: 9.5 });
      near(angleDelta(end.heading, Math.PI), 0); near(end.curvature, 0);
      assert.ok(plan.clearance.maxCurvatureBound <= plan.clearance.maxCurvature);
      for (let i = 0; i < route.curves.length; i++) {
        let previous = route.curveAt(0, i);
        if (i) {
          const before = route.curveAt(1, i - 1);
          near(angleDelta(previous.heading, before.heading), 0);
          near(previous.curvature, before.curvature);
        }
        // Independently corroborate the interval certificate at dense points.
        for (let sample = 1; sample <= 1000; sample++) {
          const at = route.curveAt(sample / 1000, i);
          assert.ok(gardenPoseIsClear(at.position, at.heading, footprint));
          assert.ok(Math.abs(at.curvature) <= plan.clearance.maxCurvature + 1e-8);
          assert.ok(Math.abs(angleDelta(at.heading, previous.heading)) < .05);
          previous = at;
        }
      }
    }
  });
}

test('boundary outward poses are rejected with their heading unchanged', () => {
  const footprint = { width: .8, length: 2 };
  const start = { x: 0, y: 0, z: 25 - footprint.length / 2 - .080001 };
  assert.ok(gardenPoseIsClear(start, 0, footprint));
  assert.throws(() => planGardenApproach({ start, heading: 0, footprint }), /no supported clear forward route/);
  assert.deepEqual(start, { x: 0, y: 0, z: 23.919999 });
  assert.throws(() => planGardenApproach({ start: { x: 30, y: 0, z: 20 }, heading: 0, footprint }), /outside the clear garden/);
});

test('interval screening rejects tiny obstacles and nonzero-curvature limits without a sample-gap assumption', () => {
  const footprint = { width: .01, length: .01 };
  const curve = [{ x: 0, y: 0, z: 16 }, { x: 0, y: 0, z: 14 }, { x: 0, y: 0, z: 12 }, { x: 0, y: 0, z: 10 }];
  const layout = { ...gardenLayout, rails: [], noah: { x: 12, z: 12, radius: .1 },
    ark: { minX: -.0001, maxX: .0001, minZ: 13.0018, maxZ: 13.002 } };
  assert.equal(certifyGardenCurves([curve], footprint, 1, layout), undefined);
  const cusp = [{ x: 0, y: 0, z: 15 }, { x: 0, y: 0, z: 18 }, { x: 0, y: 0, z: 18 }, { x: 0, y: 0, z: 9.5 }];
  assert.equal(certifyGardenCurves([cusp], footprint, 1), undefined);
  const raised = curve.map((value, i) => ({ ...value, y: i === 1 ? 1 : 0 }));
  assert.equal(certifyGardenCurves([raised], footprint, 1), undefined);
});

test('cabin endpoint uses the whole straight gait, while legacy approved endpoints stay fixed', () => {
  near(interiorEndpoint(3.789126461042909, true), -1.5391264610429092);
  near(interiorEndpoint(2.0008337018684985, true), -1);
  const zebraStraight = { minZ: -2.1585782682868864, maxZ: 2.060413188462522 };
  const endpoint = interiorEndpoint(zebraStraight);
  near(endpoint, .09142173171311363);
  near(endpoint - zebraStraight.minZ, 2.25);
  assert.ok(endpoint - zebraStraight.maxZ >= -2.06 + .08);
  assert.throws(() => interiorEndpoint({ minZ: -3, maxZ: 3 }), /cannot fit fully/);
  assert.throws(() => interiorEndpoint({ minZ: NaN, maxZ: 2 }), /valid longitudinal bounds/);
  const donkeyStraight = { minZ: -1.466419819708928, maxZ: 1.2357356657456566 };
  near(interiorEndpoint(donkeyStraight), .783580180291072);
  near(interiorEndpoint({ minZ: -1.4373878286961754, maxZ: 1.2060599898378248 }), .8126121713038246);
  near(interiorEndpoint({ minZ: -1.339829930709937, maxZ: 1.133389437922794 }), .9101700692900629);
});
