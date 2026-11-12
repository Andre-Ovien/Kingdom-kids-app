# Ark garden mechanics staging

The current ten-animal integration is described in
[`ark-garden-native-integration.md`](ark-garden-native-integration.md). All ten
native models are saved and exported, and the v2 game is bundled and staged
unpublished. Native build and visual playback checks are still blocked by this
session's permissions. The v1 staging details and older checkpoints below are
retained as history; they do not describe the new v2 renderer's readiness.

The `ark_garden` mode is a held, single-level tap-to-board engine. It does not
create a game, publish a catalogue entry, reopen `ark-animal-match`, or install
placeholder art. Normal mode dispatch supplies no scene adapter, so the engine
remains empty and its clock stays stopped.

The shared course is version 1, with a 100 ms clock and an initial 600-tick
(60-second) limit. It contains one each of elephant, lion, giraffe, zebra, dove,
sheep, camel, donkey, deer, and rabbit. The first tap starts each fixed 3D route;
repeat taps have no effect. Movement carries through waypoint joins. Stair
points strictly rise, the door and interior share deck height, and the final
interior point is at least one body length beyond the door. Only that endpoint
marks the animal boarded. Ten boarded animals finish the round early; timeout
saves the partial tap replay.

`ark_garden_course.json` and `ark_garden_replay.json` in `test/fixtures` mirror
the backend course and seven replay cases. Tests compare both copies and the
client's positions, phases, tap timestamps, and arrival ticks with Python's
golden results. The draft coordinates and projection are integration fixtures;
they are not an alignment claim for the GUI-authored Ark or approved panorama.

Before activation, supply an `ArkGardenScene` adapter with reviewed art for all
ten species. Its layers paint world/Ark behind, entering animals, opaque door
foreground, animals still outside, and other foreground elements. Boarded
animals are excluded entirely. The adapter receives elevated foot anchors,
ground anchors, heading, walk ticks, scene ticks, and reduced-motion preference.
Use scene ticks for idle/grazing and bird cycles without moving untapped animal
roots. For stair contact shadows use the elevated feet on the stair receiver;
the zero-height ground anchor is provided for ground projection and ordering.

The final Blender camera must determine projection scales and world dimensions.
One viewport transform and pan offset must position the background, models,
shadows, doorway mask, and hit targets. The adapter must derive its render
sizes/foot anchors from approved exports. The engine's full-screen host already
provides exit, lifecycle, pending-save, failed-save, and retry pauses. Asset
loading, final camera alignment, catalogue metadata, and publication remain
release work after art review. The approved engine requests landscape and
restores its host's configured orientation policy when disposed; the held
engine makes no orientation request.

Focused validation:

```sh
flutter test --no-pub --concurrency=1 test/ark_garden_model_test.dart test/ark_garden_engine_test.dart test/blender_activity_gameplay_test.dart
```

This runs host tests. No phone build, install, live database change, or Blender
execution is part of these checks.

## GUI art checkpoint — 12 October 2026

The user paused the remaining nine animals after the elephant review. Keep
modeling in the visible Blender application when work resumes; do not replace
it with Blender CLI or scripted character generation.

Saved sources are `Motion/ark-landscape-gui-v1.blend`,
`Motion/noah-character-gui-v1.blend`, and `Motion/ark-animals-gui-v1.blend`.
The elephant has a connected skinned body, four staggered foot controls,
short swing phases, body bob, trunk sway, and ear motion. Frames 1 and 49
match across all 32 bones. Foot Y curves are linear; swing Z curves are Bezier.
The actual exported gait is `Elephant_RigAction`, not the old source actions.

`tool/ark_elephant_preview` is a separate, one-elephant Three.js review served
through local DEBUG media. It uses GUI-exported Ark, Noah, and elephant GLBs
from `Motion/ark-animals-gui-v1/`. It does not activate the production game,
submit results, award XP, or replace the ten-animal completion rules.
Noah's unsupported outer-robe shader is displayed using its saved linear
base color; embedded skin textures remain intact.

Review feedback to retain: the elephant must be larger, its travel must match
its steps, and the Ark/Noah must stay registered to the garden. The quick
single-scene preview locks camera panning because its backdrop is a fixed
image. The production game still needs a coherent wide, swipable world.
Landscape presentation is automatic; no rotate-phone blocking prompt.

