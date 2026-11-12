# Billing job release preparation

This source adds no scheduled resource and changes no running billing flag.
The repository-root `render.yaml` remains the existing staging web deployment.
The separate [opt-in template](billing-jobs.render.yaml.example) intentionally
omits `--apply`, sets production job flags false, and requires an owner-selected
environment group. Importing it would provision billable resources; this work
does not authorize that action or select a production capacity or backup policy.

## Hosting prerequisites before activation

The checked-in staging Blueprint uses Free web/Postgres/Key Value. Render's
[Free limits](https://render.com/docs/free) make live credentials insufficient:
Free web sleeps after fifteen idle minutes and may take about a minute to wake;
Free Postgres expires thirty days after creation, becomes inaccessible, and is
deleted after its fourteen-day upgrade grace period. It has no managed backups.
Free Key Value loses its contents on restart. The expiry date of the actual
database must be checked by its owner; this source audit did not read the hosted
database or dashboard. Cron and background-worker services have no Free tier.

Before any production activation, the owner must select/configure non-sleeping
web hosting, a non-expiring PostgreSQL service and backup/restore policy, shared
cache capacity, separate scheduler services, alert delivery and stable production
origins. Migrate through a reviewed release with restore-tested backups and
qualified schema/canonical recovery. Checkpoint rows and payment evidence belong
in durable PostgreSQL, never local disk or the volatile Free cache. No upgrade,
service creation, paid-resource import or spend approval is performed here.

Official [pricing](https://render.com/pricing) and
[compute-plan IDs](https://render.com/docs/compute-plans), checked 12 November
2026, list these entry options (USD; capacity is **not** qualified for this app):

| Resource | Entry option | Published price |
| --- | --- | --- |
| Always-on web or background worker | `0.5c-512mb`, 0.5 CPU / 512 MB | $7/month per service |
| Paid PostgreSQL | `0.1c-256mb`, 256 MB / 100 connections | $6/month plus applicable storage |
| Paid shared Key Value | `256mb` | $10/month |
| Each cron service | `0.5c-512mb` | $0.00016 per active minute, prorated by second; [minimum $1/month per service](https://render.com/docs/cronjobs) |

The two-cron template therefore has at least $2/month of scheduler charges,
in addition to web, DB/cache and usage. An always-on worker is a separate
$7/month entry alternative, not an extra required component. These are option
prices, not a capacity recommendation or total quote; workspace, storage,
bandwidth/build usage and applicable taxes can add cost. Confirm current pricing
when approving hosting. Paid PostgreSQL
[PITR/backups](https://render.com/docs/postgresql-backups) currently provides a
three-day recovery window on Hobby workspaces or seven days on Pro and above;
verify retention requirements and actually rehearse restore before release.

For an existing database, omit `diskSizeGB` in a promotion to retain its actual
allocation; shrinking is unsupported. A new entry-plan DB defaults to 15 GB if
storage is omitted, while an explicitly selected 1 GB minimum is valid. Current
pricing lists the first 1 GB SSD as included; extra allocation is $0.30/GB/month
(the official [cost example](https://render.com/articles/saas-hosting-cost) prices
5 GB total as $1.20 extra). Thus preserved 1 GB plus the two minimum cron charges
has a $25/month hosting baseline before usage/workspace/taxes; 5 GB totals $26.20
and 15 GB totals $29.20 with those same entry services and minimum cron runtime.
Confirm actual allocation and the final platform quote before approval, rather
than assuming compute price includes an arbitrary storage size. Valid paid
Key Value `persistenceMode` values are `journal-snapshot`, `snapshot`, and `off`;
set `journal-snapshot` explicitly when promoting the existing instance because
omission retains its current OFF mode. An upgrade/from-OFF transition loses
cache state and briefly restarts it. Payment checkpoints remain in PostgreSQL.
See the [Blueprint storage/persistence fields](https://render.com/docs/blueprint-spec)
and [Key Value persistence](https://render.com/docs/key-value).

## Job boundaries

`run_square_billing_jobs` executes one tick and exits. Its required environment
is exactly `sandbox` or `production`; its stage is `reconcile` or `renew`.
The default invocation exits before provider configuration, DB queries, locks,
checkpoint writes or any provider request. The standalone wrapper can dry-run
without loading Django or environment secrets:

```sh
python Backend/scripts/run_billing_jobs.py --environment production --stage reconcile
python Backend/scripts/run_billing_jobs.py --environment production --stage renew
```

An apply tick additionally requires its exact environment's default-false flag:

| Stage | Sandbox flag | Production flag |
| --- | --- | --- |
| Canonical reads | `SQUARE_SANDBOX_RECONCILIATION_JOBS_ENABLED` | `SQUARE_PRODUCTION_RECONCILIATION_JOBS_ENABLED` |
| First renewal dispatch | `SQUARE_SANDBOX_RENEWAL_JOBS_ENABLED` | `SQUARE_PRODUCTION_RENEWAL_JOBS_ENABLED` |

These are additional guards. Provider, term-billing, transport and canonical-read
configuration must independently qualify for the same environment. Production
renewal also requires `SQUARE_PRODUCTION_RENEWALS_ENABLED`. Enabling checkout or
storing credentials alone never opts into these jobs. Sandbox enrollment remains
required at selection and at the core's final financial authorization.

The reconciliation stage processes a bounded signed-receipt inbox batch, then a
bounded canonical-term scan. Receipt signatures and deduplication remain at the
web endpoint; a webhook acknowledgment never grants access. Existing term reads
recover lost payment responses and recheck payment/refund facts. The client for
this stage rejects all provider mutation methods. Canonical observations may
update local payment proof and access/revocation; they cannot charge or save cards.

The renewal stage rotates through eligible activated agreements and asks the
existing core to prepare the currently due term. It permits only a never-dispatched
`reserved`, buyer-absent saved-card term. It sends at most the first financial
request for that original immutable term/key. The client rechecks the recorded
dispatch counter immediately before the provider call, so a concurrent request
cannot turn a stale selection into an unattended financial POST replay. A timeout,
process death, provider ambiguity, existing payment, or previously dispatched term
goes to canonical reads and operational review. This runner never creates a fresh
key, changes a mandate/card, resets attempts, supplies a new source token, refunds,
or enables catch-up charges. The existing final authorization, cancellation race,
paid-overlap and expired-cycle checks remain authoritative.

## Locks, fairness and bounds

Both stages share a PostgreSQL session advisory lock for the exact environment
and merchant. Contention exits with redacted `lock_busy`, without provider calls
or checkpoint changes. Every record still uses its existing durable lease and
immutable evidence: the scheduler lock does not replace that financial boundary.
The lock is released on process/session close. Crash recovery respects surviving
record leases and backoff timestamps; no scheduler retry resends a financial POST.

`SquareBillingJobState` stores a durable keyset cursor for each receipt, term and
renewal lane, separated by environment and merchant digest. Cursors advance after
failed attempts as well as successful ones and wrap, so a permanently unresolved
old row cannot monopolize the first batch. A term scan includes canonical paid
evidence to recover missed refund webhooks. A full-scan timestamp means every
eligible row was *attempted* in the rotation, not that every payment was verified.

Defaults are five records per lane, eighty typed provider calls per tick and a
120-second soft wall budget. Maximums are twenty records per lane, two hundred
calls and 600 seconds. The reconciliation stage has two lanes sharing the same
call/time budget. Bounds are checked before each record/provider call; an already
running request and DB query can finish within their independently configured
timeouts. A budget interruption preserves the original ledger/key and reports
`budget_exhausted`. SIGTERM/SIGINT through the wrapper stop additional work; an
in-flight authorized request can still complete and must be reconciled.

## Deployment and scheduler choice

Use the same reviewed Docker image/commit and private same-region PostgreSQL as
the web service, with durable storage, tested backup/restore and appropriate
connection capacity. A job uses its normal Django connection plus one dedicated
advisory-lock connection. It needs no local disk, queue service or Redis lock.
Run reviewed schema migrations once through release operations before scheduling;
the job wrapper refuses pending migrations and never applies them or bootstraps
content/accounts. Set explicit `DJANGO_ALLOWED_HOSTS`, the same stable signing
identity, DB/cache/TLS/email/security configuration and environment-specific
provider settings privately. Existing Render signing seeds can be shared
deliberately; the wrapper uses the identical web derivation and does not generate
new keys. Django's original production checks still apply.

Set the Docker Command explicitly to `python scripts/run_billing_jobs.py` with
the reviewed arguments. The image's default command is the web startup script;
using that default would run bootstrap/start Gunicorn instead of a job. Start
with dry-run commands and flags OFF. Scheduling, paid resources, credentials and
the final `--apply` activation remain separate owner operations after isolated
Sandbox qualification and production readiness approval.

Suggested initial scheduling is canonical reads every two minutes and renewal
dispatch every five minutes, both UTC, with observed capacity/SLA review before
activation. Separate stages allow read recovery to continue while financial
dispatch is paused. Render cron provides one active run **per cron service**, not
across both services or manual shell invocations. A manual Trigger Run cancels an
active run; pause future scheduling and let active work finish instead of using
Trigger Run as a retry button. Render delays an overlapping scheduled run and
terminates runs after twelve hours. Its cron services have a minimum monthly
charge; no service was provisioned here. An always-on worker is an alternative
only after an owner approves its capacity and shutdown policy; it should invoke
the same bounded ticks, without adding automatic financial retries.

## Health, alerts and incident response

Tick output contains fixed stage/environment/status names, numeric counts and
backlog; it omits parent IDs, provider IDs, cursor values, signed URLs, credentials,
exception text and payloads. A provider-call count is an attempted operation, not
proof of a completed payment. The durable state records started/heartbeat/finished
and last completed/full-scan times. It is internal operational data and is not
exposed through public `/health/ready/`, which still checks web DB/cache health.

From the private server environment, this command performs DB reads only, with
no provider request or observation writes:

```sh
python Core/manage.py billing_jobs_status --environment production --stage reconcile --max-age-seconds 900
python Core/manage.py billing_jobs_status --environment production --stage renew --max-age-seconds 900
```

Alert on failed ticks, repeated lock contention, missing/stale completed heartbeat,
budget exhaustion, increasing pending receipts, growing oldest uncertain age,
review outcomes and renewal backlog. Alert separately when the full canonical
scan age exceeds the owner-approved refund/recovery SLA; measure a complete scan
under production-sized data before selecting that SLA. Monitor scheduler history,
external webhook delivery failures, provider errors/rate limits, database backups,
connection usage and host UTC/NTP clock health. A healthy web probe or a recent
job heartbeat alone does not establish an empty financial backlog.

For uncertainty, disable future renewal ticks/flags, retire old dispatch processes,
preserve all original terms/keys and continue canonical reads. Do not reset dates,
invent coverage, advance clocks, rekey, or run a new purchase to discover whether
an earlier payment succeeded. Investigate exact owned canonical evidence through
the existing manual recovery tools. Reconcile in-flight authorized payments even
after parent cancellation/deletion; cancellation preserves any already-paid end.
Resume financial dispatch only after the incident is understood and the owner
approves the recovered state. Free sleeping web hosting and expiring/no-backup
staging datastores do not qualify an ongoing production billing operation.

## Primary platform references

Verified 12 November 2026: [Render cron execution/single-run/UTC/billing rules](https://render.com/docs/cronjobs),
[background worker lifecycle](https://render.com/docs/background-workers), and
[Blueprint Docker command/schedule/service fields](https://render.com/docs/blueprint-spec).
