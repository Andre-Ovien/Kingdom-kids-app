# Render release preparation

This is a preparation runbook, not a deployed service or an executable Blueprint.
No service name, account, region, paid plan, domain, credential or database is
selected here. The machine-readable checklist is [render-preflight.json](render-preflight.json).
Existing production configuration is described in [the backend README](../README.md#production-and-deployment).

## Local source check

From the repository root:

```sh
python3 Backend/scripts/render_preflight.py
```

This stdlib check reads source and the two approved metadata files. It does not
load Django settings, read environment secrets, access the network, open a
database, apply migrations or qualify a production environment. Its JSON output
includes only checks and metadata hashes. Do not treat a passing source check as
approval to deploy or enable a feature.

## Proposed service settings

After the owner selects the account, repository commit, region and compute plan,
use a Docker **web service** with Root Directory `Backend`, Dockerfile Path
`./Dockerfile`, and Docker Build Context `.`. Disable automatic deploys for the
initial controlled release. Keep PostgreSQL and shared Key Value in the same
selected region; select their capacity, persistence and backup policy explicitly.
Do not create a default-plan Blueprint just to fill these missing decisions.

The existing image serves on `0.0.0.0:8000`; Render can normally detect that port.
For explicit platform-port binding, set this Docker Command (not a build command):

```sh
/bin/sh -c 'exec gunicorn --chdir Core Core.wsgi:application --bind "0.0.0.0:${PORT:?PORT must be set}" --workers 3 --timeout 30 --graceful-timeout 30 --access-logfile - --error-logfile -'
```

Three workers are the existing default, not a measured capacity recommendation.
Load-test the selected plan and size its database connection limit accordingly.
The image builds static files once with WhiteNoise, runs as an unprivileged user,
and makes `/app` read-only. Preserve the restrictive Docker COPY/ignore rules:
only narration metadata and the frozen Cloudinary map are copied from
`content/releases`; recordings, uploads, local databases and secrets are absent.
Do not add sensitive build arguments or `COPY .`.

## Environment and first release

Set production values through the platform secret manager. Do not copy the
example development environment or print resolved settings. Supply the exact API
hostname(s), five independent signing secrets/peppers, stable JWT issuer/audience,
PostgreSQL URL, shared cache URL, and qualified transactional-email sender and
transport. Use `DJANGO_DEBUG=false`. Verify the ingress strips user-supplied
forwarded headers before enabling `DJANGO_TRUST_X_FORWARDED_PROTO`; establish the
actual proxy count before setting `DJANGO_API_NUM_PROXIES`. Keep HSTS subdomain
and preload opt-ins false until their separate domain prerequisites are met.

For Render Postgres internal TLS, `DJANGO_DB_SSLMODE=require` matches the provider's
self-signed internal certificates; `verify-full` is not supported on that internal
endpoint. Prefer an authenticated TLS cache URL. If a chosen internal cache uses
`redis://`, explicitly review its private-network boundary and auth before setting
`DJANGO_CACHE_ALLOW_INSECURE=true`; it remains false in this preparation.

The current email implementation uses SMTP. Render Free web services block
outbound 465/587 (and 25 is blocked for all services), lack pre-deploy commands,
and spin down when idle. Free Postgres expires after 30 days without backups;
Free Key Value loses state on restart. These do not qualify as the production
stack described here. No paid plan has been authorized or created by this work.

Keep **all** `SQUARE_*_ENABLED`, `PAID_CONTENT_ENFORCEMENT_ENABLED`, and
`CLOUDINARY_PRIVATE_DELIVERY_ENABLED` false. Do not configure renewal,
reconciliation or cancellation jobs. Cloudinary staging proof and its packaged
map do not activate the consumer, populate narration DB rows, or establish a
production paid-access boundary. No media disk is needed merely to package the
map. If a separately approved importer requires recordings, use its controlled
staging workflow; Render pre-deploy instances cannot read a service's disk.

After a restore-tested backup and staging migration review, a paid service's
pre-deploy command can run the following **once per release**, not per worker:

```sh
/bin/sh -c 'python scripts/render_preflight.py --image && python Core/manage.py check --deploy && python Core/manage.py migrate --noinput'
```

Review deployment warnings; do not enable HSTS preload merely to silence them.
`--image` checks pinned distributions, collected static files, non-root/read-only
layout and IANA timezone data without opening services. It must be executed in
the actual built image, not the developer virtualenv. The official Python slim
recipe includes `tzdata`, but this check qualifies the selected image rather
than assuming a mutable tag's contents. Record the built image digest.

Content bootstrap is a separate, explicit operation. The existing reviewed
matching command defaults to dry-run and has a separate publish switch; follow
its README procedure. Narration imports require the approved 33 tracks and
3 samples plus metadata validation. Do not clone development accounts, attempts,
profiles or local DB state to initialize content. A migration-only success does
not prove the complete approved catalogue/narration is available.

## Health and acceptance

Use `/health/ready/` for Render's HTTP health check. Its real handler returns 200
only after a DB query and shared cache write/read succeed, otherwise 503. Only
`/health/live/` and `/health/ready/` bypass Django's HTTP-to-HTTPS redirect; all
account/admin/API routes retain it. Render accepts 3xx as healthy, so check the
actual handler rather than interpreting a redirect as readiness.

Render requires a healthy response within five seconds. Existing dependency
failure timeouts can exceed that, so failed probes may be observed as platform
timeouts; measure healthy and outage recovery latency in staging. This prep does
not promise a sub-five-second failure response or change application timeouts.
Liveness has no dependency checks. Both health responses omit infrastructure
information and are uncached.

Before enabling traffic: verify exact 200/503 behavior through the real ingress,
static admin assets, shared-cache throttling, a PostgreSQL transaction, real
verification/recovery/deletion email, approved catalogue availability and a
rollback/restore drill. Qualify redirects and forwarding with spoofed header
requests. Verify public `/media/` is not exposed. Keep external health monitoring
and latency alerts. Schedule only the existing daily `flushexpiredtokens` and
`purge_expired_auth_challenges` maintenance after its retention policy is accepted.

## Primary sources checked 12 November 2026

- [Web services / port and TLS](https://render.com/docs/web-services)
- [Docker, build context and secrets](https://render.com/docs/docker)
- [HTTP health success and five-second budget](https://render.com/docs/health-checks)
- [Pre-deploy execution and filesystem boundary](https://render.com/docs/deploys#pre-deploy-command)
- [Free-tier limitations](https://render.com/docs/free)
- [Postgres internal TLS](https://render.com/docs/postgresql-creating-connecting#ssl-modes-for-internal-connections)
- [Key Value connections and authentication](https://render.com/docs/key-value)
- [Blueprint defaults and supported fields](https://render.com/docs/blueprint-spec)
- [Root-directory-relative Docker paths](https://render.com/docs/monorepo-support)
- [Official Python slim image recipe](https://github.com/docker-library/python/blob/master/3.14/slim-trixie/Dockerfile)
