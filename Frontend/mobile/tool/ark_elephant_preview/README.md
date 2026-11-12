# Saved-animal development preview

`index.html` remains the isolated single-animal review described below. The
separate `garden.html` combines the complete ten-animal course and actual native
exports. It fails closed until all ten own walking/turning clips, exported bytes,
and course/manifest calibration agree; it never shows stand-in animals.

The garden page uses the same world for the Ark, Noah, animals, shadows, and
approved panorama. Swiping translates the camera along its right axis, rather
than moving the Ark/Noah or dragging the photograph independently. The initial
garden view is shallower than the single review camera to fit the Ark roof and
the spread of foreground animals in a landscape phone viewport. Native phone
orientation is the Flutter host's responsibility; standalone portrait review
retains the automatic sideways canvas layout with no blocking instruction.

`garden.html?host=1` exposes `window.KingdomArkGarden`: `configure({config})`,
`start()`, `pause(bool)`, `state({tick,renderTick,taps,distances,paused,finished})`,
`replay()`, and `dispose()`. It emits JSON through the native
`KingdomArkBridge.postMessage` channel. `animalTapped` requests an authoritative
tap; `animalEntered` is explicitly visual-only and never awards XP or completes
the native game. Native distances interpolate for one tenth-second and drive
the own gait phase; queued animals' feet freeze when distance stops. The host
owns the timer, accepted first taps, pause/background behavior, and result.

The standalone page uses the same fixed-tick traffic rule for local review.
Explicit queue gates reserve the common approach and stairs until a tail has
fully entered. Other animals wait in protected areas around their scattered
starts and continue without another tap. Curves are certified against those
waiting areas as well as the actual Ark, rails, and Noah footprint. There is
one timed level. Its duration is derived from real gait speeds and full traffic
replays, with at least a thirty-second cushion, rather than speeding up native
clips to fit a guessed deadline.

`build_garden_course.mjs` reads the real GLBs and writes the movement-only
`garden_course_v2.json` plus `garden_native_assets.json`. It checks skin weights,
own closed loops, posed normalization, actual open-door width/lintel height,
and complete early/reversed/staggered tap replays before writing either file.
The new lion/camel/giraffe pace estimates use their own low-foot stance samples;
front/rear contact differences still mean approximate planting, not a physics
solver. The generated manifest retains exact file SHA-256 values and diagnostic
limits. A LAN-compatible browser hash fallback avoids a WebCrypto restriction
on HTTP phone reviews. Native packaging must include actual exported assets,
the manifest, local Three.js modules, and `assets/licenses/` notices.

## Ten-animal review checkpoint · 2026-10-14

All ten real exports are linked: elephant, sheep, zebra, donkey, deer, rabbit,
dove, lion, camel, and giraffe. The new three use their own saved native gaits;
none inherits the elephant rig. Their chosen heights relative to Noah's 1.8 m
body are lion 1.3 m, camel 2.3 m, and giraffe 3.3 m. The sampled giraffe gait
reaches 3.416 m and fits below the 3.9 m doorway height with the stated guard.

The review course places the slower elephant, lion, and giraffe nearer the Ark
while spreading the faster animals farther across the garden. It preserves all
native speeds and the approved isolated elephant/sheep routes. Every animal's
possible pre-queue body poses are bounded continuously along its Bezier prefix;
every other owner's full ground route must clear those bounds. Animals can
advance in parallel only as far as those certified prefixes, then wait for the
shared staircase. Walking actors park on closed gait phases; the dove keeps its
native hover flap while waiting. `garden_waiting_zones.mjs` implements the
continuous prefix bounds, including asymmetric front/rear dimensions.

The resulting deadline is **359.7 seconds**, displayed as 6:00. Together,
reverse, and staggered tap replays finish in 323.2, 323.7, and 323.2 seconds,
leaving at least 36 seconds of search/tap margin for those scenarios. The
manifest retains those arrival records and each actor's waiting certificate.
This is a six-minute first-review course, with pacing still to review, not a
claim of finished play balance. JS, Python, and Dart deterministic replays
agree after native packaging. There are 41 passing focused Node checks.

Native final entry continues its last 100 ms interpolation before hiding the
last tail; finished state does not snap that frame. A paused state freezes the
visible pose. The native host waits 120 ms after final state before its result.

