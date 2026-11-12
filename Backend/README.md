# Kingdom Kids API

## Local development

The settings fail closed when `DJANGO_DEBUG` is missing. Explicitly opt into
development mode before every local Django command. With debug enabled, the API
uses the checked-in development-only secret, SQLite, a process-local cache, and
prints each email verification code directly in the runserver terminal.

```sh
cd Backend
export DJANGO_DEBUG=true
.venv/bin/python Core/manage.py migrate
.venv/bin/python Core/manage.py runserver 0.0.0.0:8000
```

After registration, copy the value shown beside `Code:` in the
`KINGDOM KIDS DEVELOPMENT CODE` terminal banner. Never use debug mode in a
public environment.

Debug mode accepts localhost, emulator, and changing LAN host addresses so a
physical phone can call the API without editing `ALLOWED_HOSTS`. Production
still requires an explicit `DJANGO_ALLOWED_HOSTS` value.

Run the focused game tests, the complete backend suite, and Django's sanity and
migration checks from the repository root with:

```sh
cd Backend
export DJANGO_DEBUG=true
.venv/bin/python Core/manage.py test apps.games
.venv/bin/python Core/manage.py test
.venv/bin/python Core/manage.py check
.venv/bin/python Core/manage.py makemigrations --check --dry-run
```

Environment files are ignored by Git, but Django does not load `.env` files
itself. Export the variables in the process environment or use the deployment
platform's secret/environment configuration.

## Account API

All endpoints use the `/api/accounts/` prefix. Access tokens are passed as
`Authorization: Bearer <access-token>`.

| Method | Endpoint | Purpose |
| --- | --- | --- |
| POST | `register/` | Create a pending parent account and send a six-digit email code; returns a verification challenge but no JWT |
| POST | `email-verification/confirm/` | Confirm `challenge_id` and `code`; returns the normal JWT session |
| POST | `email-verification/resend/` | Rotate a challenge after its resend cooldown |
| POST | `login/` | Sign in with `email` and `password` |
| POST | `password-reset/request/` | Return a generic recovery response and real or decoy challenge handle |
| POST | `password-reset/confirm/` | Consume a six-digit code and set a validated new password |
| POST | `account-deletion/request/` | Return a generic deletion response and send a purpose-bound six-digit code to an eligible account |
| POST | `account-deletion/confirm/` | Consume the deletion code plus exact `DELETE` confirmation and erase the account data |
| POST | `token/refresh/` | Exchange a refresh token; refresh tokens rotate |
| POST | `logout/` | Blacklist the supplied refresh token (requires access token) |
| GET | `me/` | Read the signed-in parent and their kid profiles |
| DELETE | `me/` | Permanently delete the signed-in parent account after password confirmation |
| DELETE | `unverified-account/` | Generically process password-confirmed deletion of a pending account without issuing a JWT |
| GET, POST | `kid-profiles/` | List/create the signed-in parent’s profiles |
| GET, PUT, PATCH, DELETE | `kid-profiles/<uuid:id>/` | Manage one owned profile |
| GET, PATCH | `kid-profiles/<uuid:id>/preferences/` | Read or partially update one owned child’s typed reading preferences |

Account deletion requires a valid bearer token and the current password:

```json
{"password": "the-current-parent-password"}
```

A successful `DELETE /api/accounts/me/` returns HTTP 204 and permanently
removes the parent, all child profiles and their related game/story progress,
verification/password-reset challenges, and a waitlist record with the same
email. It explicitly removes SimpleJWT's outstanding-token and blacklist rows,
and previously issued JWTs can no longer authenticate. The client must remove
its local tokens and user data after the 204 response. This operation is not
recoverable from the application; recovery would require an authorized backup-
restoration process consistent with the retention policy.

An active account that is still waiting for email verification cannot receive a
JWT. `DELETE /api/accounts/unverified-account/` accepts exact JSON fields
`email`, `password`, and `confirmation: "DELETE"` for that case. It is limited
by both client IP and a non-PII HMAC of the normalized email, performs equivalent
password-hash work for nonexistent accounts, and returns the same HTTP 204 for
missing, verified, disabled, wrong-password, and successfully deleted pending
accounts. It deletes only an active unverified account after password proof and
does not treat an independent waitlist signup as owned before email control is
proven.

Password-reset requests accept `{"email": "parent@example.com"}` and always
return HTTP 202 with the same message and a real or decoy `challenge_id`, so the
endpoint does not reveal whether an active account exists. Confirmation accepts
`challenge_id`, the six-digit `code`, `new_password`, and matching
`new_password_confirmation`, then returns HTTP 204. Codes are single-use,
short-lived, attempt-limited keyed digests; a successful password change also
invalidates existing JWTs through password-hash revocation checks. For a pending
account, that same mailbox proof verifies the address and lets the real owner
reclaim an email somebody else registered but never verified. The local console
email backend intentionally does not print password-reset credentials and
invalidates those challenges, so use a safe non-console test email service when
exercising recovery end to end.

The public website never accepts an account password. It starts deletion with
`POST /api/accounts/account-deletion/request/` and `{"email":
"parent@example.com"}`. The endpoint always returns HTTP 202 with the same
message and a real or decoy `challenge_id`; only an eligible non-staff parent
receives a code. Confirmation accepts `challenge_id`, the six-digit `code`, and
`confirmation: "DELETE"`, then returns HTTP 204 after atomically deleting the
parent, related family data, same-email waitlist row, and outstanding sessions.
Deletion codes are purpose-bound, single-use, short-lived, attempt-limited keyed
digests and cannot be reused from verification or password recovery. The
console email backend invalidates these irreversible-action challenges instead
of printing them.

Kid profiles deliberately collect only `display_name` and one controlled
`avatar_key`: `lion`, `dove`, `rainbow`, `star`, `crown`, or `sheep`.
Profile creation also requires a client-generated UUID in `operation_id`.
Replaying that ID for the same parent returns the existing profile instead of
creating a duplicate; reusing it with different profile content returns HTTP
409. An account may have 10 child profiles by default. `MAX_KID_PROFILES` can
lower or raise that limit to at most 20.

Each child profile has an independently owned preferences resource. Its first
GET or valid PATCH creates these safe defaults when no row exists yet:

```json
{
  "profile_id": "c5a35566-765a-4017-971a-fb0125bcf7cd",
  "story_text_scale": "comfortable",
  "narration_enabled": true,
  "streak_timezone_offset_minutes": null,
  "updated_at": "2026-07-15T10:30:00Z"
}
```

`story_text_scale` accepts only `comfortable`, `large`, or `extra_large`.
PATCH is partial, so omitted values are retained. The parent cannot change
`profile_id`, `streak_timezone_offset_minutes`, or `updated_at`, and both a
missing profile and another parent’s profile are reported as 404. The streak
claim service owns the timezone field; it starts as null and records the first
accepted device offset. Device display, notification permission, offline
storage, autoplay, bedtime schedules, and parent-gate policy remain outside
this API until their ownership and enforcement rules are defined.

## Story API

Story content is managed in Django admin and served to verified parent
sessions. All requests require `Authorization: Bearer <access-token>`.

| Method | Endpoint | Purpose |
| --- | --- | --- |
| GET | `/api/stories/` | List published story summaries |
| GET | `/api/stories/?search=ark&category=Faith` | Search and filter published stories |
| GET | `/api/stories/<slug>/` | Read the full story and its narrator options |

The initial migration seeds eight stories and three provider-neutral narrator
personalities. Profile avatar keys select the default narrator: `lion` → Kai,
`dove` → Nia, and `rainbow` → Zuri. The response includes safe device-speech
settings such as locale, pace, and pitch. TTS provider names and provider voice
IDs remain private server fields and are never serialized.

Inactive narrator personalities and narrations marked unavailable are omitted
from story responses. Other delivery states remain visible so the app can
disable playback while hosted audio is still processing.

Each detail response also carries `audio_url`, `audio_available`,
`duration_seconds`, `segments`, and `words`. Ready character audio can be downloaded by
the mobile reader; stories without a ready track retain device text-to-speech.
Segments contain exact passage text, UTF-16 start/end offsets, and measured
audio start/end seconds for paragraph navigation. Optional `words` contain the
same exact-text and UTF-16 fields with word boundaries measured against the
recording. The reader uses the player's actual position for word highlighting
and elapsed time; missing word cues do not produce estimated highlights.
Tracks are bound to a SHA-256 of the story body so changing a story
does not keep serving an obsolete generated reading.

### Original synthetic character narration

`scripts/generate_character_narration.py` creates original voices from text
descriptions using local Qwen3-TTS through MLX-Audio on Apple Silicon. This is
separate from the older stock-voice audition generator below. The model and
isolated generation environment are downloaded once; no voice API key or paid
generation service is required. Voice quality must be auditioned before a
track is selected for release.

Generated audio and a versioned manifest live beneath
`Backend/media/character_narration/`, which is ignored by Git. Install completed
assets after migrating the backend:

```sh
cd Backend
DJANGO_DEBUG=true .venv/bin/python Core/manage.py migrate
DJANGO_DEBUG=true .venv/bin/python Core/manage.py install_character_narration \
  --manifest media/character_narration/manifest.json
```

