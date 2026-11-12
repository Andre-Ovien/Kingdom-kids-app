# Square-hosted production subscriptions on the existing Free backend

This is the selected recurring-checkout architecture. Square hosts card entry,
stores the recurring instrument and schedules renewal charges. A paid Render web,
worker, cron or custom API domain is not required to make those provider charges.
The application must still reconcile canonical provider evidence before granting
access; a redirect, active subscription, webhook acknowledgment or SDK outcome is
not proof of payment. No source example activates credentials or sends a charge.

## Explicit, mutually exclusive startup profile

Use the existing exact backend origin
`https://kingdom-kids-checkout-staging.onrender.com`, with that hostname as the
sole `DJANGO_ALLOWED_HOSTS`. `PARENT_CHECKOUT_ORIGIN` must match exactly, and
`SQUARE_PRODUCTION_WEBHOOK_NOTIFICATION_URL` must be that origin plus
`/api/billing/square/webhook/`. Keep the reviewed production signature key and
token/merchant/location/application slots private. API version is `2026-09-16`,
active and entitlement environments are both `production`, and the trusted HTTPS
proxy settings remain `true` and `1`. The optional approved-origin slot may be
empty or the same exact backend origin; no custom-domain attestation is used.
Hosted provider request timeouts must be between one and five seconds
(`SQUARE_HTTP_TIMEOUT_SECONDS`, default five). Reconciliation shares a bounded
provider-read budget and deadline; it does not admit another call after that
deadline. An already-running bounded request may finish after the admission
deadline. The separate native request timeout and pending UI must account for it.

These literal flags must be `true`:

```text
RENDER_HOSTED_PRODUCTION_CHECKOUT_ENABLED
SQUARE_PRODUCTION_HOSTED_SUBSCRIPTIONS_ENABLED
SQUARE_HOSTED_RELEASE_QUALIFIED
SQUARE_PRODUCTION_ENABLED
SQUARE_PRODUCTION_HTTP_TRANSPORT_ENABLED
PARENT_CONTENT_ACCESS_STATUS_ENABLED
PAID_CONTENT_ENFORCEMENT_ENABLED
DJANGO_EMAIL_DELIVERY_ENABLED
CLOUDINARY_PRIVATE_DELIVERY_ENABLED
```

Supply distinct, canonically reviewed production variation IDs in
`SQUARE_PRODUCTION_HOSTED_MONTHLY_VARIATION_ID` and
`SQUARE_PRODUCTION_HOSTED_YEARLY_VARIATION_ID`. Startup accepts bounded provider
identifier shapes, not arbitrary unbounded text, and never treats that shape as
proof of the plan's price or cadence. The separate hosted release gate is an
operator declaration after reviewing the exact production merchant/location and
the $9.99/30-day and $99.90/annual plan policies. Do not enable it merely because
keys or IDs are present. No fixed billing anchor, shortened first period, free
trial or prorated amount may silently replace the reviewed offer.

All active verified parents are eligible; there is no checkout parent allowlist.
The controlled-parent ID slot must be empty, all Sandbox credentials/plan IDs/
test enrollment must be empty or absent, and temporary import/lookup keys must
be removed. The full old app-scheduled release, restricted one-period profile,
Sandbox profile, old checkout/term dispatch and every scheduled billing job must
remain off. In particular:

```text
RENDER_PRODUCTION_CHECKOUT_QUALIFICATION_ENABLED=false
RENDER_CONTROLLED_PRODUCTION_CHECKOUT_ENABLED=false
RENDER_SANDBOX_CHECKOUT_QUALIFICATION_ENABLED=false
RENDER_PRODUCTION_OPERATIONS_QUALIFIED=false
RENDER_PRODUCTION_CUSTOM_DOMAIN_VERIFIED=false
SQUARE_PRODUCTION_RELEASE_QUALIFIED=false
SQUARE_PRODUCTION_CONTROLLED_CHECKOUT_ENABLED=false
SQUARE_PRODUCTION_CONTROLLED_PARENT_IDS=
SQUARE_PRODUCTION_CHECKOUT_ENABLED=false
PARENT_CHECKOUT_PRODUCTION_ENABLED=false
SQUARE_PRODUCTION_TERM_BILLING_ENABLED=false
SQUARE_PRODUCTION_TERM_RECONCILIATION_ENABLED=false
SQUARE_PRODUCTION_RENEWALS_ENABLED=false
SQUARE_PRODUCTION_RECONCILIATION_JOBS_ENABLED=false
SQUARE_PRODUCTION_RENEWAL_JOBS_ENABLED=false
SQUARE_SANDBOX_RECONCILIATION_JOBS_ENABLED=false
SQUARE_SANDBOX_RENEWAL_JOBS_ENABLED=false
SQUARE_SANDBOX_HOSTED_SUBSCRIPTIONS_ENABLED=false
```

