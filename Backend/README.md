# Kingdom Kids API

## Local development

Local testing needs no environment variables. With no environment configured,
the API uses the checked-in development-only secret, SQLite, and prints each
email verification code directly in the runserver terminal.

```sh
cd Backend
.venv/bin/python Core/manage.py migrate
.venv/bin/python Core/manage.py runserver 0.0.0.0:8000
```

After registration, copy the value shown beside `Code:` in the
`KINGDOM KIDS DEVELOPMENT CODE` terminal banner. Setting
`DJANGO_DEBUG=false` restores the production checks for a private secret,
PostgreSQL, HTTPS, and a real email backend.

Debug mode accepts localhost, emulator, and changing LAN host addresses so a
physical phone can call the API without editing `ALLOWED_HOSTS`. Production
still requires an explicit `DJANGO_ALLOWED_HOSTS` value.

Run the focused game tests, the complete backend suite, and Django's sanity and
migration checks from the repository root with:

```sh
cd Backend
.venv/bin/python Core/manage.py test apps.games
.venv/bin/python Core/manage.py test apps.accounts apps.stories apps.games apps.progress
.venv/bin/python Core/manage.py check
.venv/bin/python Core/manage.py makemigrations --check --dry-run
```

## Account API

All endpoints use the `/api/accounts/` prefix. Access tokens are passed as
`Authorization: Bearer <access-token>`.

| Method | Endpoint | Purpose |
| --- | --- | --- |
| POST | `register/` | Create a pending parent account and send a six-digit email code; returns a verification challenge but no JWT |
| POST | `email-verification/confirm/` | Confirm `challenge_id` and `code`; returns the normal JWT session |
| POST | `email-verification/resend/` | Rotate a challenge after its resend cooldown |
| POST | `login/` | Sign in with `email` and `password` |
| POST | `token/refresh/` | Exchange a refresh token; refresh tokens rotate |
| POST | `logout/` | Blacklist the supplied refresh token (requires access token) |
| GET | `me/` | Read the signed-in parent and their kid profiles |
| GET, POST | `kid-profiles/` | List/create the signed-in parent’s profiles |
| GET, PUT, PATCH, DELETE | `kid-profiles/<uuid:id>/` | Manage one owned profile |
| GET, PATCH | `kid-profiles/<uuid:id>/preferences/` | Read or partially update one owned child’s typed reading preferences |

Kid profiles deliberately collect only `display_name` and one controlled
`avatar_key`: `lion`, `dove`, `rainbow`, `star`, `crown`, or `sheep`.
Profile creation also requires a client-generated UUID in `operation_id`.
Replaying that ID for the same parent returns the existing profile instead of
creating a duplicate.

Each child profile has an independently owned preferences resource. Its first
GET or valid PATCH creates these safe defaults when no row exists yet:

```json
{
  "profile_id": "c5a35566-765a-4017-971a-fb0125bcf7cd",
  "story_text_scale": "comfortable",
  "narration_enabled": true,
  "updated_at": "2026-07-15T10:30:00Z"
}
```

`story_text_scale` accepts only `comfortable`, `large`, or `extra_large`.
PATCH is partial, so omitted values are retained. The parent cannot change
`profile_id` or `updated_at`, and both missing and another parent’s profile are
reported as 404. These preferences intentionally cover only story text scale
and narration; device display, notification permission, offline storage,
autoplay, bedtime schedules, and parent-gate policy remain outside this API
until their ownership and enforcement rules are defined.

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

Each detail response also carries optional `audio_url` and `duration_seconds`
fields. They are empty while narration uses device text-to-speech, but allow
hosted recordings or generated-and-cached audio to be introduced later without
changing the mobile story contract.

### Round 1 narrator auditions

The first in-app audition maps Kai to Cedar, Nia to Marin, and Zuri to Coral.
Generate only variant A with the local generator, then atomically attach the
three cached files to the narrator records:

```sh
cd Backend
python3 scripts/generate_voice_auditions.py --variant a
.venv/bin/python Core/manage.py migrate
.venv/bin/python Core/manage.py install_round_one_voice_samples
```

The installer requires all three valid MP3 files in
`Backend/media/voice_auditions/`; if one is missing or malformed, it changes no
database records. Running it again is safe. Story detail responses expose each
available file as an absolute `sample_url`, built from the phone's API request
host, while the provider and provider voice ID stay private.

Django serves these local media files only while `DJANGO_DEBUG=true`. Debug
media URLs are deliberately public and do not require the story API's JWT;
audition clips must therefore contain no private content. Production must use a
configured media server or storage backend. The MP3 files remain ignored by Git
and must never be committed as source code.

## Game API

The game catalogue is profile-scoped because stars, best scores, and unlocked
levels belong to a child rather than the parent account. All three endpoints
require a verified parent's bearer token, and `profile_id` must identify one of
that parent's kid profiles. A profile owned by another parent is returned as a
404 rather than disclosed.

| Method | Endpoint | Purpose |
| --- | --- | --- |
| GET | `/api/games/?profile_id=<uuid>` | List eight published games with this child's progress |
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

The initial migrations seed eight games with three levels each (24 playable
levels total):