Refresh the exact published story inputs and render only the accepted character
references with the isolated generation runtime:

```sh
DJANGO_DEBUG=true .venv/bin/python Core/manage.py export_character_story_inputs
~/.cache/kingdom-kids-voices/.venv/bin/python scripts/generate_character_narration.py \
  story --character accepted --story-dir media/character_narration/story_inputs
```

The generation runtime requires Python 3.12, `mlx-audio==0.5.7`,
`soundfile==0.13.1`, and `ffmpeg`. Load one model at a time on an 8 GB Mac.
Kai's approved reference is option 2 (`boy2`); the explicit human acceptance
supersedes its earlier rejection and both decisions remain in review history.
Rejected and unselected references are excluded from installation and story
generation.

After generation exits, align the canonical story text against the existing
recordings before reinstalling the manifest:

```sh
~/.cache/kingdom-kids-voices/.venv/bin/python scripts/align_character_narration.py \
  --model-dir ~/.cache/kingdom-kids-voices/models/models--openai--whisper-base.en/snapshots/911407f4214e0e1d82085af863093ec0b66f9cd6 \
  --character kai --character nia --character zuri --write
```

Alignment uses local Whisper cross-attention and dynamic time warping with the
exact canonical tokens. It preserves audio checksums and records diagnostics.
Collapsed token boundaries may become short phrases using their measured
outer boundaries; individual word times are never spread evenly or invented.
The generated QA report retains low-confidence boundaries for review. Forced
alignment estimates timing; it does not certify voice quality or intelligibility.

Use `--samples-only` to attach auditions without replacing any story track.
The installer validates every file, content hash, exact story revision, and
complete measured passage coverage before an atomic database update. When word
cues are included, they must also cover every story word with valid recorded
times. Repeating the same install is safe. Kai uses `lion`, Nia `dove`, and
Zuri `rainbow`.

In development the API returns absolute local audio URLs for existing files.
Production still requires controlled HTTPS media storage and an explicitly
allowlisted hostname; a local filesystem track is never advertised as
production audio. Missing files or changed story text report no available
audio, rather than a broken playable URL.

### Older stock-voice narrator auditions

The first in-app audition maps Kai to Cedar, Nia to Marin, and Zuri to Coral.
Generate only variant A with the local generator, then atomically attach the
three cached files to the narrator records:

```sh
cd Backend
python3 scripts/generate_voice_auditions.py --variant a
export DJANGO_DEBUG=true
.venv/bin/python Core/manage.py migrate
.venv/bin/python Core/manage.py install_round_one_voice_samples
```

Generation requires an `OPENAI_API_KEY` with available API billing/quota and
audio-model access. Before generated narration is exposed to families, the
product must also show a clear disclosure that the character audio is
AI-generated.

The installer requires all three valid MP3 files in
`Backend/media/voice_auditions/`; if one is missing or malformed, it changes no
database records. Running it again is safe. Story detail responses expose each
available file as an absolute `sample_url`, built from the phone's API request
host, while the provider and provider voice ID stay private.

Django serves these local media files only while `DJANGO_DEBUG=true`. Debug
media URLs are deliberately public and do not require the story API's JWT;
audition clips must therefore contain no private content. The MP3 files remain
ignored by Git and must never be committed as source code.

Production deliberately does not serve or serialize local HTTP media URLs.
Put production cover art and narrator/story audio on controlled HTTPS
object storage or a CDN, save those external URLs in Django admin, and list each
exact hostname in `DJANGO_CONTENT_MEDIA_HOSTS`. Do not include a scheme, path,
wildcard, or port in that comma-separated allowlist. Any external media URL
whose HTTPS hostname is not allowlisted is rejected on validation and omitted
from API responses. Do not depend on the container's local `Backend/media/`
directory in production; it is neither a durable media store nor a public media
server. Cached files can instead remain on a durable mounted media volume:
set `DJANGO_MEDIA_ROOT` to that volume and `DJANGO_MEDIA_URL` to the owned HTTPS
CDN/web-server base that serves the same relative filenames. Story tracks and
auditions are exposed only when the mounted file exists and its public URL is
allowlisted. This configuration preserves the installed character choices;
it does not generate or replace narration.

## Game API

The game catalogue is profile-scoped because stars, best scores, and unlocked
levels belong to a child rather than the parent account. All three endpoints
require a verified parent's bearer token, and `profile_id` must identify one of
that parent's kid profiles. A profile owned by another parent is returned as a
404 rather than disclosed.

| Method | Endpoint | Purpose |
| --- | --- | --- |
| GET | `/api/games/?profile_id=<uuid>` | List published games with this child's progress |
| GET | `/api/games/<slug>/?profile_id=<uuid>` | Read the game's three ordered, playable levels |
| POST | `/api/games/<slug>/submit/` | Evaluate a level result, award stars, and update progress |

Submissions use a client-generated UUID so a retry cannot award progress twice:

```json
{
  "profile_id": "c5a35566-765a-4017-971a-fb0125bcf7cd",
  "level_number": 1,
  "operation_id": "78cc7e4f-2960-431c-b0ae-d02774920220",
  "result": {"sequence": ["day-1", "day-2", "day-3"]}
}
```

The current migration chain retains historical definitions and progress while
publishing **ten games / 30 levels**: five puzzles and five quizzes. The
separately reviewed matching release adds **five games / 15 levels**, producing
the approved **15-game / 45-level** catalogue. Its default validation mode makes
no database changes; staging and publication are explicit administrative steps.
The five matching games are not installed by schema migrations.

| Game | Slug | Engine |
| --- | --- | --- |
| Esther Brave Quiz | `esther-quiz` | Quiz |
| Noah's Ark Quiz | `noah-quiz` | Quiz |
| David and Goliath Quiz | `david-quiz` | Quiz |
| Jonah and the Big Fish Quiz | `jonah-quiz` | Quiz |
| The Lost Sheep Quiz | `lost-sheep-quiz` | Quiz |
| Puzzle Quest | `puzzle-quest` | Puzzle |
| Esther puzzle | `puzzle-esther` | Puzzle |
| Noah puzzle | `puzzle-noah` | Puzzle |
| David puzzle | `puzzle-david` | Puzzle |
| Lost Sheep puzzle | `puzzle-lost-sheep` | Puzzle |
| Joseph's Coat Studio | `josephs-coat-studio` | Matching release |
| Ruth's Harvest | `ruths-harvest` | Matching release |
| Find My Sheep | `find-my-sheep` | Matching release |
| Creation: Match & Bloom | `creation-match-bloom` | Matching release |
| Esther's Celebration Table | `esthers-celebration-table` | Matching release |

### Reviewed content bootstrap (SQLite or PostgreSQL)

After applying migrations to the intended database, validate the immutable
`published_matching_release_v1.json` bundle:

```sh
python Core/manage.py install_published_matching_release
python Core/manage.py install_published_matching_release --apply
python Core/manage.py install_published_matching_release --apply --publish
```

The first command is a dry-run. The second stages missing games unpublished;
the third explicitly publishes only the five reviewed games. Existing published
status is preserved. Repeating an apply retains game/level IDs and performs no
rule replacement. A different existing game identity or level rules rejects
the entire release, including unplayed conflicts; use a separately reviewed
revision rather than overwriting editorial content. Other games, accounts,
profiles, attempts, progress, XP and streak data are never imported or deleted.
PostgreSQL duplicate invocations serialize on a release-scoped transaction
lock. Run bootstrap as a controlled release step without simultaneous content
editing. The older `install_matching_studio`, `install_matching_collection` and
`install_ark_garden` commands remain intentionally SQLite-only review tools.

The published story library contains **11 stories**. Migrations create narrator
placeholders, not recordings: **33 approved tracks** (Kai, Nia and Zuri for each
story) plus **three approved character samples** must be installed separately.
`content/releases/character_narration_v1_manifest.json` is metadata only. It
merges the accepted base, additional and repaired recordings, retains all exact
file/text hashes and measured timing arrays, and excludes the two editorially
hidden stories. The existing original manifests remain available for review;
installing the whole additional/repair manifest after retirement would correctly
reject its unavailable-story entries.

Stage the reviewed release manifest beneath the configured `MEDIA_ROOT`, with
the approved audio files at their exact relative paths. Validate without writes:

```sh
python Core/manage.py install_character_narration \
  --manifest "$APPROVED_MEDIA_ROOT/release-manifest.json" --dry-run
```

The default importer continues to attach validated local files. For separately
uploaded files on an actual, controlled HTTPS object-storage/CDN origin, configure
its exact hostname in `DJANGO_CONTENT_MEDIA_HOSTS` and provide that real base URL:

```sh
python Core/manage.py install_character_narration \
  --manifest "$APPROVED_MEDIA_ROOT/release-manifest.json" \
  --hosted-base-url "$APPROVED_MEDIA_BASE_URL" --dry-run
```