Every other Sandbox/legacy financial flag remains false. Parent handoff for
separate legacy management is an independent explicit boolean; it does not
authorize a new hosted purchase or create any app-scheduled renewal. Original
debug, independent signing/peppers, PostgreSQL/TLS, private cache, email, private
media, deployment checks and locked migration/content bootstrap remain intact.
The startup launches only Gunicorn. Existing old purchase records remain owned
history for separately guarded read/recovery/cancellation after the cutover.

The root Free Blueprint keeps its current web/DB/cache resource identities,
plans and automatic commit deployments. Its declared old financial/status gates
are `sync: false`; existing Blueprint updates cannot reset the owner-selected
profile. The full public app-scheduled jobs template and paid promotion example
are unrelated, inactive alternatives and must not be applied for this profile.

## Return and notifications

The exact HTTPS return page is
`https://kingdom-kids.app/payments/return/`. It accepts only `attempt=<UUID>` and
`state=<UUID>`, clears the address before loading its module, and keeps sanitized
correlation in memory. Neither UUID authenticates or grants access. No app JWT,
email, card/source value, provider payment ID or read capability belongs in that
URL. Unknown/duplicate parameters and fragments are rejected.

Universal Links claim only this exact path. The current development application
identifier is `VTV9889TNF.com.andreovien.kingdomkids`; final client publishing-team
ownership remains a separate release verification. The extensionless AASA file
must return HTTP200 with JSON MIME and no authentication or redirect. Verify that
actual hosted response after deployment; static source checks are not DNS/CDN
or installed-device proof.

The browser fallback is intentionally generic: it offers an explicit
`kingdomkids://payments/return/?attempt=…&state=…` link, with no automatic opening
loop. Only the native authenticated, owned canonical reconciliation can show
payment success. The fallback neither calls a payment endpoint nor claims paid.

Our forms, return and merchant-management pages share one notification module:
five seconds, right edge retreating to the left, then a short fade; hover,
keyboard focus and hidden tabs pause the countdown. Persistent status and pending
instructions remain accessible after the toast disappears. Square's hosted page
is controlled by Square; our scripts/styles are not injected into its UI.

The old merchant fallback automatically polls local verified access after an
uncertain buyer action, for at most six GETs and a 90-second deadline with bounded
requests. It never automatically calls `/confirm/`, saves a card, submits a new
source or changes an intent key. This can observe a payment already reconciled
by the server; local-only status polling cannot itself repair missing provider
proof. The new hosted reconciliation must do bounded canonical provider reads
on authenticated return/resume and process signed renewal/refund evidence.

## Free hosting and noncharging qualification

Square-owned renewals continue independently of a sleeping app server. Free web
cold starts can delay verification, so the five-second toast is feedback timing,
not a payment-verification deadline. Square webhook retries are bounded; durable
inbox recording plus on-demand canonical recovery must handle missed delivery.
Free database expiry/data retention still requires owner attention. None of this
silently provisions or requires a paid service.

`python scripts/production_checkout_preflight.py` selects the hosted profile when
its startup flag is present. Output is redacted and noncharging, identifies
`provider_hosted_production` and Square as the renewal controller, and makes no
public-release, actual renewal, scheduler, provider or database-readiness claim.
It changes no environment values and loads no credential file/DB/provider. A
zero exit means local configuration checks only. Canonical merchant/plan evidence,
signed callback delivery, actual owned reconciliation/cancellation, and the
separate storefront/privacy/distribution release requirements remain evidence
outside this script. Keep credentials, family data and signing identities stable.
