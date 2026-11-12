/** Read-only mesh bounds through complete native gait cycles and blends.
 * The result includes a guard, but is not a continuous skinning certificate.
 * Keep that distinction visible in diagnostics and require visual review.
 */
export function measureGaitEnvelope({ THREE, asset, mixer, gaits, actions, standingBounds, factor, samples = 48, guard = .06 }) {
  if (!Number.isInteger(samples) || samples < 24 || samples > 96 || !Number.isFinite(factor) || factor <= 0
    || !Number.isFinite(guard) || guard < 0) throw new Error('Gait bounds need a valid scale, guard, and sampling count.');
  const center = standingBounds.getCenter(new THREE.Vector3());
  const bounds = standingBounds.clone();
  const straightBounds = standingBounds.clone();
  const combinations = [
    { walk: 1 }, { left: 1 }, { right: 1 },
    { walk: .5, left: .5 }, { walk: .5, right: .5 },
    { left: .5, right: .5 }, { walk: 1 / 3, left: 1 / 3, right: 1 / 3 },
  ].filter(weights => Object.entries(weights).every(([name, weight]) => !weight || actions[name]));
  let poses = 0;
  for (const weights of combinations) {
    mixer.stopAllAction();
    for (const [name, action] of Object.entries(actions)) {
      if (action) action.reset().setEffectiveTimeScale(1).setEffectiveWeight(weights[name] ?? 0).play();
    }
    for (let i = 0; i <= samples; i++) {
      for (const [name, action] of Object.entries(actions)) if (action) action.time = Math.min(gaits[name].duration - 1e-8, i / samples * gaits[name].duration);
      mixer.update(0); asset.updateMatrixWorld(true);
      asset.traverse(object => {
        if (object.isSkinnedMesh) { object.skeleton.update(); object.computeBoundingBox(); }
      });
      const at = new THREE.Box3().setFromObject(asset);
      bounds.union(at);
      if (weights.walk === 1) straightBounds.union(at);
      poses++;
    }
  }
  mixer.stopAllAction();
  actions.walk.reset().setEffectiveTimeScale(1).setEffectiveWeight(1).play();
  mixer.update(0); asset.updateMatrixWorld(true);
  asset.traverse(object => {
    if (object.isSkinnedMesh) { object.skeleton.update(); object.computeBoundingBox(); object.computeBoundingSphere(); }
  });
  const envelope = box => ({
    width: 2 * Math.max(Math.abs(box.min.x - center.x), Math.abs(box.max.x - center.x)) * factor + 2 * guard,
    length: 2 * Math.max(Math.abs(box.min.z - center.z), Math.abs(box.max.z - center.z)) * factor + 2 * guard,
    minZ: (box.min.z - center.z) * factor - guard,
    maxZ: (box.max.z - center.z) * factor + guard,
    minY: (box.min.y - standingBounds.min.y) * factor - guard,
    maxY: (box.max.y - standingBounds.min.y) * factor + guard,
  });
  const { width, length, minY, maxY } = envelope(bounds);
  if (![width, length].every(value => Number.isFinite(value) && value > 0)) throw new Error('The native gaits have invalid mesh bounds.');
  return { width, length, minY, maxY, poses, phaseSamples: samples + 1, blendSamples: combinations.length,
    straight: envelope(straightBounds), guard,
    basis: 'sampled native gait and blends with guard; visual review required' };
}
