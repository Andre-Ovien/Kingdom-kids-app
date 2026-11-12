# Parent website checkout: Sandbox preparation

The new same-origin page is `/parent/checkout/`. It is a normal parent sign-in,
plan selection and card checkout, not a developer control panel. It is **off by
default** and refuses production Square configuration, HTTP, an unexpected
origin and query-bearing page links. Server checkout and plan-routing capability
is restricted to explicitly enrolled, verified Sandbox test parents. The global
paid-content gate stays off for the shared staging service.

## Source contract

- `/api/accounts/login/` authenticates an already verified parent. The page keeps
  only its access JWT in memory, ignores refresh tokens, and clears its own state
  on sign-out/page exit. Credentials and card sources are never put into browser
  URLs, app storage or application logs. Browser extensions, developer HAR
  capture and Square's own SDK behavior are outside that application guarantee.
- `GET /api/billing/content-access/` is authenticated and `no-store`. With
  `PARENT_CONTENT_ACCESS_STATUS_ENABLED=false`, it returns `unknown` without
  querying payment state. When enabled it uses the canonical
  `verified_paid_coverage_until` helper, independently of the enforcement bypass.
  It returns `paid`, `unpaid` or `unknown`, a current exclusive proof expiry,
  separate checkout capability and an optional same-parent purchase reference.
  DB failure or an uncertain purchase remains unknown. Sandbox purchases cannot
  alter production access discovery. In Sandbox, an unenrolled parent receives
  `unknown`/`not_enrolled`, no purchase reference and no plan-routing capability,
  without reading payment state. An enrolled parent gets
  `parent_plan_routing_enabled=true` only when the complete same-origin Sandbox
  checkout configuration is available. Account APIs retain their existing access.
- Quote: `GET /api/billing/square/checkout-intents/?billing_period=monthly|yearly`.
  The page requires the current capture-bound policy: $9.99/30 elapsed days or
  $99.90/12 calendar months, USD, `CHARGE_AND_STORE`, and a disclosure hash.
  There is no guessed pre-capture renewal timestamp.
- Reserve sends only the selected billing period, accepted disclosure
  version/hash, explicit recurring consent and fresh parent password. The amount
  is server-selected. Card tokenization passes the server's verification details
  plus buyer-entered billing contact to the official Square card element.
- Confirm sends only fresh parent password plus the single-use charge source to
  the existing owned intent. There is no automatic payment POST retry. An
  uncertain attempt remains locally locked even if an early status read has not
  yet observed its term. Recovery sends password only to that same intent.
- Only a canonical failed/canceled payment offers the explicit guarded restart
  path. Restart reserves a new intent; a separate Pay click is required to
  tokenize or charge. Backend canonical checks remain authoritative.
- SDK success and a completed HTTP request do not show paid success. The page
  rechecks the general access endpoint. Paid-but-card-setup-pending access stays
  paid, with a separate setup action. Stopping future renewals does not shorten
  verified already-paid coverage.

## Explicit staging inputs, not activation instructions

An operator must separately approve a private Sandbox backend/database and safe
HTTPS origin before setting any flags. This work did not read keys, create a
listener, contact Square, change a database/runtime flag or deploy a service.
Required configuration names are in `.env.example`:

- `PARENT_CHECKOUT_SANDBOX_ENABLED` and
  `PARENT_CONTENT_ACCESS_STATUS_ENABLED` remain false in source/defaults.
- `PARENT_CHECKOUT_ORIGIN` must be the exact HTTPS origin. Nonstandard ports are
  accepted only for loopback HTTPS, allowing a private test listener with
  `DEBUG=false`. No LAN HTTP exception exists.
- `SQUARE_SANDBOX_APPLICATION_ID` is the public Sandbox SDK ID; the location ID
  must match the server checkout configuration. Secret Square access/webhook
  credentials stay in server environment configuration only.
- `SQUARE_SANDBOX_TEST_PARENT_IDS` is a default-empty, comma-separated list of
  at most 100 approved positive numeric parent IDs. Registration, verification
  and a client-supplied parent ID cannot enroll anyone. Empty or malformed
  enrollment denies new payment, card storage and renewal operations. Removing
  a parent also hides Sandbox access/recovery from discovery. Their authenticated
  owned purchase status and password-confirmed stop-renewals action remain
  available while term billing is enabled. Canonical reconciliation can retain
  an already dispatched payment's evidence without creating an unenrolled
  parent's grant or recurring-card setup.