The isolated software-WebGL test can be run with
`KK_RUNTIME_NODE_PACKAGES=<bundled Node modules> node tool/ark_elephant_preview/render_garden_test.mjs`.
It uses only an embedded local file fixture, a fresh headless profile, and
software WebGL; it starts no HTTP service and does not control Safari. In this
session Chromium exited during Mac sandbox initialization before loading the
fixture. No screenshot was generated. Physical foot contact, garden/perspective
alignment, phone framing, and texture appearance therefore still require actual
on-screen review; structural tests do not replace it.

Phone URLs on the existing local backend:

- Elephant (default): `http://192.168.1.114:8100/media/dev/ark-elephant-preview/index.html`
- Sheep review: `http://192.168.1.114:8100/media/dev/ark-elephant-preview/index.html?animal=sheep`
- Zebra review: `http://192.168.1.114:8100/media/dev/ark-elephant-preview/index.html?animal=zebra`
- Donkey review: `http://192.168.1.114:8100/media/dev/ark-elephant-preview/index.html?animal=donkey`
- Deer review: `http://192.168.1.114:8100/media/dev/ark-elephant-preview/index.html?animal=deer`
- Rabbit review: `http://192.168.1.114:8100/media/dev/ark-elephant-preview/index.html?animal=rabbit`
- Dove flight review: `http://192.168.1.114:8100/media/dev/ark-elephant-preview/index.html?animal=dove`

This isolated Three.js page loads the real, GUI-exported Ark, Noah, and one
selected animal. Elephant remains the default; the `animal` query selects an
allowlisted review profile. It has no profile, database write, game submission,
XP, or catalogue entry.
It is a development scene, not an installed mobile-app update. The isolated single-animal page does not activate the production catalogue.
The native host and unpublished garden staging are maintained separately.

Export from the visible Blender GUI into `Motion/ark-animals-gui-v1`:

- `ark-review.glb`: the saved Ark, all thirteen treads, and its physical doorway
  opening; preserve the existing scene transforms and metre units.
- `noah-review.glb`: saved Noah meshes/rig/staff in the reviewed pose.
- `elephant-review.glb`: saved elephant meshes/rig and actual walking animation;
  the reviewed export's `Elephant_RigAction` is selected explicitly, with its
  0.041667-second offset rebased for a closed two-second loop. The exported
  `ElephantTurnLeft` and `ElephantTurnRight` are phase-locked to that gait and
  blended by signed route curvature. Unrelated source clips are ignored.
- `sheep-review.glb`: native GUI export now available, with the sheep's own
  24-joint rig, body, and head-parented eyes. Its exact `WalkSlow` source clip
  runs from 0 to 2 seconds with matching loop endpoints. Other source actions
  (`Death`, `Idle`, `Jump`, `Run`, `Walk`) are ignored. The native re-export
  also contains `SheepTurnLeft` and `SheepTurnRight`, each with a closed
  two-second loop and actual per-leg changes. The shared mixer phase-locks
  these sheep-native variants to `WalkSlow` and blends by route curvature.
  Availability and pending diagnostics are derived from the loaded asset's
  clips; no elephant tracks or fabricated turn poses are substituted.

The zebra native export is now saved and linked; its own three closed gaits,
colors, and head-attached smaller eyes pass the read-only loader audit. It is
still a review candidate. Donkey is also now exported and linked, with its own
50-joint body, original eight materials, and three closed 35/30-second gaits.
Its posed height is 1.9 and calibrated pace is about 1.4044 world units/second.
Deer is now also exported and linked, retaining its 46-joint body, seven
materials including skinned eyes, and three closed 35/30-second native gaits.
Its posed height is 2.1 and calibrated pace is about 1.4145 world units/second.
Rabbit is now exported and linked, retaining its own 37-joint body and native
`Running`, `RabbitTurnLeft`, and `RabbitTurnRight` paired-hop cycles. Each loop
is 16/24 seconds. Original source extras are excluded from the playback selection.
Its posed height is .9; estimated hop pace is about 1.8418 world units/second
from average native paw longitudinal spans over a cycle. Front/rear ground
contact speeds differ, so a constant pace does not claim exact planted feet.
Dove is now exported and linked with its 13-joint connected body, white vertex
coat colors, and closed one-second flap/bank clips. The reviewed export already
faces +Z; no second runtime flip is applied. Its .55 posed height is supplemented
by 1 metre flight altitude above the route, at 1.2 world units/second. Its own
signed 8-degree bank clips phase-lock to the source flap. The whole-wing envelope
retains at least 8 cm over the forward stair treads and below the doorway top.
All seven animals remain review candidates except the approved elephant.
No stand-in models are supplied.
Their heights are provisional; actual posed dimensions, forward orientation,
gait, and doorway clearance must be checked before marking them ready.