Remaining art work: nine animals, final garden/ground registration, precise
stair foot contact, and production scene integration. One inner elephant
tusk face still has the skin material and needs an ivory assignment in the
GUI source. The model and boarding review are not final production approval.

## GUI art checkpoint — 13 October 2026

The user approved the revised elephant boarding preview (“elephant was perfect”)
and asked to continue the other nine animals. Preserve that reviewed elephant
export and its default preview profile. `ElephantTurnLeft` and
`ElephantTurnRight` are native GUI-authored actions with distinct inner/outer
foot strides and head/trunk response. They blend with `Elephant_RigAction` at
the same loop phase along the curved approach. The iPhone Safari review was
opened successfully over the local network.

The sheep review is saved in `Motion/ark-sheep-gui-v1.blend` and exported to
`Motion/ark-animals-gui-v1/sheep-review.glb`. It retains a continuous skinned
body, subdivision after the armature, fitted eyes parented to `Head`, and
`WalkSlow`, `SheepTurnLeft`, and `SheepTurnRight`. All three exported clips
have closed two-second loops; native turn clips alter actual leg and head
channels. Loader/mixer checks confirm synchronized blending and normalized
weights. The sheep preview opens with `?animal=sheep`; it is a review candidate,
not user approval or production activation.

Zebra work is saved separately in `Motion/ark-zebra-gui-v1.blend`. Its body
smoothing, stripe materials, and native turning stride changes are present.
All four eye components now follow `Head`; eye radii were reduced by 35% and
the pupils fitted inward following the user's feedback. Right-head steering
is corrected to the opposite of the left turn, with exact endpoint closure.
`Motion/ark-animals-gui-v1/zebra-review.glb` was exported through the visible
Blender interface. The actual loader confirms a connected skinned body,
colors, attached eyes, and closed two-second `WalkSlow`, `ZebraTurnLeft`, and
`ZebraTurnRight` clips. Physical foot contact and full boarding still require
visual review; this is not production or user approval.

Unmodified native CC0 donkey and deer rigs are stored under
`Motion/ark-animals-gui-v1/source-assets/quaternius-ultimate-animals/` with
source hashes and permission metadata. Additional original animated Camel,
Lion, and Giraffe Collada sources and textures are isolated under
`source-assets/wildfire-0ad-animals/`; their CC BY-SA 3.0 art credit and
redistribution requirements must accompany any selected modified exports.
Downloading these sources is not a claim that their final appearance has
been reviewed or that their models have been integrated.

## Battery pause — 13 October 2026

The user requested continued animal work until battery reaches 7%. The next
battery read reported 6%, so work was immediately paused and the active
boarding helper interrupted. Save checkpoints before stopping; do not touch
the other project, force quit Blender, quit Codex, or eject the SSD.

Fourth animal: `Motion/ark-donkey-gui-v1.blend`, saved at frame 35 with
`DonkeyTurnLeft` active. Preserve mesh X and the cancelling parent inverse.
The connected body has Armature followed by Subdivision 2, smooth shading,
and its original materials and eyes. All 13 source NLA strips are muted.
The original `Walk` is preserved; its loop is frames 0–35 at 30 fps. Left
turn foot Location Y AND Z curves use .L 0.70 and .R 1.30 about value zero;
their ratios, unchanged timing, rotations, and closure passed read-only audit.
Head global +6-degree yaw was applied through the visible GUI at native head
keys 0, 8, 19, 28, and 34, with frame 0 pose copied to 35. This head edit
still needs final audit. `DonkeyTurnRight` and donkey export are NOT done.

The user confirmed ten unique animals and scattered garden starts, including
left/right and facing-away approaches. Preview varied-start geometry and
footprint clearance work was in progress when paused. Default elephant and
sheep routes must remain approved as reviewed. Held native garden routes also
need frontend/server replay agreement before adopting new route geometry;
no production activation or app rebuild occurred during this pass.

## Resumed session — 13 October 2026

