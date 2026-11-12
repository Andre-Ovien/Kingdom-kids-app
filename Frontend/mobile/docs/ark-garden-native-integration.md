# Ark garden native integration

The new v2 course uses the actual bundled Blender GLBs in a native Flutter
WebView. `ArkGardenNativeEngine` owns the active-time clock, first taps,
movement, waiting queue, full-body arrivals and the result. The JavaScript
renderer receives those distances and draws its own native walk/turn clips;
renderer arrival or score messages cannot complete a round.

The phone serves only an explicit allowlist of bundled resources on a random,
loopback-only origin. No models depend on the Mac's Wi-Fi address or Django
DEBUG media. All ten native models must load and match their recorded hashes
before the clock starts. Navigation cannot leave the local scene. The origin
and viewer resources close on exit and retry. Release Android HTTP access is
limited to `127.0.0.1`; the existing debug LAN access remains available.

V1 staging fixtures and the approved individual elephant/sheep previews are
unchanged. V2 routes explicitly carry the certified Bezier control points,
using the same 256-sample arc table in JavaScript, Dart and Python. The server
recomputes movement from first-tap ticks, accepting no client positions.

Each animal has its own conservative body width, length, rear extent and
holding gate. Ordered 5cm movement substeps keep idle/waiting bodies separated.
One owner reserves the shared convergence and stair corridor; the others wait
and resume automatically after its complete interior arrival. The scene
builder protects each holding area when certifying every ground route.
This is a deterministic boarding rule rather than a rigid-body simulator.
Skinned gait envelopes are sampled with a guard, so physical foot/wing contact
still needs the actual phone visual review.

The reviewed scene requests landscape automatically and restores the host's
orientation policy on exit. User pause, host exit/save overlays and lifecycle
backgrounding freeze the same clock and distances. On returning from the
background, the child resumes explicitly. Loading failures pause safely.
Viewer operations are generation-bound; old retry Futures cannot corrupt a
replacement. A terminal retry preserves the finished run and submits it once,
after the final state is successfully delivered and the renderer acknowledges
every animal the authoritative run actually boarded. A successful run needs
all ten arrivals; a partial timeout needs only its boarded subset. The renderer
emits those visual-only acknowledgements after a successful draw. They never
alter movement, score or elapsed time. Missing acknowledgements enter safe
retry after five active seconds; pause, backgrounding, retry and disposal
cancel that wait. A short settle delay remains after the final acknowledgements.

## Packaging and local installation

`tool/package_ark_garden.py` first checks the complete course, exact model
hashes and real ten-animal JavaScript/Python queue replay agreement. It then
copies the actual models, garden, renderer, Three.js and accompanying art
license notices into the Flutter bundle. It also writes identical backend and
Flutter v2 course/replay fixtures. It does not publish a catalogue entry.

The idempotent backend `install_ark_garden` command uses a new garden identity
and one level. It takes a consistent SQLite backup before changes. Existing
profile XP, attempts, progress and retired matching IDs are preserved. Its
default creates an unpublished review record; `--publish` makes it visible
only in the local catalogue. Do not expose it to an installed app without the
new v2 viewer. App-store or public deployment is separate work.

The catalogue uses four presentation sections: Puzzles, Quizzes, Games and
Matching. Noah's Ark Garden appears under Games with a Game badge and animal
icon. Its existing matching wire engine is retained for API/dispatch
compatibility; the retired matching identities stay hidden. Catalogue
summaries identify the garden by its stable slug even before levels load.

```sh
python3 tool/package_ark_garden.py
dart run tool/check_ark_garden_replay.dart
```

From `Backend/Core`:

```sh
DJANGO_DEBUG=true ../.venv/bin/python manage.py install_ark_garden
DJANGO_DEBUG=true ../.venv/bin/python manage.py test \
  apps.games.test_ark_garden apps.games.test_ark_garden_curves \
  apps.games.test_ark_garden_install.ArkGardenInstallerTests --noinput
```

From `Frontend/mobile`:

```sh
flutter test --no-pub --concurrency=1 \
  test/ark_garden_model_test.dart test/ark_garden_engine_test.dart \
  test/ark_garden_native_engine_test.dart
```