| Query | Required export | Required walk / expected duration | Own turn clips | Provisional height | Source pace × own scale |
| --- | --- | --- | --- | --- | --- |
| `?animal=zebra` | `zebra-review.glb` | `WalkSlow` / 2 seconds | `ZebraTurnLeft`, `ZebraTurnRight` | 3.0 | 2.44938 |
| `?animal=donkey` | `donkey-review.glb` | `Walk` / 35/30 seconds | `DonkeyTurnLeft`, `DonkeyTurnRight` | 1.9 | 2.8305732 |
| `?animal=deer` | `deer-review.glb` | `Walk` / 35/30 seconds | `DeerTurnLeft`, `DeerTurnRight` | 2.1 | 2.8305732 |
| `?animal=rabbit` | `rabbit-review.glb` | `Running` / 16/24 seconds | `RabbitTurnLeft`, `RabbitTurnRight` | .9 | 19.707256 (cycle-span estimate) |
| `?animal=dove` | `dove-review.glb` | `flap-wings-animation` / 1 second | `DoveTurnLeft`, `DoveTurnRight` | .55 | fixed flight pace 1.2 |

The `assets` links point at those exports and the approved garden image. The
backend's existing DEBUG media route follows a development-only directory link;
no new service is started and no backend code is modified. Three.js r180 and its
GLTF loader are served locally with the package's MIT licence, so the phone
does not fetch CDN scripts.

Blender `(x,y,z)` maps to glTF `(x,z,-y)`. Ark geometry stays at its authored
size. Figure wrappers normalize elephant height to 3.3 (3.0 if needed, capped
to a 2.5-wide doorway clearance), sheep height to 1.4, and Noah's head/body
height to 1.8, excluding the taller staff from that measurement and placing
their feet on the floor. The elephant's review ground and exported cameras/
lights are removed at runtime. Noah stands beside the stair foot at
`(-2.7,0,9.3)`. The exported robe's unsupported procedural chain receives only
its saved Blender linear Base Color `(0.18,0.07,0.27)`; skin textures and all
other exported colors are retained. Both animals face their initial route
tangent while stationary, so tapping does not snap their orientation.
The selected animal starts at `(4,0,12)`, follows a smooth ground curve into
the straight stair line at `(0,0,9.5)`, climbs
thirteen .33-high/.5-deep treads, reaches `(0,4.3,2.5)`, then travels farther
than its full measured body length behind the door before becoming invisible.
Actual geometry provides depth occlusion; there are no placeholder characters.

The approved panorama is a backdrop. The initial camera is an orthographic
three-quarter review angle, not a claim of final panorama/Blender calibration.
The single-scene review's camera is fixed: dragging does not move models
against the baked photographic garden. This does not change the full game's
future swipe requirement. Elephant travel speed uses the actual stance stride
of .9 source-world units over 1.5 seconds, multiplied by its normalization
factor. Sheep speed uses the current saved rig's audited mean grounded stance
speed of 2.44938 source-world units per second, multiplied by its own
normalization factor. Its source front and rear stride lengths differ, so
this is an approximate contact calibration. Neither animal inherits the
other's rig, clips, or stride. The fixed camera uses a 9.5-world-unit half-height.
Portrait Safari
automatically rotates the whole surface and controls; there is no blocking
orientation instruction. Tap the selected animal or its start button, then use
Pause/Replay as needed. The renderer
sleeps while the scene is still, limiting review load on the Mac/phone.