| Game | Slug | Engine |
| --- | --- | --- |
| Match the Ark Animals | `ark-animal-match` | Matching |
| Creation Order | `creation-order` | Ordering |
| David's Sling Aim | `david-sling-shot` | Aim |
| Jonah Ocean Maze | `jonah-ocean-maze` | Maze |
| Red Sea Path | `red-sea-path` | Path |
| Daniel Memory Match | `daniel-memory` | Memory |
| Esther Brave Quiz | `esther-quiz` | Quiz |
| Moses Mission Match | `moses-match` | Matching |

Level responses contain the presentation content needed to play, but the
serializer strips private quiz answers, ordering sequences, and matching pairs
before sending a level to the device. Memory match keys are intentionally
public so the app can reveal a local pair immediately; the server still
recomputes completion, efficiency, score, and stars from the submitted cards.

The server validates every engine's result against its private level config and
is the sole source of `completed`, `score`, and `stars`. It also validates grid
bounds, walls, adjacent path steps, target geometry, unique matching cards, and
memory move/time metrics. Sending client-computed score fields is rejected.
Levels unlock in order. An identical `operation_id` and request receives the
original attempt with HTTP 200; changing any part of an already-used operation
returns HTTP 409.

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
- aim levels require bounded canvas/target geometry and 1–10 allowed shots;
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

The optional `timezone_offset_minutes` query parameter is the device's minutes
east of UTC (`60` for UTC+01:00). It defaults to UTC and accepts only integer
values from `-840` through `840`. Streak days and weekly activity are calculated
in that fixed local offset. The response shape is:

```json
{
  "profile": {
    "id": "c5a35566-765a-4017-971a-fb0125bcf7cd",
    "display_name": "Amara",
    "avatar_key": "star"
  },
  "level": {
    "number": 2,
    "title": "Little Explorer",
    "xp": 500,
    "next_level_xp": 600
  },
  "stats": {
    "completed_game_levels": 3,
    "total_game_levels": 24,
    "game_stars": 10,
    "max_game_stars": 72,
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

The deterministic progression rules are deliberately based on best game
progress, so repeating an attempt cannot farm XP:

- each distinct completed level contributes 100 XP;
- each best level star contributes 20 XP;
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

An activity day is any local calendar day with at least one accepted game
attempt or recorded story completion. A story start updates story discovery
stats but deliberately does not inflate the streak. `current_days` stays active
when the last qualifying activity was today or yesterday; `longest_days` is the
longest consecutive run in the full qualifying history. `weekly_activity`
always contains the five Monday-starting local weeks from oldest to current.
It exposes game `attempts`, `story_completions`, and their summed `activities`;
events rather than unique days are counted in each week. `last_activity_at`
remains an absolute UTC timestamp. XP and the five badges remain based solely
on authoritative game progress.

Registration responds with HTTP 202 and this shape:

```json
{
  "verification": {
    "challenge_id": "3ce09cd7-8321-4ad1-94ef-f476fa4f8114",
    "email": "parent@example.com",
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

Registering an email that belongs to an active, still-unverified parent safely
reclaims that one pending account and replaces its validated password. While
the existing challenge is inside its resend cooldown, registration returns that
same challenge without sending another email. Once cooldown permits, the old
challenge is invalidated before a replacement is issued. Verified or disabled
accounts remain protected and return a validation error; re-registration never
creates a second user row, resets the guess budget, or issues a JWT.

If the configured email backend rejects a message after its challenge has been
committed, registration or resend still returns HTTP 202. The response includes
`code: verification_delivery_delayed`, `verification_delivery_delayed: true`,
and the persisted replacement challenge metadata. Its `resend_after` is zero,
so the app can offer an immediate retry. The six-digit code is never included
in this recovery response. A durable external delivery queue remains the
recommended production evolution when retry guarantees are required.

## Production checklist

- Set `DJANGO_DEBUG=false`, a strong `DJANGO_SECRET_KEY`, and
  `DJANGO_ALLOWED_HOSTS`; the application refuses to start without them.
- Set `DJANGO_DATABASE_URL` to PostgreSQL. Production refuses SQLite because
  verification confirmation and resend transitions depend on row-level locks.
  Use `DJANGO_DB_SSLMODE=require` unless the deployment network provides an
  equivalent protected database connection.
- Serve only through HTTPS. If TLS terminates at a trusted proxy, set
  `DJANGO_TRUST_X_FORWARDED_PROTO=true` only after that proxy strips and sets
  `X-Forwarded-Proto` itself.
- Leave `DJANGO_HSTS_INCLUDE_SUBDOMAINS` and `DJANGO_HSTS_PRELOAD` false until
  every current and future subdomain is HTTPS-only; then enable both as an
  explicit deployment decision.
- Use a shared cache such as Redis for DRF throttling when running multiple
  application processes; the development cache is process-local.
- Set a unique `EMAIL_VERIFICATION_PEPPER` independently from
  `DJANGO_SECRET_KEY`. Rotating it invalidates every outstanding code.
- Set `DJANGO_EMAIL_BACKEND` and `DJANGO_DEFAULT_FROM_EMAIL`. The sample uses
  Django's console backend for local development; production refuses console,
  in-memory, and dummy backends. Configure SMTP or a provider backend and keep
  its credentials in the deployment secret store.
- Schedule `python Core/manage.py flushexpiredtokens` daily to remove expired
  SimpleJWT blacklist records.
- Periodically delete consumed, invalidated, and expired email-verification
  challenges according to the application's audit-retention policy.

Debug mode accepts emulator and changing LAN hostnames automatically. Keep
production `DJANGO_ALLOWED_HOSTS` explicit.
