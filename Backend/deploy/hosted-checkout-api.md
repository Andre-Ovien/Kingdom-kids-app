# Native Square-hosted checkout API

This is a source contract with synthetic regression coverage. Provider-managed recurring checkout is independently default OFF. The operator's `SQUARE_HOSTED_RELEASE_QUALIFIED` declaration records merchant/location/catalog/policy review; credential presence does not activate it. It does not assert that an actual hosted signup or elapsed renewal has been observed.

Only an active verified parent authenticated with the normal app JWT can use `/api/billing/square/hosted-checkout/`. Checkout-audience browser tokens are not accepted. The server selects the environment; no caller can supply an environment, amount, provider URL or return URL.

| Method and suffix | Input | Result |
| --- | --- | --- |
| GET `quote/` | Exactly one `billing_period=monthly` or `yearly` | Canonical provider-checked fixed price/cadence, frozen disclosure/hash and parent/environment identity |
| POST `authorize/` | `operation_id` client UUID, `billing_period`, fresh `password`, `accepted: true`, exact `disclosure_version` and `disclosure_sha256` | Owned attempt and short-lived opaque `authorization_token` in JSON body only |
| POST `prepare/` | Same `operation_id`, `billing_period`, `authorization_token` | Exactly the same frozen idempotent API-created link; no automatic rekey or replacement |
| GET `attempts/<UUID>/status/` | No financial input | Local owned canonical-proof status, no provider mutation |
| POST `attempts/<UUID>/reconcile/` | `{}` | Bounded canonical reads, no payment/card/link creation |
| POST `attempts/<UUID>/cancel/` | Fresh `password` | Revoke owned unused link and stop future owned Square renewal; preserve verified paid end |

All replies are private/no-store. Wrong owner/environment is 404. Uncertainty is 409/503 and retains the same attempt; it is never an instruction to create another operation. A definitive wrong password is `invalid_parent_password`. Native authorization is the only fresh password step before Square's own Pay action. No app JWT or parent password is placed in a URL.

Quote identity includes `schema_version: 1`, string `parent_id`, explicit `environment`, `billing_period`, integer `amount_minor` (999 or 9990), `currency: USD`, policy/disclosure hashes, `automatic_renewal: true`, `billing_controller: square_hosted_subscriptions`, and `cadence: THIRTY_DAYS|ANNUAL`.

Attempt envelopes include that parent/environment/plan/amount identity plus UUID `attempt_id`, original `operation_id`, UUID non-auth `return_state`, `state`, `checkout_url` (only ready), `payment_confirmed`, `access_state`, `access_until`, `renewals_enabled`, `cancel_requested` and `cancellation_confirmed`. States are reserved, creating, ready, pending, paid, failed, canceled or review_required. `ready` only means that the same single-use owned Square link can be opened; settlement can remain unknown. It never proves failure, unpaid settlement or paid access. A still-valid owned link can be resumed explicitly after canonical link/template reads, without creating a new link or operation.

The success return is fixed to `https://kingdom-kids.app/payments/return/?attempt=<UUID>&state=<UUID>`. These UUIDs correlate a return but grant no authority. The public browser page is generic; normal app JWT ownership and canonical reconciliation determine success. Production provider URLs allow only HTTPS `square.link/u/<token>` or `checkout.square.site/merchant/<merchant>/order/<order>`, with no query, fragment, credentials or alternate port.

## Paid proof and bounded work

The exact chain is frozen app parent/operation → server-created owned order template and single-use payment link → canonical subscription phase `order_template_id` → exact variation/location/customer → canonical invoice membership (`subscription_id`, `order_id`, `invoice_ids`) → billed order → canonical completed CARD payment with exact customer, USD amount/location and actual capture timestamp. Canonical merchant/location and static variation are rechecked. Buyer-entered email/phone, redirects, webhook envelopes, ACTIVE status and charged-through dates cannot grant access.

Each actually verified capture grants the immutable full period: 30 elapsed days for monthly, or one local calendar anniversary for yearly. Square's financial cadence follows subscription billing dates; future charges are not represented as guaranteed 720-hour capture intervals. The hosted policies are distinct from historical app-owned/controlled policy versions.

A reconciliation pass admits at most 24 canonical reads and stops starting reads after an eight-second deadline (one already-running transport request can outlast that deadline). Hosted transport timeout configuration is capped at five seconds. One invoice is processed per pass: an exact signed invoice/refund hint first, otherwise a durable per-attempt cursor. This allows bounded progress through history without repeatedly exhausting the budget. Paid expiry is derived from capture proof, never array position.

Signed webhooks first persist a deduplicated inbox receipt. Hosted receipts then run bounded canonical read reconciliation; unresolved results return 503 for Square retry. Required object events are subscription created/updated, invoice payment/updated/refunded and payment/refund updates. Initial unmatched payment events wait for the exact invoice/subscription binding; no customer-only fallback exists.

Canonical full completed refunds revoke only their exact proof. Partial/inconsistent or pending refund facts cannot revoke unrelated/newer paid periods. Repeated confirmation cannot extend a paid period. Stopping future renewal is separate from resolving a currently pending charge: the owned attempt stays open while settlement remains unresolved, preventing another monthly/yearly purchase.

## Cancellation and deletion retention

Account deletion queues hosted cancellation atomically, retains provider-only attempt/proof/outbox rows, clears parent authorization and sets the parent relation to NULL. A bounded post-commit attempt and later signed events drain the owned cancellation. Provider failure preserves a pending outbox instead of losing the reference. No network call occurs inside account deletion locks. A lost cancellation response is resolved with canonical reads; this implementation does not blindly repeat its cancellation POST. Pending rows require canonical recovery/operator attention if Square never delivers a usable follow-up event.

Future-renewal cancellation is reported confirmed only from canonical canceled date/terminal status. It does not revoke the existing paid end and does not prove that an in-flight first invoice failed. New checkout remains blocked until that purchase's settlement is resolved.

## Evidence limits

Square documents hosted recurring checkout and the template-order metadata bridge. The observed Sandbox hosted test panel created a one-off payment without a subscription/customer chain; it is deliberately rejected as subscribed/paid proof here. Actual STATIC hosted subscription phase/template and first invoice/payment shape, actual hosted signup and elapsed renewals remain separately unobserved. Synthetic fixtures demonstrate the declared canonical contract and failure isolation, not provider end-to-end qualification.

Official references: [hosted subscriptions](https://developer.squareup.com/docs/checkout-api/subscription-plan-checkout), [API links are single-use](https://developer.squareup.com/docs/checkout-api/common-pitfalls), [Square staff template metadata bridge](https://developer.squareup.com/forums/t/pass-customer-id-to-a-payment-link/20921/5), [subscription billing](https://developer.squareup.com/docs/subscriptions-api/subscription-billing), [cancellation](https://developer.squareup.com/reference/square/subscriptions-api/cancel-subscription).