Only after validation and the upload have been independently verified, repeat
without `--dry-run` to store hosted metadata. Hosted mode still reads and checks
every staged approved byte, exact story revision and complete measured timing
coverage before one atomic database update. It clears the corresponding local
file references and records allowlisted HTTPS sample/audio URLs; it neither
uploads files nor proves remote availability. Existing narration IDs, character
choices and historical rewards remain unchanged. HTTP, unowned/credentialed
origins, query/fragment bases and unsafe relative paths are rejected.

Before public launch, verify all 15 games / 45 levels, 11 visible stories,
33 current READY tracks and three samples, then verify actual uploaded hashes,
content types, range requests and playback from the chosen origin. Metadata
unit tests alone do not establish CDN readiness or listening quality. No
production hostname, provider, secret or URL is supplied by these commands.

Level responses contain the presentation content needed to play, but the
serializer strips private quiz answers, ordering sequences, and matching pairs
before sending a level to the device. Memory match keys are intentionally
public so the app can reveal a local pair immediately; the server still
recomputes completion, efficiency, score, and stars from the submitted cards.
Puzzle levels expose one high-resolution artwork key, its 2×2 through 3×3
grid, slot coordinates, and each opaque piece's crop coordinates and accessible
label. The explicit piece-to-slot solution remains private. A puzzle submission
uses this result shape:

```json
{
  "placements": [
    {"piece_id": "golden-dove", "slot_id": "slot-1-2"},
    {"piece_id": "warm-sunbeam", "slot_id": "slot-1-1"}
  ],
  "moves": 4,
  "elapsed_seconds": 32
}
```

Every submitted piece and slot may appear at most once. The engine rejects
unknown IDs, unsupported result fields, impossible move counts, and out-of-range
time values. Correct placement supplies 70% of the score; a completed puzzle
can earn the remaining 30% from deterministic move and time efficiency.

Jonah's Ocean Maze publishes a `sailing` config for a continuous 60-second,
1200-metre voyage. It contains normalized obstacle positions, collision radii,
the three-hit limit, and the boat's steering speed. Its original `grid` remains
available for older app versions.
Sailing submits `result.voyage` with `duration_ms: 60000` and a `samples` list
of `[time_ms, x]` pairs. The app records these every 100 milliseconds, beginning
at `[0, 0]` and ending at 60000 milliseconds. The server requires increasing
integer timestamps, gaps of at most 250 milliseconds, finite x in `[-1, 1]`,
and movement bounded by the authored steering speed. It derives unique
obstacle collisions from these samples; submitted hit counts or victory fields
are rejected. A full voyage with zero, one, or two hits scores 100, 85, or 65
and earns three, two, or one star respectively. Three or more hits fails the
level, earns no stars, and does not unlock the next level. The app offers a
local retry as soon as the third hit occurs, without submitting a truncated
voyage. Existing quest XP and idempotent submission rules remain unchanged.

Red Sea Path also retains its legacy grid, while current apps use its `crossing`
config: ten travellers in 45 seconds, fifteen in 30 seconds, and twenty in
15 seconds across its three levels. Explicit traveller IDs and labelled fathers,
mothers and children share a normalized dry-path `drop_zone`.
The optional `drop_zone.polygon` follows the widening visible lane with three to
sixteen finite, normalized vertices forming a convex polygon. Its edges count
as dry ground; it replaces rectangular containment when present. Older courses
and clients can continue to use the retained rectangle coordinates. The timer begins
after Moses opens the sea, excludes pauses, and stops when the last traveller is
released onto the path. Travellers then finish walking before the app submits;
this final animation does not consume placement time. The result is
`{"crossing":{"elapsed_ms":20000,"placements":[...]}}`, with each real release
recorded as `{"traveller_id":"traveller-1","x":0.5,"y":0.6,"released_at_ms":3000}`.
The server accepts each authored ID once, requires finite coordinates inside
the dry drop zone, and verifies ordered release times within the elapsed timer
and time limit. All travellers placed earns 100 points/three stars within 60%
of that round's time limit, 85 points/two stars within 85%, or 65 points/one star
within the full limit. For the first round those boundaries are 27, 38.25 and
45 seconds; later rounds use their shorter authored timers.
A timeout sends only the travellers actually placed and earns no completion or
stars. A late final drop remains valid while walking finishes afterward. The
server rejects water drops, unknown or duplicate IDs, and submitted completion,
score, rescued-count or walk-duration fields. No grid route is manufactured
for the new crossing engine.

The server validates every engine's result against its private level config and
is the sole source of `completed`, `score`, and `stars`. It also validates grid
bounds, walls, adjacent path steps, target geometry, unique matching cards, and
memory move/time metrics. Sending client-computed score fields is rejected.
Levels unlock in order. An identical `operation_id` and request receives the
original attempt with HTTP 200; changing any part of an already-used operation
returns HTTP 409.

This validation protects data integrity for ordinary app use, but the gameplay
evidence itself—including moves, paths, placements, answers, and elapsed time—is
reported by the client. Story starts/completions and timezone offsets are also
client-reported. A modified client can therefore fabricate activity or optimize
reported metrics. Treat all scores, stars, XP, badges, streaks, and story/game
telemetry as private, noncompetitive gamification only. They must not determine
prizes, payments, eligibility, public rankings, or leaderboards. Any future
competitive feature needs a separate threat model and trusted event/anti-cheat
design before launch.

Progress stores each level's best score, best star rating, completion state,
and evaluated-attempt count. A game's `total_stars` is the sum of its three
best level ratings, so replaying or retrying a request cannot duplicate stars.
The first accepted submission returns HTTP 201 and includes the updated
profile-scoped progress in the same response.

### Authoring games in Django admin

Games and their levels can be managed under `/admin/`. A game defines its
engine, catalogue copy, artwork key, accent, difficulty, estimated duration,
featured/published state, and sort order. Levels are ordered challenges with
instructions, `max_score`, three star thresholds, and engine-specific JSON in
`config`. Attempts are immutable in admin, while progress is an inspectable
server-owned summary rather than editable game content.

Every level is validated on save, including saves made outside admin. Level
numbers must be contiguous from 1, must be positive and unique within a game,
and a middle level cannot be deleted while higher levels remain. The validator
also rejects malformed or unsafe engine configuration:

- quiz questions need unique question/option IDs and an answer referencing an
  available option;
- ordering and matching answers must use every authored item exactly once;
- memory cards must have unique IDs and exactly two cards per match key;
- maze/path grids must stay within the 2–10 row/column limits and contain a
  traversable start-to-finish route;
- sailing courses need finite ocean geometry, unique ordered obstacles with
  room to steer, clear launch and landing water, and a 60-second duration;
- crossing courses need unique labelled travellers, a bounded placement timer,
  and a finite normalized dry-path drop rectangle, optionally replaced by a
  convex polygon matching the visible land;
- aim levels require bounded canvas/target geometry and 1–10 allowed shots;
- puzzle levels require one crop and one slot for every 2×2–3×3 grid position,
  a one-to-one private solution, and bounded preview, move, and time targets;
- star thresholds must be three distinct, increasing integers between zero and
  `max_score`.

Keep private quiz, ordering, and matching answer fields in the backend
configuration. Do not duplicate them in mobile code or add them to the public
serializer; the result evaluator needs those private values to remain the
authoritative scoring source.

## Kid progress API

Progress endpoints require a verified parent's bearer token and return 404 for
both a missing profile and a profile owned by another parent.

| Method | Endpoint | Purpose |
| --- | --- | --- |
| POST | `/api/progress/kid-profiles/<uuid:profile_id>/activity-events/` | Record an idempotent story start or completion for one owned child |
| POST | `/api/progress/kid-profiles/<uuid:profile_id>/streak-presentations/claim/` | Record today's app visit and claim its one streak celebration |
| GET | `/api/progress/kid-profiles/<uuid:profile_id>/summary/` | Read identity, game/story stats, badges, streak, and recent activity for one owned child |

The mobile app sends a fresh UUID for each story action. Only these three body
fields are accepted:

```json
{
  "operation_id": "78cc7e4f-2960-431c-b0ae-d02774920220",
  "event_type": "story_completed",
  "story_id": "1294e5b0-3954-43d8-b519-d5172c93f779"
}
```

`event_type` accepts only `story_started` or `story_completed`, and new events
must reference a published story. An exact operation replay returns the stable
event with HTTP 200, while reusing the operation UUID for different content
returns HTTP 409. The event ledger has no public GET endpoint.

Story-event responses include server-owned `xp_awarded` and a nullable
`level_milestone`. The first recorded completion of a story earns 100 XP;
starts and subsequent completions of the same story earn zero. An exact
operation replay returns its original award and milestone, even after later
activity has raised the child's level. Clients cannot submit reward metadata.

The optional `timezone_offset_minutes` query parameter is the device's minutes
east of UTC (`60` for UTC+01:00). It defaults to UTC and accepts only integer
values from `-840` through `840`. Before the first streak claim it controls the
summary buckets; after a claim binds the profile to an offset, the stored offset
overrides this query value. Streak days and weekly activity are calculated in
that fixed local offset. The response shape is:

```json
{
  "profile": {
    "id": "c5a35566-765a-4017-971a-fb0125bcf7cd",
    "display_name": "Amara",
    "avatar_key": "star"
  },
  "level": {
    "number": 3,
    "title": "Brave Believer",
    "xp": 700,
    "next_level_xp": 900
  },
  "xp_breakdown": {"quests": 500, "stories": 200, "streaks": 0},
  "stats": {
    "completed_game_levels": 3,
    "total_game_levels": 27,
    "game_stars": 10,
    "max_game_stars": 81,
    "games_started": 2,
    "games_completed": 1,
    "total_stories": 8,
    "stories_started": 3,
    "stories_completed": 2,
    "earned_badges": 3
  },
  "badges": [
    {
      "key": "first-play",
      "title": "First Play",
      "description": "Finish your first game attempt.",
      "icon_key": "play-spark",
      "target": 1,
      "earned": true,
      "progress": 1
    }
  ],
  "activity_streak": {"current_days": 2, "longest_days": 4},
  "weekly_activity": [
    {
      "week_start": "2026-06-15",
      "label": "Jun 15",
      "attempts": 2,
      "story_completions": 1,
      "activities": 3
    }
  ],
  "last_activity_at": "2026-07-15T08:00:00Z"
}
```

Progression combines earned quest, reading, and daily-visit XP:

- each distinct completed level contributes 100 XP;
- each best level star contributes 20 XP;
- each distinct completed story contributes 100 XP, including stories that
  were later unpublished;
- each server-recorded daily app visit contributes 20 XP, once per child and
  local date; ending a streak does not remove previously earned XP;
- a new level begins every 300 lifetime XP, and `next_level_xp` is the absolute
  threshold for the next level;
- levels 1–2 are **Little Explorer**, 3–5 **Brave Believer**, 6–9 **Faith
  Adventurer**, and 10+ **Kingdom Champion**;
- published game levels define the completion and maximum-star totals; unknown
  or malformed historical progress entries do not inflate the summary.

There are five computed badges: **First Play** at one accepted attempt, **Star
Seeker** at 10 best stars, **Level Legend** at five completed levels, **Game
Explorer** after attempts in three games, and **Quest Champion** after every
level in one game is complete. Badge `progress` is capped at its `target` and
`earned_badges` is the number currently earned.

Opening Home records that child's local calendar day through the streak claim
endpoint, so opening the app is enough to continue a streak. Accepted game
attempts and recorded story completions also qualify; all activity on the same
local date is deduplicated into one streak day. A story start updates story
discovery stats but deliberately does not inflate the streak. The server
returns `first_streak` or `continued` in `presentation` only on the first claim
for that child and local date. Every claim response includes `show`,
`profile_id`, `xp_awarded`, and nullable `level_milestone`; a repeat claim has
`show: false`, omits `presentation`, and replays the saved reward receipt so a
lost response can still deliver its level milestone. It does not award XP
again. There is no `at_risk` screen state.

Historical completed stories and daily visits contribute to lifetime XP
automatically. Their empty reward receipts return zero awarded XP and no
milestone, so old activity does not manufacture a new celebration. New
story, visit, and game rewards share the child's transaction lock and the
same combined level calculation.

The claim body accepts only the required local offset:

```json
{"timezone_offset_minutes": 60}
```

The first accepted claim binds that offset to the child. A different offset is
accepted only after 24 hours from the latest recorded visit; an earlier change
returns HTTP 409 with `code: streak_timezone_change_too_soon`, `retry_after`, and
a matching `Retry-After` header. This limits timezone hopping while still
allowing travel and daylight-saving changes.

`current_days` stays active when the last qualifying activity was today or
yesterday; `longest_days` is the longest consecutive run in the full qualifying
history. `weekly_activity` always contains the five Monday-starting local weeks
from oldest to current. It exposes learning events—game `attempts`,
`story_completions`, and their summed `activities`—without treating a plain app
visit as a learning event. `last_activity_at` remains the last absolute UTC
game/story timestamp. The five badges remain based on authoritative game
progress; overall XP also includes completed stories and daily visits.

Registration responds with HTTP 202 and this shape:

```json
{
  "verification": {
    "challenge_id": "3ce09cd7-8321-4ad1-94ef-f476fa4f8114",
    "destination_hint": "p***@example.com",
    "expires_in": 600,
    "resend_after": 60
  }
}
```

The code is single-use and expires after ten minutes by default. The parent has
one shared budget of five wrong guesses in a ten-minute window, even if codes
are replaced by registration or resend. Reaching that budget blocks every code
and resend for fifteen minutes; responses keep the same generic invalid-code
shape. Once the lock expires, resend can issue a fresh code. Only a keyed digest
is stored. Confirmation is the first endpoint that issues access and refresh
tokens. A correct-password login for a pending account returns HTTP 403 with
`code: email_verification_required` and the same verification metadata so the
app can resume the flow.

Re-registering never resets an existing account's password. An active,
unverified parent who supplies the same valid credentials can resume the
existing challenge flow; the challenge is reused while cooling down and rotated
when resend is available. Every other duplicate—including verified, disabled,
or wrong-password accounts—receives the same non-actionable HTTP 202 shape with
a random unstored challenge ID. That response does not disclose account state,
send a new code, reset the guess budget, create another user, or issue a JWT.

If the configured email backend rejects a message after its challenge has been
committed, registration or resend still returns HTTP 202. The response includes
`code: verification_delivery_delayed`, `verification_delivery_delayed: true`,
and the persisted replacement challenge metadata. Its `resend_after` is zero,
so the app can offer an immediate retry. The six-digit code is never included
in this recovery response. A durable external delivery queue remains the
recommended production evolution when retry guarantees are required.

## Placeholder APIs

The `videos` and `bible` Django apps currently contain placeholder models and
empty URL configurations. `/api/videos/` and `/api/bible/` do not yet provide
content endpoints. Do not describe them as backend-powered features in release
or Play Store materials until their models, serializers, permissions, content
licensing rules, endpoints, and tests are implemented.

## Production and deployment

Production settings fail closed. All commands below assume the deployment
platform has already injected its environment variables; the application does
not parse `.env` files.

### Required environment

Set these for every web, migration, and administrative process:

- `DJANGO_DEBUG=false`. It is mandatory; omitting or misspelling it stops
  startup.
- `DJANGO_SECRET_KEY` with a unique random value of at least 50 characters.
- `DJANGO_JWT_SIGNING_KEY` with a different unique random value of at least 50
  characters. Also set stable `DJANGO_JWT_ISSUER` and `DJANGO_JWT_AUDIENCE`
  values shared by all instances. Rotating the JWT key invalidates active
  access and refresh tokens.
- `DJANGO_ALLOWED_HOSTS` as comma-separated exact API/admin hostnames, for
  example `api.kingdomkids.example`. Production rejects `*`.
- `DJANGO_DATABASE_URL` pointing to PostgreSQL. SQLite is development-only
  because verification and progress transitions require real row-level locks.
- `DJANGO_CACHE_URL` pointing to one shared Redis database used by every web
  worker and instance. Throttle state must not use a process-local cache.
- `EMAIL_VERIFICATION_PEPPER` as an independent random value of at least 32
  characters. Rotating it invalidates outstanding verification codes.
- `PASSWORD_RESET_PEPPER` as another independent random value of at least 32
  characters. It must not equal the Django secret, JWT key, or verification
  pepper; rotating it invalidates outstanding password-reset codes.
- `ACCOUNT_DELETION_PEPPER` as a fourth independent random value of at least 32
  characters. It must not equal any other signing secret; rotating it
  invalidates outstanding public deletion codes.
- A real `DJANGO_EMAIL_BACKEND` and non-localhost
  `DJANGO_DEFAULT_FROM_EMAIL`, plus the host, port, credentials, TLS setting, or
  provider-specific configuration required by that backend.

The built-in SMTP backend must enable exactly one transport mode:
`DJANGO_EMAIL_USE_TLS=true` for STARTTLS (normally port 587), or
`DJANGO_EMAIL_USE_SSL=true` for implicit TLS (normally port 465). Production
rejects cleartext SMTP and rejects enabling both modes together.

### Resend transactional email

The existing Django SMTP transport supports Resend without an additional SDK.
Verification, password recovery, and account-deletion emails all use that shared
transport. The website waitlist stores an explicit signup; it does not send a
welcome message or subscribe an address to a third-party marketing list.

First verify a domain you control in the Resend dashboard. A sending subdomain
such as `notify.kingdom-kids.app` is suitable if that is the domain you choose;
it is an example until its DNS records are installed and Resend reports it
verified. Copy the actual DKIM and return-path DNS values from the dashboard.
Keep the apex domain's existing receiving/forwarding MX and SPF records, website
records, and nameservers intact. Resend sending configuration does not create a
monitored privacy/support inbox.

Configure the backend process with:

```dotenv
DJANGO_EMAIL_BACKEND=django.core.mail.backends.smtp.EmailBackend
DJANGO_EMAIL_HOST=smtp.resend.com
DJANGO_EMAIL_PORT=587
DJANGO_EMAIL_HOST_USER=resend
DJANGO_EMAIL_HOST_PASSWORD=
DJANGO_EMAIL_USE_TLS=true
DJANGO_EMAIL_USE_SSL=false
DJANGO_EMAIL_TIMEOUT_SECONDS=10
DJANGO_DEFAULT_FROM_EMAIL=Kingdom Kids <no-reply@YOUR_VERIFIED_SENDING_DOMAIN>
```

