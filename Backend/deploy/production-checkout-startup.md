# Production checkout startup qualification

Square production checkout can run on the existing Free backend. A paid Render
plan or custom domain is not required to call Square's production API. There
are two separate default-OFF startup profiles: restricted, explicitly enrolled
one-period checkout on the existing host, and full public recurring release.
Credential presence activates neither profile.

## Controlled production on the existing Free backend

This profile is limited to the exact existing public origin
`https://kingdom-kids-checkout-staging.onrender.com`. Despite the service name,
`SQUARE_ENVIRONMENT` and `PAID_CONTENT_ENTITLEMENT_ENVIRONMENT` must both be
`production`, and only the production credential slots are used. It does not
require a hosting upgrade, custom-domain/DNS change, scheduler, operations
attestation or public-release qualification. Existing family data, signing
identity, API origin, email, private media, DB and cache remain on that service.

Set these literal booleans to `true` only for the authorized restricted activation:

```text
RENDER_CONTROLLED_PRODUCTION_CHECKOUT_ENABLED
SQUARE_PRODUCTION_CONTROLLED_CHECKOUT_ENABLED
SQUARE_PRODUCTION_ENABLED
SQUARE_PRODUCTION_CHECKOUT_ENABLED
SQUARE_PRODUCTION_TERM_BILLING_ENABLED
SQUARE_PRODUCTION_TERM_RECONCILIATION_ENABLED
SQUARE_PRODUCTION_HTTP_TRANSPORT_ENABLED
PARENT_CHECKOUT_PRODUCTION_ENABLED
PARENT_CONTENT_ACCESS_STATUS_ENABLED
DJANGO_EMAIL_DELIVERY_ENABLED
CLOUDINARY_PRIVATE_DELIVERY_ENABLED
```

`SQUARE_PRODUCTION_CONTROLLED_PARENT_IDS` must be an explicit nonempty list of
approved positive numeric parent IDs: at most 100 signed-64-bit IDs, comma
separated. No wildcard, email or automatic enrollment is accepted. The payment
core independently checks current verified-parent eligibility and enrollment at
capability and final financial boundaries; the startup parser alone grants
nothing. Keep this setting absent/empty in every other startup profile.

These gates must stay `false` (or absent where the application defaults false):

```text
RENDER_PRODUCTION_CHECKOUT_QUALIFICATION_ENABLED
RENDER_PRODUCTION_OPERATIONS_QUALIFIED
RENDER_PRODUCTION_CUSTOM_DOMAIN_VERIFIED
SQUARE_PRODUCTION_RELEASE_QUALIFIED
PAID_CONTENT_ENFORCEMENT_ENABLED
SQUARE_PRODUCTION_RENEWALS_ENABLED
SQUARE_PRODUCTION_RECONCILIATION_JOBS_ENABLED
SQUARE_PRODUCTION_RENEWAL_JOBS_ENABLED
SQUARE_SANDBOX_RECONCILIATION_JOBS_ENABLED
SQUARE_SANDBOX_RENEWAL_JOBS_ENABLED
RENDER_SANDBOX_CHECKOUT_QUALIFICATION_ENABLED
```

All other Sandbox/legacy financial flags must also remain false and all Sandbox
credential, callback, plan and test-parent slots must be absent/empty. Temporary
test-family import and Sandbox lookup variables are forbidden. The two startup
production profiles and Sandbox qualification cannot be combined. Public
release explicitly rejects the controlled flags and enrollment; its broader
renewal/operations requirements below remain unchanged.

`RENDER_EXTERNAL_HOSTNAME` and the sole `DJANGO_ALLOWED_HOSTS` entry must be
`kingdom-kids-checkout-staging.onrender.com`. `PARENT_CHECKOUT_ORIGIN` must be the
exact HTTPS origin above, with no suffix/path/query/credentials. Leave
`RENDER_PRODUCTION_APPROVED_ORIGIN` empty or set it to that same exact origin;
the custom-domain attestation is false. Require the existing trusted HTTPS proxy
configuration (`true` and `1`), reviewed Square API `2026-09-16`, production
application ID/token/merchant/location, and a signed production webhook key with
the exact callback ending `/api/billing/square/webhook/`. Missing either signed
callback field fails closed. Startup makes no provider call or webhook change.
The owner verifies canonical production merchant/location and callback identity
separately. `PARENT_CHECKOUT_HANDOFF_ENABLED` is a separate explicit boolean;
enabling it preserves the same parent-only scope and exact-origin boundaries.

