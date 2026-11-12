# Kingdom Kids mobile

The Flutter client begins with an image-led onboarding journey, then lets a
parent register or sign in and create one or more child profiles.

## Run locally

```bash
cd Frontend/mobile
flutter pub get
flutter run
```

The API base URL is configured at build time with `API_BASE_URL`. It must
include the `/api` suffix.

| Target | Development command |
| --- | --- |
| macOS, iOS simulator, or Flutter Web | `flutter run --dart-define=API_BASE_URL=http://localhost:8000/api` |
| Android emulator | `flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8000/api` |
| Physical device | Use an HTTPS URL reachable from that device, for example `flutter run --dart-define=API_BASE_URL=https://api.example.test/api` |

Android permits local HTTP only in the debug build. Release builds must use
HTTPS; do not point a production build at a cleartext development server.

Hosted story covers, narrator audio, and future hosted game covers are also
restricted at build time. The `API_BASE_URL` host is trusted automatically;
leave `CONTENT_MEDIA_HOSTS` empty for API-host-only media, or list every
additional owned CDN hostname in that comma-separated define. Extra entries
must be public hostnames only—no schemes, paths, ports, wildcards, or local
network addresses. The guarded release script also requires a positive,
monotonically increasing Play build number and configured upload signing:

```bash
API_BASE_URL=https://api.example.com/api \
CONTENT_MEDIA_HOSTS=media.example.com,audio.example.com \
BUILD_NUMBER=2 \
./tool/build_android_release.sh
```

Copy `android/key.properties.example` to the ignored
`android/key.properties` and replace every placeholder, or set all four
`ANDROID_KEYSTORE_*` variables in the release environment. Release builds fail
if signing is incomplete; they never fall back to the debug key. Keep the
upload keystore and passwords in a secret manager and enroll the upload key in
Google Play App Signing.

The Android application ID is `com.andreovien.kingdomkids`. A Play package ID
cannot be changed after the first upload, so confirm ownership of this exact ID
before creating the production listing. The repository pins Flutter 3.44.1 in
`.fvmrc` and pins the Gradle distribution and wrapper checksums. The guarded
release script refuses to run under a different active Flutter version.

Release media URLs must be absolute HTTPS URLs on one of those exact hosts.
Signed query strings are supported, while URL credentials, fragments, and
non-default ports are rejected unless the exact API endpoint declares that
port. Debug builds additionally permit cleartext media only from localhost
(including loopback addresses); rejected media falls back to bundled artwork
or the local placeholder.

Run the focused games tests, the complete widget/unit suite, and static
analysis from the repository root with:

```bash
cd Frontend/mobile
flutter test test/game_data_test.dart test/game_screen_test.dart
flutter test
flutter analyze
```

## Account flow

1. A new parent registers with an email and password.
2. The app opens the six-digit email verification screen; registration does
   not issue or store JWTs yet.
3. Successful verification returns the JWT session, which is stored in
   platform secure storage. Returning verified parents can sign in directly.
4. The parent creates a minimal child profile (display name and approved avatar).
5. The selected profile personalizes Home and Profile.

The backend routes live under `/api/accounts/`: `register/`, `login/`,
`email-verification/confirm/`, `email-verification/resend/`, `token/refresh/`,
`logout/`, `password-reset/request/`, `password-reset/confirm/`, `me/`, and
`kid-profiles/`. Password recovery uses generic responses to avoid revealing
which email addresses have accounts. Successful recovery invalidates old
sessions; email proof also lets the mailbox owner reclaim a pending account
that was never verified. A parent can permanently delete the account and all
associated child data from the in-app danger zone or the public website
deletion page.

Parent settings, account details, profile editing, and adding another child
are protected by current-password reauthentication. Ordinary switching among
the signed-in parent's existing child profiles remains available without
showing parent account data. Route-level parent authorization expires after
five minutes and immediately relocks whenever the app leaves the resumed
foreground state. The first profile setup immediately after verified
registration remains part of the parent-led setup flow.

Authentication state, the selected child, parent settings, first-launch state,
and reminder settings use scoped platform secure-storage keys. Version 10 of
`flutter_secure_storage` is intentional for one shipped migration cycle so
existing version-9 Android ciphertext can be read and migrated; upgrade to
version 11 only after that migration release has reached existing installs.

## Stories and narration

The Story Library and full reader load from the authenticated Django endpoints
under `/api/stories/`. Requests reuse the parent session's coordinated token
refresh path, and the UI provides loading, retry, empty, search, and category
filter states.