The focused Python/Dart checks run without a live server or phone/account
changes. The native widget suite includes delayed/stale/failing viewer
regressions. An earlier restricted run could not bind its required loopback
socket. After full access was restored, the complete focused native widget,
catalogue, data and game-screen suite ran successfully: 104 tests passed.

## Checked checkpoint — 14 October 2026

All ten actual native exports, Ark, Noah, the garden and renderer resources are
packaged: 31 files, 34.6MiB, including the required accompanying asset licenses.
The three real ten-animal queue orders (together, reversed and staggered) agree
in JavaScript, Python and Dart. Protected waiting prefixes and cycle-aligned
holding gates allow independent garden approaches before the shared corridor.
The elephant, lion and giraffe begin closer to the Ark; native gait speeds and
approved individual preview profiles are unchanged. All ten arrive within
3,237 ticks. The deadline is 3,597 ticks, shown as 6:00, leaving at least
36 seconds for finding and tapping the animals.

Validation passed: 29 focused backend contract/API/installer checks, 18
socket-free Dart cross-language replay/pause checks, model hash verification,
and targeted Dart analysis with no issues. A measured backend replay takes
about 0.35 seconds on this Mac. Catalogue tests cover the four presentation
sections and prevent the new garden from restoring retired matching games.
Native fake-viewer regressions for late/stale/failing state delivery now pass
as part of the 104 executed Flutter tests. The host-resume regression gives
the restarted ticker its first baseline frame before asserting active-time
advancement; no production pause or clock behavior changed.

The new garden record is installed **unpublished** with one level after a
consistent SQLite backup under `Backend/Core/.cache/ark-garden-backups/`.
Comparing that backup verifies 25 account/progress/other tables and all other
game rows are unchanged. Repeating the installer reports no data changed.
After the final actual-renderer review and verified phone installation, the
new single-level `noahs-ark-garden` record was activated in the local review
database. The installer made a consistent backup; comparison confirms all
25 other tables and all other game and level rows are unchanged. This is not
a public deployment or store release.

An earlier unsigned build failed before compilation because restricted
workspace/build-cache access denied Xcode's PIFCache writes. That historical
diagnostic is retained in `output/ark-garden-integration-20261014/ios-build.log`.

After full access was restored, the signed Profile build succeeded with the
existing development team and bundle ID, a deployment override of iOS 15.0,
and the local API at `http://192.168.1.114:8100/api`. Deep strict signature
verification passed. All 31 bundled files match their packaged source hashes,
including the ten animals, Ark and Noah, totaling 36,289,916 bytes. The final
bundle also matches the current tool source for every one of its 31 resources.

The final updated app was installed on Andre's paired iPhone and launched
successfully; the device process listing independently confirmed the new
Runner process after local catalogue activation. The update preserves the
existing app container. Actual renderer review verified all ten models,
raycast taps after panning, fixed Ark/Noah world transforms, stair entry and
final arrivals. A failed final draw emitted zero acknowledgements; a recovered
draw emitted ten distinct visual-only acknowledgements without duplicates.
The physical phone round remains for the user's review under
Games → Noah's Ark Garden → Play; no direct game deep link is supported.

The signed build, executed tests and device outcomes are saved under
`output/ark-garden-integration-20261014/` as `ios-signed-build.log`,
`native-widget-tests.log`, `iphone-install.json`, `iphone-launch.json` and
`iphone-processes.json`. The exact final source/package/app hashes are recorded
in `ios-bundle-verification.json`; preserved local data is recorded in
`local-activation-verification.json`.

## Paused for charging — 14 October 2026

The user requested stopping the session and safely ejecting ANDRE_DEV at
18% battery. All ten animal models and exports are saved, and Blender was
already closed. The final signed app and local Ark entry remain installed
on the iPhone. The Mac backend is stopped; build and rendering jobs have
finished. No further game changes are authorized until the user returns.

Next session: hear the user's gameplay fixes and make the Ark more enjoyable
for children. Do not assume the current visual review replaces that feedback.
Restart the backend only when work is resumed. Preserve all existing models,
source art, evidence, user profiles and progress.