Controlled plans are distinct one-period policies. They never save a payment
card or create a renewable agreement/next term, even if a full public recurring
profile is enabled later. The browser/mobile offer must disclose that automatic
renewal is off. No renewal worker or job is started, no automatic recovery charge
is promised, and global content enforcement/routing remains off. A startup or
offline preflight is not a charge test and does not authorize charging a card.

The same noncharging command below selects this profile when its startup opt-in
is present. A passing report identifies `profile: controlled_production`, leaves
`public_release_ready`, `activation_performed`, `automatic_renewals_enabled` and
`scheduled_jobs_claimed` false, and requires actual Django/DB/cache readiness,
canonical provider identity, signed delivery and manual canonical recovery
qualification separately. It does not require paid hosting or custom-domain
proof. All original debug/signing/peppers/PostgreSQL/TLS/cache/email/private-media
guards, deploy check, locked migrations/bootstrap and Gunicorn launch remain.

Free web can sleep, Free PostgreSQL has an expiry lifecycle, and no unattended
reconciliation service is asserted by this profile. Those operational limits
remain relevant to the owner; they do not prevent controlled production API
use. See [Render's Free limitations](https://render.com/docs/free). The paid
promotion patch, jobs template and inactive custom-domain rewrite example below
are optional future public-release preparation, not prerequisites for this
restricted activation. Do not apply them after a declined hosting upgrade.

## Separate full public recurring release

This is source preparation only. The selected custom-origin target is
`https://api.kingdom-kids.app`; its DNS, Render custom-domain mapping and CA
certificate are not created or verified by this work. No paid service is created,
no runtime flag changes, and no credential is read from a
private file or used against a provider by this work. The existing Sandbox
deployment remains on its separate reviewed exception. Live credential presence
alone cannot qualify production checkout or its hosting and billing operations.

### Default-off full-release startup boundary

`scripts/render_start.py` preserves the original strict Django security checks,
deployment check, PostgreSQL migration lock, reviewed content bootstrap and
Gunicorn launch. The full production exception is mutually exclusive with the
existing Sandbox exception and requires all of the following explicitly:

| Contract | Required value |
| --- | --- |
| `RENDER_PRODUCTION_CHECKOUT_QUALIFICATION_ENABLED` | `true` |
| `RENDER_PRODUCTION_OPERATIONS_QUALIFIED` | `true`, set only after the operations evidence below is reviewed |
| `RENDER_PRODUCTION_APPROVED_ORIGIN` | Pinned `https://api.kingdom-kids.app`, or the exact `https://` origin of a newly selected production Render hostname; no default exists |
| `RENDER_EXTERNAL_HOSTNAME` | Exact platform-provided `.onrender.com` hostname, with no wildcard |
| `PARENT_CHECKOUT_ORIGIN` | Exactly the approved origin, with no trailing slash, path, credentials, query or fragment |
| `SQUARE_PRODUCTION_WEBHOOK_NOTIFICATION_URL` | Approved origin plus `/api/billing/square/webhook/`, including the trailing slash |
| `SQUARE_ENVIRONMENT` and `PAID_CONTENT_ENTITLEMENT_ENVIRONMENT` | `production` |
| `DJANGO_TRUST_X_FORWARDED_PROTO` and `DJANGO_API_NUM_PROXIES` | `true` and `1`, after ingress review |
| `SQUARE_API_VERSION` | Reviewed `2026-09-16` |

For the custom path, the additional default-OFF
`RENDER_PRODUCTION_CUSTOM_DOMAIN_VERIFIED` must explicitly be `true`, only after
the owner verifies DNS, Render mapping and the CA certificate. This path accepts
only the source-pinned host, never an arbitrary configured custom domain.
`DJANGO_ALLOWED_HOSTS` must contain exactly the platform host and
`api.kingdom-kids.app`, comma-separated without duplicates or extra/wildcard hosts.
The current staging-named Render handle may remain to preserve the existing
service/database family data, but serves only exact `/health/live/` and
`/health/ready/` probes. The first middleware rejects other alias routes before
security redirects or account/content/billing handlers. Parent checkout and
handoff retain their own exact configured-origin checks too.

The alternative path for a truly new production Render service requires
`RENDER_PRODUCTION_CUSTOM_DOMAIN_VERIFIED=false` and its exact Render hostname as
the sole allowed host/public origin. It rejects the current Sandbox public
origin, staging/Sandbox labels, placeholders, localhost/private/literal-IP hosts,
credentials, query strings and arbitrary non-Render domains.
The mobile production API `/api` and checkout `/parent/checkout/` must use this
same origin. A syntactically valid hostname is not proof it is provisioned,
owned, reachable or accepted for release.

All these financial/release flags must be the literal string `true`:

```text
SQUARE_PRODUCTION_ENABLED
SQUARE_PRODUCTION_CHECKOUT_ENABLED
SQUARE_PRODUCTION_TERM_BILLING_ENABLED
SQUARE_PRODUCTION_TERM_RECONCILIATION_ENABLED
SQUARE_PRODUCTION_HTTP_TRANSPORT_ENABLED
SQUARE_PRODUCTION_RELEASE_QUALIFIED
SQUARE_PRODUCTION_RENEWALS_ENABLED
SQUARE_PRODUCTION_RECONCILIATION_JOBS_ENABLED
SQUARE_PRODUCTION_RENEWAL_JOBS_ENABLED
PARENT_CHECKOUT_PRODUCTION_ENABLED
PARENT_CHECKOUT_HANDOFF_ENABLED
PARENT_CONTENT_ACCESS_STATUS_ENABLED
PAID_CONTENT_ENFORCEMENT_ENABLED
```

Reconciliation and both renewal gates are required for the full public startup
because that offer promises automatic renewal. A consistently disabled draft can
be reported offline but cannot start the full public recurring flow. Startup does not
create jobs or infer that a scheduler runs from these flags. Email delivery and
the reviewed private-media delivery must also be enabled; their existing exact
sender/Resend, pinned map, private credential and URL-TTL checks still apply.

Supply the production-only token, merchant/location IDs, SDK application ID and
webhook signature key privately. The SDK ID must match the production
`sq0idp-`/`sq0idb-` format; token/ID/key shapes must be bounded printable ASCII,
with no Sandbox label. These local shape checks do **not** prove that an opaque
token belongs to production or to the configured merchant. Separate canonical
production merchant/location verification remains required; there is no provider
request or credential fallback in startup qualification.

Every Sandbox financial/job flag and `PARENT_CHECKOUT_SANDBOX_ENABLED` must be
false or absent. `RENDER_SANDBOX_CHECKOUT_QUALIFICATION_ENABLED` must be false or
absent. All Sandbox token/merchant/location/application/signature/callback/
variation slots and test-parent enrollment must be absent or empty. Temporary
test-family import and Sandbox parent-lookup variables are forbidden. This
prevents staging credentials, account import or allowlist state from entering a
production process. An inactive production configuration may still be stored
privately on the current Sandbox service while all production gates stay OFF;
that existing credential-storage behavior is preserved.

The new path never skips the original `DJANGO_DEBUG=false`, independent signing
secrets/peppers, PostgreSQL/TLS, shared-cache transport, exact host, proxy, email,
private-media, deploy-check or migration checks. Passing this local qualification
does not prevent original Django settings from rejecting an invalid environment.
It does not change key derivation, mutate schemas by itself, start a worker,
issue a payment, or grant paid access.

## Noncharging offline report

With the separately prepared private server environment already available to the
owner, the following is a local diagnostic only:

```sh
python scripts/production_checkout_preflight.py
```

It loads no Django, opens no DB or network connection, reads no credential file,
changes no environment/runtime flag, and invokes no provider. When a complete
candidate reaches the original local private-media guard, that guard reads only
the shipped pinned metadata map. Output contains fixed check names and booleans,
never secret values, URLs or provider/account IDs.

Exit `2` means a disabled draft or blocked local contract; credential presence
does not change that result. Exit `0` means only that local flag/shape/startup
guards passed. **Every report has `public_release_ready: false` and
`activation_performed: false`.** For the full public-release profile it explicitly lists original Django production
checks, hosting, durable DB/cache and restore testing, canonical production
merchant/location qualification, signed webhook processing, actual scheduled
reconciliation/renewal heartbeats, monitoring and approved mobile release as
separate required runtime evidence. It does not validate the original Django
security configuration or dependency readiness by loading application settings.
Do not interpret its zero exit as deployment approval or as proof credentials
were accepted by Square.

For the pinned custom target the report always states
`custom_domain_dns_ca_proof: external_evidence_required_not_checked`; a local
attestation variable is not a DNS/CA/provider probe. A platform hostname can
remain for health without becoming a public production checkout origin.

## Evidence before the operations declaration

Use [billing-jobs.md](billing-jobs.md) and its separate opt-in template to prepare
the scheduler, durable cursors/locks, health/backlog monitoring and incident
response. Confirm the selected web service does not sleep, PostgreSQL does not
expire and has restore-tested backups, cache transport/capacity are qualified,
and the two scheduled stages actually run with the approved same-environment
configuration. Review their real heartbeat, recovery/full-scan and backlog
evidence, not just flag presence. Observe signed callback processing and the
canonical recovery path; an inbox acknowledgment alone proves no grant.

The checked-in Free staging Blueprint is not a production durability or scheduler
plan. Selecting/provisioning paid hosting, production origin and monitoring,
deploying the reviewed image/schema, and final activation remain separate owner
operations. No new service is added to the active Blueprint. Set the operations
declaration only after this evidence is reviewed, alongside the independent
`SQUARE_PRODUCTION_RELEASE_QUALIFIED` gate. Neither declaration is synthesized
from keys or changed by a diagnostic script.

The separate [review-only promotion patch](promote-existing-render.patch.example)
updates the existing resource names/plans, preserves the existing DB allocation and
paid cache persistence, temporarily disables auto-deploy for cutover and proposes the selected custom
domain mapping. It is not applied automatically and keeps financial activation
gates OFF. Align the actual managed Blueprint with any owner-approved upgrade so
a later sync cannot restore the checked-in Free plans. Review the separate
activation-gate configuration when switching billing environments; existing
Blueprint-managed false gate values must not silently overwrite an approved
runtime activation either. Apply neither change merely because keys are present.

The patch intentionally omits `diskSizeGB`: Render retains an existing database's
actual disk size when omitted and cannot shrink it. Confirm the resource names
resolve to the existing web/DB/cache in the owner workspace before any sync;
do not use this patch to create replacement datastores. A newly created paid DB
would default to 15 GB on the entry plan if storage were omitted, so this is an
existing-resource promotion only. Keep the restored family/account data in the
same DB, take and restore-test a backup, and record stable signing/pepper identity
before changing infrastructure. A Free cache upgrade loses cache contents and
briefly restarts it; it does not move or delete PostgreSQL family data.

## Website rewrite and cutover order

The inactive [website example](website-vercel.production.json.example) changes
only the four existing public-form rewrite destinations to the pinned custom
API origin and preserves the no-cache headers. The active
`Frontend/website/vercel.json` is unchanged. Do not add a catch-all account/billing
proxy: browser checkout/handoff stays directly on the exact API/checkout origin.

1. Review and obtain approval for the concrete hosting/persistence/storage costs.
   Preserve the existing resource identities and DB allocation; align the managed
   Blueprint promotion so a future sync cannot restore Free plans. No paid
   provisioning or upgrade is implied by this source example.
2. Back up and rehearse restore; freeze the reviewed source/image/migration set.
   Stage the two job services and monitoring with the same approved environment,
   initially dry-run/OFF. Keep signing identity and restored family data stable.
3. The owner configures DNS, the Render mapping and CA certificate for
   `api.kingdom-kids.app`, verifies ownership/TLS, and records that external proof.
   Only then may the custom-domain attestation be set. The offline report cannot
   make this proof or activation decision.
4. Qualify original Django/DB/cache checks, scheduled job heartbeats, canonical
   provider identity, callback/reconciliation and incident response. Review the
   release and operations declarations and the separate activation configuration.
5. Coordinate the backend production-origin deployment, the inactive website
   rewrite promotion and the matching mobile API build during a controlled
   cutover window. The alias becomes health-only in custom production mode, so
   the website's old alias-targeted form rewrites must change as part of that
   same cutover; this example does not promise a zero-downtime switchover.
6. Confirm the custom origin serves the expected account/forms/checkout paths,
   both health probes work on the platform alias, all other alias paths return
   404, website no-cache headers remain, and the restored parent sees the same
   child data. Old staging-targeted mobile builds need the production API build;
   backend-bound credential storage is deliberately not copied across origins.
7. Restore `autoDeployTrigger: commit` in the managed web and job Blueprints
   after qualification, then verify an approved source update reaches the web
   service and both scheduled jobs. The requested steady state is automatic
   deployment from the tested main branch; cutover's temporary OFF setting must
   not remain as the operating configuration.

Until those optional full-release owner actions and acceptance checks are
complete, the full public-release/custom-domain/operations gates remain OFF.
The separately authorized controlled profile can use production credentials on
the unchanged existing origin with its narrow gates and enrolled parents. No
DNS, website, Render or runtime change is performed by these source examples.
