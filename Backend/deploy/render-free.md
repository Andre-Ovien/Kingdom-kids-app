# Free Render staging deployment

Use the repository-root `render.yaml` as a **new Blueprint**, linked to the private
repository's `main` branch. It creates exactly three Free resources in Virginia:
`kingdom-kids-checkout-staging` (Docker web), `kingdom-kids-db` (Postgres), and
`kingdom-kids-cache` (private Key Value). Automatic deployments follow commits to
`main`. Existing undeployed dashboard drafts are not required by this Blueprint.

Render supplies the exact public hostname; no wildcard or guessed URL is used.
The Docker command `python scripts/render_start.py` validates strict production
settings and email/feature disablement, takes a PostgreSQL session advisory lock,
runs `check --deploy` and migrations before one Gunicorn worker, then binds `$PORT`.
Free services have no pre-deploy command. Each cold start checks migrations again;
already-applied migrations do not run twice. Concurrent starts serialize migrations.
Failed configuration/migrations prevent the web process from starting.

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
login and password-based account deletion remain available. All Square, payment
enforcement, checkout/status and Cloudinary private-delivery switches stay OFF.
No payment worker, provider credentials, media upload, local-user import, admin
creation, content importer, cron, disk or paid resource is created here.

Accept deployment only after Render reports a ready instance and public
`/health/ready/` returns actual200 (not3xx); `/health/live/` must return200 too.
Ready checks real Postgres and shared-cache access. Test a normal API URL redirects
to HTTPS and external DB/cache connections are blocked. A successful empty
migration deployment does not establish approved stories/games/narrations or
production subscription access: content bootstrap and integration are separate.

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