- Existing explicit Sandbox billing, transport and reconciliation configuration
  must be separately enabled/qualified by the operator. No activation is implied
  by rendering templates or by `checkout.state=available`, which means only that
  local Sandbox configuration is present. Actual provider acceptance remains a
  canary result, not a configuration claim.
- Use only approved synthetic verified parents, Square test cards and a separate
  staging database. On an explicitly approved shared staging database, enroll
  only the selected synthetic parent IDs; existing general accounts remain
  unenrolled. Email-disabled staging cannot register or auto-verify an
  account; follow its separately approved fixture/guard procedure. Preserve all
  other production secret, PostgreSQL, shared-cache and HTTPS protections.

## Shared staging configuration and new test parents

The following is the reviewed configuration contract, not an instruction to
activate it without the operator's Sandbox authorization. Keep all existing
`DJANGO_DEBUG=false`, exact allowed hosts, HTTPS proxy, PostgreSQL, Redis, signing
and email protections. Do not use live Square credentials or a real card.

| Environment name | Sandbox staging value or requirement |
| --- | --- |
| `RENDER_SANDBOX_CHECKOUT_QUALIFICATION_ENABLED` | Explicit `true` only on this exact approved Render staging service; defaults `false` |
| `SQUARE_ENVIRONMENT` | `sandbox` |
| `SQUARE_SANDBOX_ENABLED` | `true` |
| `SQUARE_SANDBOX_TERM_BILLING_ENABLED` | `true` for the reviewed test checkout |
| `SQUARE_SANDBOX_TERM_RECONCILIATION_ENABLED` | `true` for canonical term/receipt reads |
| `SQUARE_SANDBOX_HTTP_TRANSPORT_ENABLED` | `true` for the fixed-origin bounded TLS transport |
| `PARENT_CHECKOUT_SANDBOX_ENABLED` | `true` |
| `PARENT_CONTENT_ACCESS_STATUS_ENABLED` | `true` |
| `PAID_CONTENT_ENTITLEMENT_ENVIRONMENT` | `sandbox` |
| `PAID_CONTENT_ENFORCEMENT_ENABLED` | **`false`** on shared staging |
| `PARENT_CHECKOUT_ORIGIN` | `https://kingdom-kids-checkout-staging.onrender.com`, exact origin without a path |
| `SQUARE_SANDBOX_TEST_PARENT_IDS` | Only the explicitly approved verified synthetic parent IDs; initially blank |
| `SQUARE_SANDBOX_APPLICATION_ID` | Public Sandbox SDK application ID matching the provider account |
| `SQUARE_SANDBOX_MERCHANT_ID` | Same approved Sandbox merchant |
| `SQUARE_SANDBOX_LOCATION_ID` | Same approved active US/USD Sandbox location |
| `SQUARE_SANDBOX_ACCESS_TOKEN` | Existing Sandbox token, server environment only |
| `SQUARE_SANDBOX_WEBHOOK_SIGNATURE_KEY` | Signature secret of this dedicated Sandbox subscription, server environment only |
| `SQUARE_SANDBOX_WEBHOOK_NOTIFICATION_URL` | Exact registered `https://kingdom-kids-checkout-staging.onrender.com/api/billing/square/webhook/`, including the trailing slash |
| `SQUARE_API_VERSION` | Existing reviewed pinned `2026-09-16` |
| `SQUARE_HTTP_TIMEOUT_SECONDS` | Existing bounded value, default `5` |
| `SQUARE_WEBHOOK_MAX_BODY_BYTES` | Existing bounded value, default `262144` |

Render's startup guard retains the original financial-feature denial unless the
qualification opt-in is exactly `true`. The exception requires this exact
`RENDER_EXTERNAL_HOSTNAME`, the exact checkout origin above without a trailing
slash, the callback above with its trailing slash, all six current
Sandbox/term/transport/parent flags enabled, nonempty valid numeric enrollment,
Sandbox provider and entitlement environments, and all required provider inputs.
It also requires the existing trusted Render HTTPS proxy setting
`DJANGO_TRUST_X_FORWARDED_PROTO=true`, `DJANGO_API_NUM_PROXIES=1`, and the pinned
API version. A different host, production environment, empty enrollment, enabled
legacy switch or enabled global paid gate prevents startup. It does not contact
Square or prove account/location matching. Original Django production,
PostgreSQL, Redis, signing, email and deployment checks still run unchanged.

Keep legacy automatic-subscription switches
`SQUARE_SANDBOX_CHECKOUT_ENABLED`, `SQUARE_SANDBOX_RECONCILIATION_ENABLED` and
`SQUARE_SANDBOX_CANCELLATION_ENABLED` false. The current app-owned term flow does
not need `SQUARE_SANDBOX_PLAN_VARIATION_ID`. Its cancellation is a local stop of
future app-scheduled terms. Neither a Sandbox purchase nor changing the
discovery environment creates a production entitlement: grant writes explicitly
use `environment='sandbox'`, and production discovery queries production only.