Each child character has a backend-configured reading style. Ready character
tracks use hosted audio through `just_audio`; the reader downloads validated,
bounded media before playback. Highlighting follows measured word timings when
the API supplies them, while elapsed time and the duration bar follow the
player's live position independently of paragraph changes. Silence clears the
word highlight; missing word cues do not trigger invented paragraph highlights.
The paragraph being read stays centered using its rendered text bounds; long
paragraphs follow the spoken lines so the active words remain visible.
A paused track resumes at its actual audio position, and
passage navigation seeks to the corresponding measured cue. The selected
profile's character determines the narrator.

Stories still marked `device_tts` use `flutter_tts` to rank installed offline
English voices by locale and quality, request audio focus, and apply the
configured pace and pitch. Those system voices remain device-dependent; they
are not the new original synthetic character voices. Hosted recordings and
device fallback use the same reader, parental preference, lifecycle, and
progress flow.

Android 11+ package visibility for the system TTS service is declared in the
main manifest. No microphone permission is needed because the feature only
reads story text aloud. The last server-confirmed narration preference is
cached per child in encrypted platform storage and may be used after a
connection timeout; a first-ever offline preference check remains fail-closed.

## Watch release scope

The first Play Store release intentionally does not advertise Watch. It is
absent from the primary bottom navigation and Home adventure launcher because
the videos backend is still a placeholder. The internal video routes and
screens remain in the source for future development, but must not be described
as a shipped backend-powered feature in the Play listing.

## Release-safe failures

User-facing screens render `AppException.userMessage`, which maps connectivity,
timeouts, expired sessions, unavailable content, rate limits, and service
failures to reviewed family-facing copy. Raw response bodies, status codes,
backend field names, and native TTS errors remain diagnostic-only. Unexpected
Flutter rendering failures use the app-level friendly fallback rather than the
default technical error surface.

## Daily streak

Reaching Home claims the selected child's local day from the authenticated
progress API. That app open immediately continues the streak; the character
celebration is shown at most once for that child and day, based entirely on the
server response. The mobile app does not calculate a separate “at risk” screen
state.

A parent can opt into streak reminders under **Parent settings → On this
device**. Permission is requested there, never from the child-facing Home
screen. After every app open, the device cancels the pending reminder and
schedules one for 5:00 PM the following local day. It therefore fires only if
the app has not been opened by that time, and signing out disables the pending
reminder.

## Games

Games are fully backed by the authenticated Django API; the mobile app does not
use a hard-coded fallback catalogue or award its own progress. The active child
profile is sent with every catalogue, detail, and submission request, and the
repository refuses a stale profile ID if the parent switches children while a
screen is open. Requests share the same refresh-aware bearer-token path as the
rest of the signed-in experience.

The game room loads eight games and 24 backend-authored levels:

| Game | Play style |
| --- | --- |
| Match the Ark Animals | Pair each animal with its partner |
| Creation Order | Put the days and events in sequence |
| David's Sling Aim | Aim and launch at the target |
| Jonah Ocean Maze | Navigate Jonah through a bounded grid |
| Red Sea Path | Build an adjacent start-to-finish route |
| Daniel Memory Match | Reveal and remember matching cards |
| Esther Brave Quiz | Answer story-based questions |
| Moses Mission Match | Connect people, places, and story clues |

The catalogue supports search, engine filters, featured quests, loading/empty/
retry states, and real per-child completion and star totals. A game detail
screen presents its sequential level map; completing a level unlocks the next
one from the progress returned by the backend.

All seven play engines build a result payload, but only the server decides
whether the level was completed and calculates its score and zero-to-three star
rating. Each attempt uses a UUID operation ID. A temporary save failure retries
the exact same operation safely, while a deterministic conflict offers a fresh
level attempt instead of silently changing the submitted result. The success
screen renders the backend's feedback and updated progress, then refreshes the
game room when the player returns.

To exercise the real flow locally, run the backend on `0.0.0.0:8000`, launch
Flutter with the appropriate `API_BASE_URL` above, then sign in as a verified
parent and select or create a child profile. The Games screen requires that
authenticated profile context; it is intentionally not an offline demo mode.

## Play release gate

Before uploading an Android App Bundle:

1. Run `flutter pub get`, `dart format --output=none --set-exit-if-changed lib test tool`,
   `flutter analyze`, and `flutter test` with the pinned Flutter toolchain.
2. Build only through `tool/build_android_release.sh` with the production API,
   owned media hosts, a fresh build number, and the upload signing secret.
3. Inspect the generated AAB's merged manifest, signing certificate, native
   libraries, and 16 KB page alignment with Android Studio/SDK tooling, then
   install the Play-generated APKs on representative physical devices.
4. Exercise registration, verification, password reset, profile management,
   narration, games, progress, reminder permission denial, session expiry, and
   both in-app and web account deletion against staging.
5. Publish and test `https://kingdom-kids.app/privacy/` and
   `https://kingdom-kids.app/account-deletion/`, then make the Play Console
   target-audience, Data safety, content-rating, and deletion declarations
   match the production vendors and behavior exactly.