The user resumed work and changed the battery stopping point to **15%**.
At or below that threshold, save the GUI checkpoint, stop project work and
helpers, close Blender normally, stop development/backend/preview jobs, and
safely eject ANDRE_DEV. The user also authorized stopping other project
processes if they prevent safe ejection. Preserve files; do not force unmount
the drive or shut down the Mac. The prior session's SSD ejection succeeded.

The first resumed battery read reported 57%; the SSD is mounted again.
Current Codex permissions rejected both visible Blender control and the
battery-monitor update. The prior heartbeat therefore remains paused at its
old configuration; it is not an active 15% monitor. Check the battery manually
between work steps while this session remains active. A permission request is
pending; do not claim GUI modeling resumed or switch to CLI/model-edit scripts.
Read-only donkey audit and review-only scattered-route work can proceed.

The user changed this chat to Ask for approval. Blender access then succeeded,
and keyboard and mouse control were verified in its visible window. The existing
heartbeat was updated through the app and is now ACTIVE with the 15% stop,
save, process-cleanup, and safe SSD-ejection instruction. The earlier permission
block is resolved; the donkey scene is open for GUI edits again.

The donkey is now complete for the model/export review pass, saved in
`Motion/ark-donkey-gui-v1.blend` and exported through Blender's visible interface
to `Motion/ark-animals-gui-v1/donkey-review.glb`. Walk and both turns close at
frames 0–35 at 30 fps; playback is 0–34. Read-only native audits confirm the
original Walk is unchanged, each turn scales the eight intended foot Y/Z
curves, and Head steering is +6/−6 degrees with exact endpoint closure.
The actual Three.js loader confirms 50 joints, eight retained materials,
normalized weights, closed clips and eight certified approach routes. This
is a review candidate; actual boarding visuals and stair contact remain to
be reviewed. No production activation, backend restart or phone rebuild.

Fifth animal: `Motion/ark-deer-gui-v1.blend`, saved separately from its CC0
source. The connected body has smooth shading and Armature → Subdivision 2.
`Walk`, `DeerTurnLeft` and `DeerTurnRight` are retained. Both native turn
audits pass the intended asymmetric foot Y/Z strides and ±6-degree head
steering; other channels and source Walk remain unchanged. Playback is 0–34
at 30 fps, retaining closure frame 35. Its review GLB was exported through
the GUI to `Motion/ark-animals-gui-v1/deer-review.glb`. The actual loader confirms
46 joints, seven exported source materials, normalized weights and three closed
clips. All eight approach routes certify; visual boarding and stair contact
remain review requirements. This is a review candidate, not production approval.

Sixth animal: `Motion/ark-rabbit-gui-v1.blend`, saved separately from its CC0
source. The body is smooth with Subdivision 2; packed diffuse and normal textures
are wired to Principled BSDF, with the normal image marked Non-Color. Decorative
fur cards are hidden and excluded from the selected rig/body export. The original
paired-hop `Running` action remains unchanged. `RabbitTurnLeft` and
`RabbitTurnRight` key Head steering at global Z ±6 degrees and spine lean at
global Y ±3 degrees across the seven native keys, with exact closure at frame 16
and playback 0–15 at 24 fps. The initial shortcut keyed Scale instead of Rotation;
this was corrected through the visible Insert Keyframe → Rotation menu and
verified by read-only native audit. The six constant Scale curves in the left
action remain at 1 and do not affect the pose. The GUI export is saved as
`Motion/ark-animals-gui-v1/rabbit-review.glb`. The actual loader confirms 37
joints, embedded diffuse/normal PNGs, normalized weights and three closed clips;
all eight approach routes certify, and the focused preview suite passes 26
checks. Actual boarding visuals still need review. Source front/rear hop contact
speeds differ, so approximate travel calibration is not verified foot planting.

Seventh animal: `Motion/ark-dove-gui-v1.blend` is saved separately from its CC0
source, with a connected body, Armature followed by Subdivision 2, and `Col`
vertex colors wired to Principled Base Color. Feather recoloring was performed
through visible Geometry Nodes, applied before skinning, and audited to preserve
mesh topology and weights. The blue-greater-than-red mask whitened 2,451 corners
(including 14 dark bluish accent corners); the remaining 579 corners, including
the original orange and neutral-black accents, are unchanged. Visual review of
the eye edges is still required.