Missing required walk clips keep playback disabled and are reported explicitly.
Sheep never falls back to a different walk or an elephant animation. Missing
exports retain the export-wait message; asset requests receive a fresh revision
query on every page reload. The elephant has been visually approved. Sheep
still needs its single-animal visual review of gait, stair contact, doorway
clearance, pose, and framing. No phone build or install is needed for the Safari
review.

## Scattered-start review fixtures

Keep the approved elephant and existing sheep default geometry, normalization,
pace, camera, and interior endpoints unchanged. Non-default starts are isolated
review fixtures; they do not change the production course or replay contract.
Add `&approach=left`, `right`, `far-left`, `far-right`, `center`, `away`,
`away-left`, or `away-right` to an animal URL. For example:

`index.html?animal=zebra&approach=away`

The fixtures preserve their initial position and facing. They use one or more
Bezier curves with zero endpoint curvature and aligned joins into the stairs.
Center-facing-away uses free lateral controls in a seventh-degree curve, so
the animal walks outward and makes a broad turn instead of reversing through
a zero tangent or snapping its facing. Unsupported boundary/outward poses are
rejected. The planner is a near-Ark garden review planner, not a general terrain
or animal-to-animal navigation system.

The full curves are screened through adaptive Bezier control-hull bounds.
Each accepted interval has a nonzero forward tangent, a curvature bound within
the .7/1.3 stride variants' range, and a swept rigid rectangle that clears the
garden boundary, Ark hull, stair rails, and the actual normalized Noah/staff
footprint. Unresolved intervals are rejected; no fixed sample spacing is treated
as proof of route clearance.

For non-default starts, the rigid envelope is measured from 49 phase samples of
each actual native gait and four additional blended cycles (343 poses total),
with a 6 cm guard. This improves substantially on using standing dimensions:

| Animal | Standing width × length | Sampled ground gait envelope width × length |
| --- | --- | --- |
| Elephant | 1.205 × 3.789 | 1.335 × 3.935 |
| Sheep | 0.718 × 2.001 | 0.852 × 2.804 |
| Zebra | 1.090 × 3.997 | 1.210 × 4.714 |
| Donkey | 0.550 × 2.316 | 0.817 × 3.118 |
| Deer | 0.711 × 2.193 | 0.887 × 3.060 |
| Rabbit | 0.629 × 1.914 | 0.848 × 2.680 |
| Dove | 1.400 × 0.924 | 1.660 × 1.077 |

The envelope measurement is **sampled**, including selected blends, and is not
a continuous skinning certificate or a guarantee of precise stair foot contact.
The mathematical route certificate is conditional on that supplied rigid
envelope. Complete visual review and production scene/camera alignment remain
required before activation. Future species must be measured independently.

Rabbit's native turns change head/body response instead of the walkers'
inside/outside paw spans. Its review uses a broader explicit curvature limit
of .45 and phase-locked native lean clips. This is a presentation limit;
neither it nor the sampled body envelope proves hop-contact physics. The native
export includes validated 1024×1024 diffuse/normal PNGs, a normal map, and
roughness .8. The Node loader uses Texture placeholders because it has no
browser image decoder; saved PNG CRCs and compressed pixels are independently
validated. Rendering texture appearance still needs browser/phone review.

Straight cabin travel uses its own asymmetric whole-cycle bounds. Zebra's
new-review endpoint is about Z=0.0914, giving the guarded longitudinal range
[-1.9690, 2.25] behind the door and ahead of the saved cabin back wall's inner
face at Z=-2.06. The standing-only endpoint Z=0.2513 is insufficient to retain
the same margin throughout the actual gait. An animal whose straight gait
does not fit is rejected, rather than hidden while still protruding.

Local read-only checks (no browser, backend restart, phone install, or Blender):

```sh
node --test tool/ark_elephant_preview/*.test.mjs
node tool/ark_elephant_preview/check_native_asset.mjs elephant sheep zebra donkey deer rabbit
```

The GLB check uses the actual Three.js loader/mixer and reports native clips,
loop closure, pose dimensions, sampled gait envelopes, and each route fixture's
continuous envelope/curvature certificate. No native models are edited by it.
`native-route-audit.json` retains this pass for the seven exported animals,
including source-file hashes. Recheck it after any new native export; it is
neither visual approval nor a production readiness record.
