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
`logout/`, `me/`, and `kid-profiles/`.

## Stories and narration

The Story Library and full reader load from the authenticated Django endpoints
under `/api/stories/`. Requests reuse the parent session's coordinated token
refresh path, and the UI provides loading, retry, empty, search, and category
filter states.

Each child character has a backend-configured narrator personality. The app
uses `flutter_tts` to choose an installed English voice and applies the
character's configured pace and pitch. Kai, Nia, and Zuri therefore sound
different immediately without an external speech API. Exact voice timbre can
vary by device; optional hosted narration URLs are already represented in the
API for a later consistent-audio pipeline.

Android 11+ package visibility for the system TTS service is declared in the
main manifest. No microphone permission is needed because the feature only
reads story text aloud.

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
