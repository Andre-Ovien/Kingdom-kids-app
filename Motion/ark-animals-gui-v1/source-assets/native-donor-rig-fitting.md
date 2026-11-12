# Native GUI fallback: Camel and Lion donor-rig fitting

This is a read-only geometry audit and proposed fitting guide, not a finished rig or animation. No model geometry, skin weights, armatures, actions, or Blender scenes were modified by the audit. Use this fallback only if the isolated ready-rig candidates cannot be imported cleanly. All actual fitting must happen in the visible Blender application.

## Shared donor

Append only `AnimalArmature` from `quaternius-ultimate-animals/Donkey.blend` into a separate working scene with the existing animal model. Keep original action names and bone names until native animation transfer is confirmed. Source donor is CC0, with real front-chain2/rear-chain4 IK, source Walk0–35 at30fps, and existing pole targets. Never copy a baked GLB skeleton and assume its named IK controls still have constraints.

Save As a new working scene before editing. Preserve the original artist mesh, materials, UV map, and source file. Fit the skeleton in Edit Mode; keep left/right bone names and hierarchy. Move each foot control and corresponding pole target with its fitted limb, maintaining its original pole direction. Bind the actual animal mesh with Armature Deform / Automatic Weights; inspect shoulder, hip, belly, neck, and mane weights and all four stance poses. Controls and pole targets should not deform the mesh. Automatic weights are a starting point requiring visual checking.

| Donor bones | Anatomical role |
|---|---|
| Body | Whole-body/root driver; retain original cycle without net travel |
| Back, Torso, Torso2, Torso3 | Pelvis-to-chest/spine chain |
| Neck1, Neck2, Neck3, Head | Chest to neck to skull/muzzle |
| FrontShoulder.L/R | Shoulder attachment |
| FrontUpperLeg.L/R | Shoulder to fore-knee/elbow |
| FrontLowerLeg.L/R | Fore-knee/elbow to ankle |
| IKFrontLeg.L/R, FF.L/R | Front ankle/paw and planted-foot orientation |
| BackShoulder.L/R | Hip attachment |
| BackLeg.L/R | Hip to hind knee |
| BackUpperLeg.L/R | Hind knee to hock |
| BackLowerLeg.L/R | Hock to ankle |
| IKBackLeg.L/R, FFB.L/R | Rear ankle/paw and planted-foot orientation |
| PoleTarget.L/R, PoleTargetBack.L/R | Front/rear bend direction, not skinned anatomy |
| Tail1–Tail7 | Tail curve; fit only the required chain length |
| Ear1–Ear4.L/R | Fit or disable unused ear deform bones; do not bind a long donkey ear chain blindly to the animal head |

## Camel — existing noway CC0 base

Source `noway-camel/camel.blend`, mesh `basemesh`, is a mirrored half-mesh with a native Mirror modifier. No armature exists. Its current object has RotationX90deg and its head faces world+Y. First rotate the actual camel model180deg about worldZ so it faces -Y like the donor; then inspect/apply Mirror ahead of the Armature modifier. Rotation/scale application and visible alignment must be checked before binding.

After that heading correction, native source units are approximately X±0.20143, Y-1.174..+1.08799, Z0..1.71725. Starting donor OBJECT scale (not a completed fitting) X0.43,Y0.30,Z0.43 and worldY translation+0.4045 align the limb widths and fore-foot positions reasonably. Fit the bones individually after this; do not accept the initial transform as final. In particular, stretch/reposition the three neck bones into the camel's actual long curved neck.

Approximate anatomical anchors after the180deg heading correction:

| Anchor | World coordinates (L side; mirrorX for R) |
|---|---|
| Front shoulder | (+0.14,+0.10,+0.86) |
| Front knee | (+0.14,+0.08,+0.48) |
| Front ankle/control | (+0.14,+0.11,+0.11) |
| Front foot surface | (+0.14,+0.10,+0.02) |
| Rear hip | (+0.14,+0.84,+0.94) |
| Rear knee | (+0.14,+0.98,+0.46) |
| Rear ankle/control | (+0.14,+0.85,+0.09) |
| Rear foot surface | (+0.14,+0.83,+0.02) |
| Neck1 guide | (0,-0.22,+1.22) |
| Neck2 guide | (0,-0.60,+1.43) |
| Neck3/skull guide | (0,-0.95,+1.63) |
| Head/muzzle tip | (0,-1.15,+1.58) |

Anchors are sampled geometry estimates. Preserve the modeled humps by assigning them smoothly to the existing spine chain. Warm coat, darker hooves, and head-attached eyes still require native material/detail work. Do not rebuild the animal from primitive pieces.

## Lion — existing Google Poly CC BY3.0 mesh

Source `lion-google-poly/lion.glb` contains one textured object and no skin or animation. It already faces glTF+Z; native Blender glTF import maps its heading to -Y. No180deg heading flip is needed. Its head/mane are on positive glTFZ, and the tail reaches negative glTFZ.

The file has3098 position records for1350triangles, but679unique geometric positions. Read-only positional welding reveals a connected484-vertex main body and a195-vertex overlapping mane shell. Keep the mane's intended overlap. In the GUI, if import leaves triangle islands, Merge by Distance at a tiny native threshold such as0.0001 before automatic skinning, retaining per-corner UV data and inspecting the texture. Bind both body and mane; weight the mane with its neck/head attachment so it cannot float separately.

Starting donor OBJECT scale X1.55,Y2.286,Z1.70 and worldY translation+0.15 approximately align the foot spread. Hind paws are wider than forepaws, so move the rear limb chains outwards individually; inspect torso, shoulders, and neck rather than accepting this scaling as final.

Native imported source geometry guides (BlenderZ up, -Y forward):

| Anchor | World coordinates (L side; mirrorX for R) |
|---|---|
| Fore shoulder | (+0.55,-1.85,+3.30) |
| Fore elbow | (+0.55,-1.55,+1.70) |
| Fore paw/control | (+0.52,-2.17,+0.15) |
| Hind hip | (+0.78,+2.80,+3.90) |
| Hind knee | (+0.75,+3.05,+2.05) |
| Hind hock | (+0.77,+3.55,+0.70) |
| Hind paw/control | (+0.78,+3.65,+0.15) |
| Neck/head pivot | (0,-2.70,+4.80) |
| Muzzle guide | (0,-5.00,+4.20) |

These are approximate fitting guides derived from the mesh. Preserve its original embedded `Lion_BaseColor` texture and UVs. Required original asset credit remains Poly by Google, linked to https://poly.pizza/m/3XAJojWxSWz, CC BY3.0; disclose model/rig modifications when redistributed. The CC0 donor does not remove the lion mesh's attribution requirement.

## Motion acceptance

Use a copy of the original walking action, never mutate the source file. Preserve loop endpoints and contact order. Donor controllers have coupled oblique localY/localZ axes; scale both location components together for a first turning study. Body proportions, step length, torso sway, and travel speed require separate review per species. A successful file export or automatic skinning is not proof of a natural gait. Check side and front views at contact, lift, turning, and stair approach poses before app integration.
