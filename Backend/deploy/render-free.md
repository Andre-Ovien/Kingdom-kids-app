# Free Render staging deployment

Use the repository-root `render.yaml` as a **new Blueprint**, linked to the private
repository's `main` branch. It creates exactly three Free resources in Virginia:
`kingdom-kids-checkout-staging` (Docker web), `kingdom-kids-db` (Postgres), and
`kingdom-kids-cache` (private Key Value). Automatic deployments follow commits to
`main`. Existing undeployed dashboard drafts are not required by this Blueprint.

Render supplies the exact public hostname; no wildcard or guessed URL is used.
The Docker command `python scripts/render_start.py` validates strict production
settings, disabled email/financial actions and qualified private-media configuration,
takes a PostgreSQL session advisory lock,
runs `check --deploy`, migrations and the reviewed five-game matching installer
before one Gunicorn worker, then binds `$PORT`. When private delivery is enabled,
the pinned metadata-only private-media installer runs after matching inside the
same release lock, creating the three approved samples and 33 narrator tracks.
Free services have no pre-deploy command. Each cold start checks migrations again;
already-applied migrations do not run twice. Concurrent starts serialize migrations.
Failed configuration, migrations or content validation prevent the web process
from starting. Content installers are transactional/idempotent and do not import
accounts, attempts, progress or local recordings.

Gunicorn26's control interface uses an owner-only socket inside a new private
0700 directory under `/tmp`. It does not write `$HOME/.gunicorn` under the
deliberately read-only `/app`. The explicit `--control-socket` and mode 0600 are
supported by the pinned installed Gunicorn and its
[official control settings](https://gunicorn.org/reference/settings/#control_socket).

Two independent platform-generated 256-bit seeds are SHA-512 domain-expanded to
satisfy the existing Django/JWT minimum character lengths; three other independent
peppers are generated directly. Values are stable across redeployments and never
printed. Do not regenerate them during ordinary deploys; that invalidates sessions
and stored challenges. Do not copy local `.env` or SQLite data into the deployment.

Postgres uses its private connection URL with required TLS. Key Value uses its
same-region private `redis://` URL; both datastores have `ipAllowList: []` to block
external connections. The explicit private-cache TLS exception is limited by the
startup guard to Render `red-*` internal names. Render terminates public HTTPS;
the deployment trusts its forwarded HTTPS header and sets one proxy for throttling.
Verify actual ingress behavior before broad public usage.

Email delivery is deliberately **disabled**: signup and email verification/reset/
email-code deletion return safe503 without issuing challenges. Verified-parent
login and password-based account deletion remain available. All Square, paid
enforcement and parent checkout/status switches stay OFF. Square Sandbox
credentials may be held privately for later qualification; storing credentials
does not enable a provider call, financial worker or charge.

The approved Cloudinary delivery switch is now enabled in the Blueprint, with
`DJANGO_CONTENT_MEDIA_HOSTS=api.cloudinary.com`, TTL300 and frozen map SHA256
`70e57ac281c330383db3e3a8c899c80d1816a41f400dae6a9a269b46c6436876`.
Supply `CLOUDINARY_CLOUD_NAME`, `CLOUDINARY_API_KEY` and `CLOUDINARY_API_SECRET`
privately through Render. The YAML contains only `sync:false` placeholders;
existing-service updates still require the operator to set these values.
Startup checks the account matches the exact shipped first-release map, numeric
key/secret format, host allowlist and short TTL without contacting Cloudinary.
Missing or mismatched configuration fails closed with a sanitized message.
Setting the delivery switch false retains the prior no-map/no-provider path.

This enables only authenticated, allowlisted serializer bindings and the pinned
first-release metadata bootstrap. It does not upload media, activate paid
enforcement or secure already-bundled/offline assets. The packaged map has 49
aliases (36 audio and 13 images); original object verification is separate provider
evidence. The installer validates exact owner/alias/use/hash, story text and
timings from the packaged metadata without needing local audio bytes or network
access. A real authenticated API/media-consumer check remains distinct from
environment validation and bootstrap row counts. Never log signed delivery URLs.
No local-user import, admin creation, cron, disk or paid
resource is created by the startup script.

Accept deployment only after Render reports a ready instance and public
`/health/ready/` returns actual200 (not3xx); `/health/live/` must return200 too.
Ready checks real Postgres and shared-cache access. Test a normal API URL redirects
to HTTPS and external DB/cache connections are blocked. A successful empty
migration deployment does not establish working media or production subscription
access. Confirm the approved matching catalogue and metadata-only narration
bootstrap, then check actual authenticated delivery separately.

Free limitations remain: web sleeps when idle, Key Value has no persistent state,
and Free Postgres expires after30days and lacks managed backups. This deploy is a
staging backend, not a durability guarantee. No Docker daemon was available locally;
Render's actual Docker build and ingress/DB/cache readiness are the runtime proof.

Current official references (verified12November2026):
- https://render.com/docs/blueprint-spec
- https://render.com/docs/environment-variables
- https://render.com/docs/docker
- https://render.com/docs/free
- https://render.com/docs/key-value
- https://render.com/docs/postgresql-creating-connecting