Store a sending-only, domain-scoped Resend key as the backend's `RESEND_API_KEY`
secret. The SMTP settings consume that key only for `smtp.resend.com`. An
explicit `DJANGO_EMAIL_HOST_PASSWORD` takes precedence for compatibility with
existing SMTP deployments. Do not put either secret in Astro `PUBLIC_*`
variables, Flutter definitions, source files, logs, or a browser bundle.
Development with the console backend remains unchanged. Selecting Resend without
a key, a valid non-local sender, or a matching encrypted port fails at startup;
this checks configuration, not actual account authorization or inbox delivery.

With those environment values injected, `python Core/manage.py check_resend_email`
checks configuration without network access. Add `--connect` to verify encrypted
SMTP authentication without submitting any message or recipient. Its output is
sanitized; neither mode proves that the sender domain is verified or that mail
will arrive in an inbox.

For implicit TLS, use port `465`, `DJANGO_EMAIL_USE_SSL=true`, and
`DJANGO_EMAIL_USE_TLS=false` together. Do not use both encryption modes at once.
Environment files are not automatically loaded; inject these values into the
actual backend process and coordinate its restart rather than changing the
currently running phone-review server unexpectedly.

Before release, verify the sender in Resend, configure the backend's secrets,
and test one explicitly authorized recipient through the real delivery path.
Provider acceptance does not guarantee inbox placement. Do not send real test
emails or submit deletion flows as a configuration smoke test without specific
authorization. The isolated mocked transport tests are:

```sh
DJANGO_DEBUG=true .venv/bin/python Core/manage.py test apps.accounts.test_resend_email
```