The original Flap, Idle and legs-up pose curves are unchanged. `DoveTurnLeft`
and `DoveTurnRight` copy the native wing cycle and add whole-rig Y banks of
−8/+8 degrees at frames 0, 6, 12, 18 and 24, preserving all wing/leg/tail roots
together. Native audit confirms closure within source float precision, all five
actions retained with Fake User, muted source NLA stashes, and selection of only
the body and rig. Playback is 0–23 at 24 fps, retaining closure frame 24.
The visible GUI export is `Motion/ark-animals-gui-v1/dove-review.glb`. Actual
loader checks confirm 13 joints, normalized weights, white vertex coat colors,
three closed one-second flight/bank clips and eight certified approach routes.
The preview suite passes 28 checks. Flight height is 0.55, speed 1.2 and altitude
1.0 above route elevation; this increased altitude clears the conservative
forward-wing/tread bound that failed at 0.65. Sampled full-wing guarded bounds
are 1.660 wide by 1.077 long, with vertical range −0.1574 to 0.8922. Signed bank
quaternions tilt into the route turn. Precise physical and visual wing clearance
remain review requirements because the skinned envelope is sampled. No
production activation or phone build.

Lion, camel and giraffe sources remain unmodified.

## Battery cutoff checkpoint — 13 October 2026, resumed session

The battery reached **15%**, so animal modeling and preview work stopped
immediately. All helpers are complete with no jobs left running. The dove was
saved through Blender's visible interface with neutral rig bank, Flap active,
frame 0 and playback 0–23. Seven review exports are saved: elephant (approved),
sheep, zebra, donkey, deer, rabbit and dove. Lion, camel and giraffe are the
three remaining animals; do not begin them until the user resumes.

Blender was saved and closed normally, and a process check confirms no Blender,
development build/render, backend or preview jobs remain. All helpers finished.
Only Codex workspace/control sessions hold SSD working directories. Safe SSD
ejection is still being completed; do not claim success until unmount is verified.
The battery-monitor pause call was rejected because the current approval policy
does not allow its required approval. The monitor has not been confirmed disabled.

## Final animal creation checkpoint — 14 October 2026

The user resumed work and authorized finishing all animals, integrating them into
the single-level Ark game, and testing the scattered garden while away. Modeling,
animation changes, and exports continued through the visible Blender application.
The 15% battery stopping instruction remains in force.

All ten species now have saved native models and review GLBs: elephant, sheep,
zebra, donkey, deer, rabbit, dove, lion, camel, and giraffe. The approved elephant
export and existing reference profile are preserved. Model/export checks are not
a claim that the combined phone gameplay has been visually approved.

The three remaining native files are `Motion/ark-lion-gui-v1.blend`,
`Motion/ark-camel-gui-v1.blend`, and `Motion/ark-giraffe-gui-v1.blend`. Their GLBs
are in `Motion/ark-animals-gui-v1/`, named `lion-review.glb`, `camel-review.glb`,
and `giraffe-review.glb`. Each export contains its straight walk and left/right
turn actions, packed original coat texture, connected subdivided skin, normalized
weights, and valid normals/bind matrices. Lion and giraffe loops run 80 frames
at 24 fps; camel loops run 32 frames at 24 fps. Closing frames are retained in
the exported clips and excluded from native looping playback. Saved checks
confirm the turn edits preserve the remaining source gait channels.

The camel's complete mesh is attached to its walking rig, with a non-deforming
shoulder control added for opposite turns. The giraffe's original rear-foot
closing mismatch is corrected, its constant torso rotation is keyed separately
for each turn, and the obsolete mismatched walk stash is excluded from export.
The original Wildfire source files are unchanged. Wildfire Games / 0 A.D.
CC BY-SA 3.0 attribution and art redistribution information must accompany
the modified lion, camel, and giraffe assets.

The combined garden integration uses an automatically landscape mobile WebView
with bundled art served only on the phone's loopback interface. Flutter owns
the tap replay, elapsed time, queue movement, and completion. The viewer supplies
rendering and panning; it cannot submit a score or a claimed animal position.
Pause, app backgrounding, save, retry, and viewer replacement are checked.
Final ten-animal course certification, bundle assembly, visual review, and
phone build/install are still pending at this checkpoint.