Create the selected synthetic account through the normal hosted registration
and delivered-email verification flow, using the user-approved test credentials.
Read its numeric ID from its own authenticated `/api/accounts/me/` response and
enroll that exact ID privately in the server environment. Do not auto-verify it,
enroll by email/domain wildcard, or enroll restored/general parents by default.
Before enrollment its account/profile APIs work normally and it has no checkout
or plan-routing capability. A second plan test needs a separately enrolled test
parent or a reviewed canonical cleanup; never force an overlapping payment.

Environment changes take effect in each restarted server/worker process. Removing
an ID is not an instantaneous revocation across an old rolling deployment. Stop
worker dispatch during withdrawal and retire old processes. A financial request
already authorized while enrolled can still complete; retain and reconcile its
original intent/key instead of retrying a new purchase.

## Manual receipts, reconciliation and renewal operation

The webhook endpoint verifies the signature over the exact registered callback
URL and raw body, then stores a deduplicated receipt. A `200` is receipt
acknowledgment only. **There is no automatic receipt consumer or renewal scheduler
in `render.yaml`.** Do not claim refunds or lost responses update access merely
because the webhook subscription is enabled.

For an operator-authorized Sandbox test, these commands are bounded manual
operations from `Backend/Core` under the private server environment. Their
default invocations are dry runs with no provider calls:

```sh
python manage.py reconcile_square_sandbox --limit 1
python manage.py reconcile_square_terms --limit 1
python manage.py renew_square_terms --limit 1
```

`reconcile_square_sandbox --apply --limit 1` processes one due signed receipt with
canonical provider reads. In term mode it uses the term-reconciliation switch
and does not require the retired plan/variation configuration.
`reconcile_square_terms --apply --term <owned-term-uuid> --limit 1` reads one
existing term's canonical payment/refund evidence; if a lost payment ID is known
from the operator's private evidence, `--payment <payment-id>` is allowed only
with that exact term. These read-only provider operations can update local proof
and Sandbox access/revocation; they cannot create a payment or store a card.
The parent's password-only confirmation recovery can also finish the same
payment-backed card setup. Never send another token or create a new intent to
recover an uncertain charge.

`renew_square_terms --apply --limit 1` **can charge** one due enrolled Sandbox
agreement using the verified saved card and original consent. Do not run it for
the initial checkout canary or attach a scheduler until a separate renewal
qualification is approved. Do not alter coverage dates or advance a clock to
force a real provider charge. There is no catch-up charge for an expired missed
cycle. Future ongoing testing needs an explicitly operated receipt consumer and
renewal worker with monitoring, clock health and outage handling; free sleeping
web hosting alone does not provide them.

The official SDK is loaded only after verified sign-in and a confirmed quote.
The page uses no third-party analytics code of its own. Its CSP includes only
same-origin resources and Square's documented Sandbox/card dependencies,
including Square's documented telemetry host. Review the actual SDK's storage,
privacy and CSP behavior during qualification; this source work does not claim
that an external provider never stores data.

## Local verification and pending qualification

From `Backend/Core`, with a synthetic environment and isolated test database:

```sh
DJANGO_DEBUG=true ../.venv/bin/python manage.py test \
  apps.billing.test_parent_access apps.billing.test_parent_checkout_web \
  apps.billing.test_parent_checkout_integration --noinput
```

From the repository root:

```sh
node --test Backend/Core/apps/billing/test_parent_checkout_flow.mjs
python3 Backend/scripts/render_preflight.py
```

Mocks prove the full Django JWT-login/quote/reserve/confirm/entitlement/status
path for both prices, explicit restart after canonical nonpayment, and paid
card-setup recovery without a duplicate charge. They do not prove browser SDK,
3DS, real Square acceptance, public HTTPS hosting, App Store checkout policy,
production purchases or the mobile post-login access flow. Those require
separately authorized tests. Never record credentials, card entry, SDK sources,
JWTs or full network bodies in screenshots, HAR files or logs.

Primary sources checked 12 November 2026:
[Square card tokenization and CHARGE_AND_STORE](https://developer.squareup.com/docs/web-payments/take-card-payment),
[secure-context requirements](https://developer.squareup.com/docs/web-payments/overview),
[official Sandbox CSP dependencies](https://developer.squareup.com/docs/web-payments/content-security-policy).