Official setup references: [Resend SMTP](https://resend.com/docs/send-with-smtp)
and [verified sending domains](https://resend.com/docs/dashboard/domains/introduction).
The static website also needs its production `/api/*` reverse proxy to reach
the deployed Django server; connecting Resend does not configure website routing.

Generate each secret independently and store it in the platform's secret
manager, never in Git, an image, a mobile build, or logs. A local generator is:

```sh
python3 -c "import secrets; print(secrets.token_urlsafe(64))"
```

Run it separately for each secret. Do not reuse database, Redis, email, Django,
JWT, or verification credentials.

### PostgreSQL and Redis transport

Use `DJANGO_DB_SSLMODE=verify-full` and set `DJANGO_DB_SSLROOTCERT` to the
provider CA file when supported. `require` is accepted when that is the
provider's documented secure mode, but `verify-full` also verifies the server
identity. Production rejects `disable`, `allow`, and `prefer`. Tune
`DJANGO_DB_CONN_MAX_AGE_SECONDS` for the provider or pooler; `0` disables
persistent connections. `DJANGO_DB_CONNECT_TIMEOUT_SECONDS` bounds connection
establishment.

Prefer a `rediss://` Redis URL. Plain `redis://` is rejected in production
unless `DJANGO_CACHE_ALLOW_INSECURE=true` is deliberately set for a provider's
trusted private network. Redis stores throttle counters, not authoritative
parent or child data, but an outage makes readiness fail and should stop new
traffic from reaching that instance.

### HTTPS and trusted proxies

Expose the API only over HTTPS. When TLS terminates at a reverse proxy or load
balancer, set `DJANGO_TRUST_X_FORWARDED_PROTO=true` only if that proxy removes
any client-supplied `X-Forwarded-Proto` header and writes its own trusted value.
Pass the original allowed `Host` value to Django.

Set `DJANGO_API_NUM_PROXIES` to the exact number of trusted reverse proxies
between the public client and Django. Those proxies must strip or normalize
spoofed forwarding headers; otherwise client-IP throttles can be evaded or can
group unrelated families under one address. Keep it `0` when Django receives
the public client address directly. Enforce request-size and primary abuse/DDoS
limits at the ingress as well—application throttles are a secondary control.

The app sets a one-year HSTS policy in production. Leave
`DJANGO_HSTS_INCLUDE_SUBDOMAINS` and `DJANGO_HSTS_PRELOAD` false until every
current and future subdomain is HTTPS-only and the domain satisfies preload
requirements.

This backend does not currently enable cross-origin browser requests. Host the
website and `/api/` behind the same origin/reverse proxy, as the waitlist form
expects, or add and review a narrow origin allowlist before deploying them on
separate origins. Native Flutter HTTP clients do not require CORS.

### Production media and static files

Set `DJANGO_CONTENT_MEDIA_HOSTS` only to exact, owned HTTPS hostnames that may
appear in child-facing cover and audio URLs, for example:

```text
DJANGO_CONTENT_MEDIA_HOSTS=media.kingdomkids.example,cdn.kingdomkids.example
```

Do not include schemes, paths, ports, or wildcards. Keep the value blank if no
external media should be exposed. Production API serializers omit every URL
outside this allowlist and omit relative or HTTP production media URLs.
WhiteNoise serves versioned Django/admin static assets only; it does not serve
`MEDIA_ROOT`. Production media must live in durable object storage/CDN under an
allowlisted host. Configure content type, size, access policy, retention, and
backup/versioning at that service.

For the existing cached character files, a durable media volume served through
an owned HTTPS origin can use:

```text
DJANGO_MEDIA_ROOT=/var/lib/kingdom-kids/media
DJANGO_MEDIA_URL=https://media.kingdomkids.example/
```

Mount the same complete approved files beneath that root and configure the
external media origin to serve their matching relative paths. Setting a URL
alone does not upload files or establish durable storage. The Docker image
contains no narration files, and Django/WhiteNoise do not serve this volume in
production. Missing files continue to report unavailable audio without
substituting device speech.

On Render, attached disks are available only to their single runtime instance.
Build/pre-deploy commands, one-off jobs and other services cannot access that
disk; attaching one also disables zero-downtime deployment. A separate media
service therefore cannot simply share the API service's disk. Prefer an owned
HTTPS object-storage/CDN origin for these immutable recordings, or explicitly
design and review a single-service media origin before choosing the volume
approach. Do not put a disk-reading audio installer in a Render pre-deploy hook.
See [Render persistent disks](https://render.com/docs/disks) and
[deploy commands](https://render.com/docs/deploys).

`DJANGO_MAX_NARRATOR_AUDIO_BYTES` is the hard limit for admin narrator uploads.
The `DJANGO_DATA_UPLOAD_*` settings bound in-memory request data and field/file
counts; `DJANGO_FILE_UPLOAD_MAX_MEMORY_BYTES` controls when files spool to disk,
not their maximum accepted size. Enforce the desired hard request-body limit at
the ingress as well.

### Non-container deployment

From `Backend/`, install the pinned dependencies. With the production
environment already present, validate, migrate once as a release task, collect
static files, and start Gunicorn:

```sh
python3 -m venv .venv
.venv/bin/python -m pip install --requirement requirements.txt
.venv/bin/python Core/manage.py check --deploy
.venv/bin/python Core/manage.py migrate --noinput
.venv/bin/python Core/manage.py collectstatic --noinput
.venv/bin/gunicorn --chdir Core Core.wsgi:application \
  --bind 0.0.0.0:8000 --workers 3 --timeout 30 --graceful-timeout 30 \
  --access-logfile - --error-logfile -
```

Do not use Django's `runserver` in production. Run migrations once per release,
not independently in every web worker. Take a current database backup before a
destructive or irreversible migration and test roll-forward/rollback procedures
in staging.

### Docker deployment

From the repository root:

```sh
docker build --tag kingdom-kids-api:release Backend
docker run --rm --env-file Backend/.env.production \
  kingdom-kids-api:release python Core/manage.py check --deploy
docker run --rm --env-file Backend/.env.production \
  kingdom-kids-api:release python Core/manage.py migrate --noinput
docker run --rm --env-file Backend/.env.production -p 8000:8000 \
  kingdom-kids-api:release
```

The image build runs `collectstatic`, makes the application tree read-only, and
starts Gunicorn as an unprivileged user. A platform secret manager is preferable
to a filesystem `.env.production`; that filename is shown only to make the
one-off commands concrete and must remain untracked. Use immutable image tags
in a real release.

### Health checks

Configure the platform probes as follows:

| Endpoint | Meaning | Success |
| --- | --- | --- |
| `GET /health/live/` | The Django process can answer HTTP; no dependency access | HTTP 200 |
| `GET /health/ready/` | PostgreSQL passes a query and the shared cache passes a write/read probe | HTTP 200; HTTP 503 when unavailable |

Both responses are deliberately small and disclose no infrastructure details.
Only these two exact health paths bypass Django's HTTPS redirect, allowing an
internal HTTP probe to execute the real handler. This matters on platforms such
as Render, which also consider 3xx responses healthy: a redirect must not skip
the dependency check. All account, admin and API paths retain HTTPS enforcement.
When TLS terminates at the platform proxy, configure its trusted forwarded
protocol header as described above. See the source-only
[Render preparation runbook](deploy/README.md) for its five-second health budget
and remaining deployment inputs.
Use liveness to restart a stuck process and readiness to remove an instance from
traffic. Do not make liveness depend on PostgreSQL or Redis.

### Operations before launch

- Verify registration, email verification, resend, login, password recovery,
  refresh rotation, logout, and authenticated account deletion against the
  production email and HTTPS domains. Monitor email acceptance,
  bounce/rejection, and delivery-delay rates; the API's immediate retry state is
  not a durable mail queue.
- Send stdout/stderr logs to centralized retention and alerting. Keep
  `DJANGO_LOG_LEVEL=INFO` for normal production use and alert on sustained 5xx,
  readiness failures, unusual 401/403/429 rates, email failures, latency, and
  PostgreSQL/Redis connection saturation. Never log passwords, JWTs,
  verification codes, peppers, or full child data.
- Back up PostgreSQL with encryption, restricted access, tested point-in-time
  recovery, documented retention, and recurring restore drills. Ensure backup
  retention and deletion handling match the published privacy policy, including
  the account-deletion commitment. Back up or version production media at its
  external storage provider.
- Schedule `python Core/manage.py flushexpiredtokens` and
  `python Core/manage.py purge_expired_auth_challenges` daily with the
  production environment. The first removes expired SimpleJWT blacklist rows;
  the second removes consumed, invalidated, and expired email challenges after
  `AUTH_CHALLENGE_RETENTION_DAYS` (30 by default).
- Run the full backend test suite, `check --deploy`, migration drift check, and a
  staging smoke test on every release. Confirm the reverse proxy preserves only
  trusted forwarding headers and that `/media/` is not routed to the app in
  production.

## Square sandbox preparation (disabled)

`apps.billing` is a backend-only sandbox foundation. `SQUARE_SANDBOX_ENABLED`
defaults to false; blank credentials do not block ordinary authentication or
content access. The signed receipt route is
`POST /api/billing/square/webhook/`, which returns 404 while disabled. The
separately disabled parent checkout routes are documented below. No checkout,
card collection or subscription purchase is active. Confirmed commercial terms
and a default-off paid-content policy are prepared below. Existing users retain
their current access. The initial billing
migration is source preparation only and has not been applied to the local
review database or any production database by this work.

Configuration names are in `.env.example`; credentials remain blank. Only
`SQUARE_ENVIRONMENT=sandbox` is supported. The client origin is fixed to Square's
Sandbox API and the reviewed API version is explicitly pinned to `2026-09-16`.
`SquareSandboxClient` requires an explicitly injected, bounded transport; no
default network implementation or automatic dispatcher exists. The initial
Customer seam and separately gated checkout methods use nonempty stored
idempotency keys. No provider mutation has been executed by this work. Use synthetic adult
sandbox records; the code never automatically sends an existing parent's email
or any child's data. Never ship a backend token in Flutter, logs or public code.

Internal customer-operation preparation stores a request fingerprint and
server-generated provider key before any future external call, without storing
the email/payload. Reusing a parent/merchant/operation UUID with different input
rejects; different parents receive different provider keys. Customer identities
are unique per parent/merchant and cannot be reassigned across parents. A
subscription identity derives ownership through its customer; it is an unused
observation/binding seam and grants nothing. No network call occurs inside a
database lock. Timeouts are ambiguous: a future caller must retry the same
stored operation, never create a fresh key automatically.

The webhook uses the exact configured public notification URL, signature key
and raw request bytes for HMAC-SHA256, with constant-time comparison before JSON
parsing. It does not derive the URL from the incoming Host/proxy headers. Reads
are bounded even without Content-Length; malformed, duplicate-key, nonfinite,
non-UTF8 and excessively nested JSON are rejected. A configured sandbox merchant
must match. Durable event-ID dedupe stores only minimal receipt metadata and a
body digest, not raw payloads, tokens or card/customer PII. Exact duplicates are
acknowledged once; conflicting bodies for the same event ID return 409 and need
reconciliation. Successful receipt is not a payment/access grant. No customer,
subscription status, XP, streak or entitlement is changed during ingestion.
The separately disabled canonical processor below records observations and can
revoke only a fully refunded exact Sandbox invoice proof; it creates no grants.

Provider-neutral paid-period records and permissions are now prepared below.
Canonical covered-cycle verification and production operational/retention
qualification remain incomplete. Deleted-account renewal cancellation now has
the separately disabled durable worker documented below. A signed event,
subscription lifecycle status or browser redirect never creates a paid period.
No public entitlement grant/CRUD API exists.

Commercial choices are confirmed in the following policy section. Tax,
cancellation/refund/privacy production policy and the real checkout, canonical
paid-period verification, delivery/mobile gates and US App Store approval path
still require completion. Sandbox preparation is not Apple approval. No Square
account, customer, plan, subscription, card, charge, webhook registration, hosted
URL, upload or deployment was created by this source work. All provider
transport tests use mocks; PostgreSQL tests use an isolated local database.

Primary Square references reviewed for this foundation:

- [REST environments and headers](https://developer.squareup.com/docs/build-basics/general-considerations/using-rest-api)
- [API versioning](https://developer.squareup.com/docs/build-basics/versioning-overview)
- [Create Customer request](https://developer.squareup.com/reference/square/customers-api/create-customer)
- [Webhook signature validation](https://developer.squareup.com/docs/webhooks/step3validate)
- [Webhook retries, ordering and event IDs](https://developer.squareup.com/docs/webhooks/overview)
- [Subscription requirements for later work](https://developer.squareup.com/reference/square/subscriptions-api/create-subscription)

## Historical full-content policy v1 (retired)

The28th-based policy below is retained as historical source/evidence only. New
checkouts use the capture-bound v2 contracts documented later in this file.

The reviewed `apps/billing/content_policy_v1.json` confirms **$9.99 USD
(999 cents), MONTHLY**, all stories and games, a Square billing anchor of **28**,
and an App Store launch limited to the **United States**. The user explicitly
chose a **full $9.99 charge immediately**, followed by **another full $9.99 on
the next 28th**, then monthly on the 28th: `can_prorate=false`, with no free
period. The checkout disclosure must state that the first two payments can be
close together. No tax, cancellation/refund or privacy policy is inferred.

`confirmed_content_plan()` verifies the immutable policy checksum. The pure
`square_catalogue_request(operation_id=..., location_id=...)` builder returns a
single atomic Catalog batch containing a plan and a related variation, with a
stable deterministic idempotency key for exact retries. It does not read tokens,
send requests, or create provider objects. Retain the approved operation UUID
and exact request for a future retry. The single indefinite phase uses
`pricing.type=STATIC`, `pricing.price_money.amount=999`, `currency=USD`,
`cadence=MONTHLY`; the variation carries `monthly_billing_anchor_date=28` and
`can_prorate=false`. The plan is a name-only fixed-price service plan and does
not assert seller-wide `all_items` or item/category eligibility. Its provider
acceptance has not been tested by a POST. The fixed anchor is Square policy; an
iOS billing implementation must separately satisfy the chosen App Store path.

`PAID_CONTENT_ENFORCEMENT_ENABLED=false` is the rollout default. Keep it OFF
until checkout, canonical payment evidence, protected delivery/mobile behavior
and the approved storefront path are ready. The independent
`PAID_CONTENT_ENTITLEMENT_ENVIRONMENT` defaults to `production`; sandbox paid
records cannot open production access. Enabling the flag is not part of this
source work, and no existing account has been restricted or given a live grant.

The new `ParentContentEntitlement` table records a server-verified paid period,
parent, feature, supported provider (`square` or `app_store`), environment,
provider account and canonical evidence reference. Periods are UTC-aware
`[valid_from, valid_until)`, require verification not in the future, and honor
effective `revoked_at`. A scheduled renewal cancellation alone does not remove
an already-paid period. One provider/account/evidence/feature cannot be copied
to another parent. Unknown providers and blank/control-bearing evidence fail
model validation; database constraints and read-time defenses reject malformed
rows that bypass normal validation. Provider lifecycle status, invoice creation
and client flags are not payment proof. The separately disabled Square app-owned term writer below now binds canonical
payments to exact contract periods. No Apple payment writer is present; no real
provider grant has been executed by this preparation.

When explicitly enabled later, the shared permission covers story list/search/
category and detail/body/narration metadata, game list/search/detail/embedded
levels/rules and submit/results, child story activity writes and streak/XP
claims. It runs before content serialization, idempotent replay or reward
writes. Paid access still requires the correct parent-owned child. Missing or
expired access returns HTTP403 with `code=subscription_required`. Authentication,
account/profile management, recovery, privacy/deletion and parent-owned
historical progress summaries remain available; summaries contain statistics,
not story text, narrated media or playable rules. New consumption endpoints
must use the same permission and bypass tests. Bible/video routes are currently
empty, not alternate content delivery paths.

This is an API policy foundation, not a complete mobile/media paywall. Existing
public media/CDN URLs and development `/media/` serving bypass an API check;
previously received story text, cached narration, bundled illustrations/game
engines and offline/device narration cannot be revoked by these server
permissions. Private signed media delivery, cache/expiry/revocation behavior,
mobile route/resume/game/narration gates and the authenticated API's edge-cache
policy must be implemented/verified before activation. No observed CDN leak is
claimed. No frontend or approved visual layout is changed by this work.

Current primary Square references for the confirmed draft:

- [Billing dates, first charge and no proration](https://developer.squareup.com/docs/subscriptions-api/subscription-billing)
- [Current static money field](https://developer.squareup.com/reference/square/objects/SubscriptionPricing)
- [Service plan and static variation example](https://developer.squareup.com/docs/checkout-api/subscription-plan-checkout)
- [Atomic temporary-ID batches and idempotency](https://developer.squareup.com/reference/square/catalog-api/batch-upsert-catalog-objects)

## Retained native-subscription prototype and canonical invoice evidence

Creation entry points are retired. The following describes historical identity,
read-only evidence and cancellation recovery, not an enabled financial flow.

`SQUARE_SANDBOX_CHECKOUT_ENABLED=false` and
`SQUARE_SANDBOX_RECONCILIATION_ENABLED=false` are separate from signed receipt
ingestion. Both require the Sandbox base flag, complete backend credentials,
configured location and an actual reviewed `SQUARE_SANDBOX_PLAN_VARIATION_ID`.
Checkout also requires explicit `SQUARE_SANDBOX_CANCELLATION_ENABLED=true` as a
safety prerequisite; its source default remains false. Cancellation can keep
running independently after checkout is disabled.
`SQUARE_SANDBOX_TRANSPORT_FACTORY` stays `None`; an operator must deliberately
inject a transport implementing response-size/time bounds and no redirects.
There is no default Internet transport. Merely adding credentials or importing
these modules cannot dispatch. Tests use mocked transports and isolated DBs.

The original native-subscription helpers remain internal for comparison and
legacy recovery; they are not the public checkout protocol. The current public
prepare/verify/pay flow is documented in the app-owned term section below.
`reserve_checkout`, `confirm_direct_checkout` and `dispatch_hosted_checkout`
retain their disabled native-provider behavior and cannot run alongside the
new app-owned billing contract for the same parent.

The direct path verifies canonical US merchant/location, currency/timezone and
the exact one-phase static999USD monthly variation (anchor28, no proration,
no price override) before mutation. It creates only a synthetic adult customer
with this intent UUID as `reference_id`, a tokenized card, and one subscription
using three separately persisted stable idempotency keys. It never sends the
real app parent's email or any child data to Sandbox. Consent text discloses
the full $9.99 immediately plus the full $9.99 on the next 28th, close first payments, no free period,
and recurring card storage. Pricing/tax/refund/cancellation legal presentation
still needs final review before activation.

An open intent is retained even after uncertainty or subscription binding; no
client route can reset it to create another subscription. Timeout/retry keeps
the same request fingerprint and keys; a changed token conflicts. Financial
dispatch older than ten minutes requires reconciliation, avoiding a new delayed
purchase. Canonical reads can recover a lost subscription response from the
dedicated unique customer reference, its exact server-created card, configured
location/variation and exactly one subscription. Another parent/customer or
multiple subscriptions is quarantined. Provider reads/mutations occur outside
database locks; short lease/owner/version checks control commits. This does not
promise prevention of unrelated merchant-admin purchases.

The internal hosted adapter is limited and is not the public checkout route.
It uses `checkout_options.subscription_plan_id` as the **variation** ID, with
the matching999USD initial amount. It saves the returned link/order-template
IDs; only exact `Subscription.phases[].order_template_id` matching can bind it.
Email, phone, customer search, a redirect or client-paid claims never bind a
parent. Multiple exact subscriptions quarantine; no automatic financial refund
or cancellation is invented. A Quick Pay guide describes one-use links, but we
do not infer an atomic duplicate-subscription guarantee under concurrent hosted
completion. Crucially, the current Checkout Sandbox panel creates a payment,
order and customer **but no subscription**; full hosted subscription end-to-end
testing is unsupported there. Direct Cards/Subscriptions component tests are a
different test, not evidence that hosted checkout was verified.

Canonical processing follows bound subscription→invoice IDs→invoice's actual
charge order→tenders→completed payments/refunds. The checkout template order
and invoice charge order are distinct. It checks parent/provider identities,
versions, full money/source/status and canonical snapshots; pending, external,
wrong-currency, partial-refund or inconsistent data cannot grant. Duplicate and
out-of-order receipts use durable processing leases and retry metadata. Equal
versions/timestamps with conflicting financial facts, stale owners and
inconsistent mid-fetch objects reject. Refund totals come from canonical
payments/refunds, not invoice completed totals (which are not reduced on
refund). A completed full refund can revoke only an existing fixture/future
Sandbox entitlement with that exact hashed invoice proof and parent; stale
paid events never resurrect it. Partial-refund access policy remains review
only and does not fabricate shortened periods.

`resolve_invoice_coverage()` is an explicit, currently unqualified adapter.
Current Square Invoice/Phase/SubscriptionEvent schemas provide no immutable
invoice-specific covered interval or renewal ordinal. `due_date` is mutable
payment timing; `charged_through_date` means latest **invoiced**-through, even
with older unpaid invoices. Therefore a paid invoice is recorded as
`invoice_coverage_unproven`, with empty coverage and **no automatic grant**.
Neither payment time plus a month nor array order/price/calendar guessing is
used. An old late payment cannot unlock a later unpaid cycle. A future genuine
pre-established invoice→contract-term ledger needs independently reviewed
binding proof; this missing piece makes the gateway functionally incomplete.

`python manage.py reconcile_square_sandbox` is a dry run without transport.
Separately authorized `--apply --limit 10` processes durable pending/retry and
expired-worker receipts, never financial mutations. `--sweep-intents` also
audits bounded active intents, prioritizing unseen invoices and rotating a
persistent cursor through previously observed history (two invoices per run).
`--intent <uuid> --invoice <provider-id>` targets an exact historical invoice.
Each reconciliation has a forty-call/deadline budget, bounded pages/payments/
refunds and a five-minute ownership lease. It does not install a scheduler;
operators must configure an appropriately bounded periodic worker and alerts.
Provider errors/private payloads are not stored/logged; exception locals are
redacted. It is not a complete retention, tax, dispute, partial-refund or
production operational policy.

No local review DB/live migration, server restart, provider object creation,
active flag, content restriction, production charge, phone or app UI change
occurred in this work. Migrations0003/0004 are source preparation plus isolated
test DB execution only. Signed
private media, client/offline gates and the approved US storefront path also
remain prerequisites.

Account deletion remains accessible without waiting for Square. A billing
`pre_delete` hook atomically retains a minimal `SquareCancellationOutbox` before
local identities cascade, even when rollout flags are off. The outbox has no
User FK, parent/contact information, card source/token, password or provider
body. It retains only the original intent UUID and provider references needed
to stop renewal; a database failure rolls back deletion rather than erasing
the last recurring-billing reference. No provider request runs in the account
deletion transaction. A dedicated operator worker is still required.

`python manage.py cancel_deleted_square_sandbox` is dry-run by default.
Separately authorized `--apply --limit 10` processes only the deleted-account
outbox, with the independent cancellation flag and explicit Sandbox transport.
It verifies provider merchant/ownership, recovers an uncertain direct response
using its dedicated customer UUID/card, and never treats an empty search as
proof no subscription exists. A reservation without a checkpointed card could
not have dispatched a subscription; an in-flight customer/card result cannot
pass a deleted intent's checkpoint. Known owned subscriptions can be cancelled
even if their card or plan was subsequently changed. Hosted usable links are
deleted and their absence is checked before finishing cancellation.

The worker reads canonical subscription state before a single CancelSubscription
request. This API has no documented idempotency-key parameter, so none is
invented. An uncertain response is retried with a canonical GET first; an
already scheduled `canceled_date` or terminal status prevents a repeated POST.
Concurrent workers use a durable lease; expired/crashed jobs are eligible for
takeover. Scheduled `canceled_date` or terminal status is verified with a fresh
read, and only then are unnecessary customer/card/template refs cleared. The
result distinguishes scheduled renewal cancellation (status can remain ACTIVE
until the cycle ends) from terminal cancellation. It requests no refunds and
does not assert that already-issued unpaid invoices, pending collections or
merchant-admin actions disappeared. Those financial/retention policies and
real-provider canary/worker monitoring remain activation prerequisites.

Primary sources for this boundary:

- [CreateSubscription and stable idempotency](https://developer.squareup.com/reference/square/subscriptions-api/create-subscription)
- [Cards source/consent requirements](https://developer.squareup.com/docs/cards-api/overview)
- [Documented synthetic Cards test values](https://developer.squareup.com/docs/devtools/sandbox/testing)
- [Canonical invoice/payment/refund retrieval](https://developer.squareup.com/docs/invoices-api/pay-refund-invoices)
- [Current hosted Sandbox limitation and template binding, Square employee Nov9,2026](https://developer.squareup.com/forums/t/does-the-checkout-api-sandbox-testing-panel-create-subscriptions-and-how-can-i-link-a-payment-link-to-its-subscription/28506)

## Capture-bound Square Sandbox billing v2 (rollout OFF)

Current contracts are versioned separately from the retired28th-based prototypes:

- `all-content-30-days-usd-999-v2`: **$9.99 USD** for30full elapsed days
  (720hours) beginning at the actual successful payment capture. A renewal is
  not requested before that entire paid period ends.
- `all-content-yearly-usd-9990-v2`: **$99.90 USD** upfront for12calendar months
  from actual capture: ten monthly prices for a full year, saving$19.98 versus
  twelve$9.99 payments. Renewal uses the same local anniversary in the frozen
  canonical seller-location IANA timezone. February29 becomes February28; an
  anniversary inside a timezone gap normalizes forward, and an ambiguous
  anniversary uses the later instant.

Both include all stories and games, with no trial or proration. The immutable
JSON policies are `content_policy_30_days_v2.json` and
`content_policy_yearly_v2.json`; their checked hashes, price, duration and
relative renewal rule are bound into the accepted disclosure. The quote cannot
truthfully predict an exact renewal timestamp before payment succeeds, so
`first_renewal_at` is null until canonical paid coverage exists. A checkout or
verification delay never consumes the member's paid duration.

The authenticated, verified parent's protocol is:

1. `GET /api/billing/square/checkout-intents/?billing_period=monthly|yearly`
   returns the current price, currency, coverage rule, timezone, disclosure
   version/hash and authoritative `web_tokenization` details. Monthly is the
   default; the selected exact token amount is9.99 or99.90.
2. POST to that same URL with fresh `password`, `accepted:true`,
   `billing_period`, `disclosure_version` and `disclosure_sha256`. Server-owned
   policy selection rejects client prices/paid flags. One open intent and one
   continuing agreement per parent prevent competing purchases across durations.
3. The current Web Payments SDK uses `CHARGE_AND_STORE`, the server's exact
   amount/currency, `customerInitiated:true`, `sellerKeyedIn:false` and the
   buyer's actual Sandbox-test billing contact. POST only fresh `password` and
   the transient `charge_source_id` to `/<intent>/confirm/`. Card data stays in
   Square's SDK; no separate legacy verification token is assumed for modern Web.
4. The backend freezes a request UUID, price, coverage rule, not-before instant,
   source digest and stable idempotency key **before** sending one payment.
   Dates remain null. Only a canonical COMPLETED CARD payment with CAPTURED card
   details and aware `card_payment_timeline.captured_at` can atomically bind
   `[captured_at,coverage_end)`. It validates chronology and rereads capture as
   part of canonical identity. Neither `created_at`, `updated_at`, a receipt
   timestamp nor the GET clock substitutes for capture. A separate coverage
   digest freezes the interval once; a replay or changed capture cannot move it.
5. That exact canonical PaymentID is the source for `CreateCard`, using the
   persisted card key and term reference. A separate immutable card binding
   verifies canonical owner/reference/merchant/enabled and matching instrument
   before future merchant-initiated renewals are ready. Card-storage failure
   does not remove an already-paid period, but keeps renewals inactive.
6. `GET /<intent>/` is an own-parent DB-only poll. Its latest payment request can
   have null coverage while a renewal is pending; it is **not** a global current
   access-expiry query. It reports `captured_at`, `coverage_state`,
   `renewals_ready` and `card_storage_state` without card/customer/token bodies.
   The separate content-access endpoint evaluates actual current verified proof,
   independently of rollout/capability; do not mistake unrestricted rollout for
   evidence of payment.

`CreatePayment.reference_id` is exactly the server term UUID. Canonical reads
must match customer, location, currency, price, source and payment identity;
refund proofs must match that payment. Money and opaque version/time hashes
are checked again before atomic commit. All provider I/O occurs outside DB
locks; short parent→agreement→term locks, leases and immutable hashes govern
commits. Missing/contradictory capture, a pending/failed/external payment,
changed owner, ambiguous recovery or stale lease never grants access.

Renewal scheduling requires verified initial payment/card and continuing adult
consent. The next not-before instant is the previous paid end. One pending
renewal is unique by agreement/not-before even though its paid dates are null;
the due date advances only after capture, to that new period's actual end. A
late successful renewal buys a fresh complete duration from its actual capture
and leaves the intervening unpaid gap unfilled. The worker never bills before
paid expiry or batches missed arrears; a fully expired missed cycle stops for
review. Existing verified full-access coverage from Square or App Store blocks
another purchase/first financial dispatch under the parent lock.

Uncertain responses retain the **same** intent, request body and payment key.
Password-only recovery looks up canonical results; it never retokenizes or
starts another charge. Every new initial POST needs fresh accepted consent
within ten minutes, even if an earlier dispatch record exists. A definitive
canonical FAILED/CANCELED initial nonpayment can use explicit `/<intent>/restart/`
with fresh terms/password to create a new attempt. Unknown outcomes cannot
rotate keys. A stopped contract whose paid end has expired can close only when
all terms are terminal and no live lease/unknown outcome remains, before a
fresh purchase; still-paid coverage cannot become an overlapping charge.

`/<intent>/cancel/` stops future app-scheduled payments without shortening paid
coverage. Account deletion atomically stops the mandate and clears active
provider references; already-authorized in-flight money can still settle and
be reconciled, but cannot grant a deleted parent or reactivate renewal. Retained
historical native subscriptions use the separate durable cancellation outbox;
no provider request occurs inside account deletion. Full refunds revoke only
their exact original proof; partial refunds require review and do not invent
new dates or prorated access.

Migration0008 changes only source/test schemas until explicitly applied by an
operator. It preserves historical fixed dates, request hashes and earned
coverage, retires old local scheduling/open intents, and adds capture-bound
nullable fields/constraints. Policies `all-content-monthly-usd-999-v1` and
`all-content-yearly-usd-10789-v1` are read/refund-only: no new grant, renewal,
automatic Subscription or hosted PaymentLink creation is allowed. Existing
remote autonomous subscriptions, if any, must be canonically closed before
switching controllers; a local migration is never claimed to cancel a provider.

All financial, transport, reconciliation, website and paid-access switches
remain default OFF. Dry-run commands make no provider changes; no renewal
scheduler or production checkout is deployed. Isolated DB/mocked tests and
historical Sandbox component canaries are distinct from current-policy browser
SDK/SCA qualification. Production activation also needs approved storefront/
website delivery, worker monitoring, clock health, tax/dispute/retention/refund
policies and client/offline/private-media access controls. API guards alone do
not protect public or already-downloaded files.

Primary protocol references:

- [Canonical card capture timeline](https://developer.squareup.com/reference/square/objects/CardPaymentTimeline)
- [CreatePayment identity, source, amount and idempotency](https://developer.squareup.com/reference/square/payments-api/create-payment)
- [Modern CHARGE_AND_STORE flow](https://developer.squareup.com/docs/web-payments/charge-and-store-cards)
- [Exact PaymentID card storage and its limits](https://developer.squareup.com/docs/cards-api/overview)

## Opt-in Square Sandbox HTTPS adapter

`SQUARE_SANDBOX_HTTP_TRANSPORT_ENABLED=false` independently disables the
built-in network adapter. It also requires `SQUARE_SANDBOX_ENABLED=true`, valid
Sandbox-only credentials/configuration, and each operation's own financial or
reconciliation flag. None of those flags enables paid content by itself.
The supported origin is fixed to `https://connect.squareupsandbox.com:443`;
production origins, userinfo, cleartext, redirects and injected headers are
refused. The adapter uses Python's verified default TLS context, sends once,
bounds request/response bytes and socket timeouts, aborts stalled I/O with a
daemon timer, and closes the connection on every path. OS DNS resolution is not
made forcibly interruptible by that socket timer; no strict DNS deadline or
network-freezing guarantee is claimed. There is no proxy/environment URL,
response-body logging, retry or connection pool.

Trusted tests/operators can still inject a **callable**
`SQUARE_SANDBOX_TRANSPORT_FACTORY` in server settings. Strings and environment
import paths are not interpreted. With no callable and the builtin switch off,
client construction fails without any network request. Factory seams are for
trusted server code, never values received from the browser.

`SquareSandboxClient.disable_card(card_id, customer_id=server_owned_customer)`
is an internal typed cleanup operation, not a public account/card endpoint.
It checks exact canonical card/customer/merchant ownership, avoids POST for an
already disabled card, sends at most one disable request and then verifies a
fresh canonical `enabled:false`. Square's documented normal response is a card
object; successful empty/lost responses observed in component qualification
are resolved by that GET rather than inferred successful or blindly retried.
An uncertain response with the card still enabled remains an error. The
exception for empty bodies is confined to this operation: generic API requests
still require a strict nonempty JSON object, and no response body is trusted to
override canonical ownership/state.

This adapter source does not enable server flags, migrate a live database,
create provider objects or install mobile purchase UI. Monthly/yearly synthetic
Sandbox component qualification is recorded separately from the still-pending
real Web Payments SDK/browser/SCA qualification. Production checkout, scheduler,
storefront, dispute/tax/retention and delivery activation require their reviewed
release gates.
