# Parent website checkout: Sandbox preparation

The new same-origin page is `/parent/checkout/`. It is a normal parent sign-in,
plan selection and card checkout, not a developer control panel. It is **off by
default** and refuses production Square configuration, HTTP, an unexpected
origin and query-bearing page links. The phone purchase action remains disabled;
no mobile route, session, child selection or paid-routing behavior changed.

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
  alter production access discovery. Account APIs retain their existing access.
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
- Existing explicit Sandbox billing, transport and reconciliation configuration
  must be separately enabled/qualified by the operator. No activation is implied
  by rendering templates or by `checkout.state=available`, which means only that
  local Sandbox configuration is present. Actual provider acceptance remains a
  canary result, not a configuration claim.
- Use only approved synthetic verified parents, Square test cards and a separate
  staging database. Email-disabled staging cannot register or auto-verify an
  account; follow its separately approved fixture/guard procedure. Preserve all
  other production secret, PostgreSQL, shared-cache and HTTPS protections.

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
