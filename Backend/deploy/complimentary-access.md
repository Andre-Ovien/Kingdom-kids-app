# Owned complimentary test access

A complimentary grant is independent of Square/App Store payments. It creates no provider order, payment, subscription, entitlement or renewal. All other parents keep the normal production access gate. The approved parent must remain active and verified; access has an explicit expiry of at most thirty days and can be revoked.

The ledger records parent, environment, feature, immutable request UUID, approved owner fingerprint, start/end, reason and operator reference. Repeating the same request returns the original grant; it cannot extend, reassign or undo revocation. Multiple active complimentary grants use the furthest individually revocation-clipped end. Overall content access is the maximum of complimentary coverage and the existing verified paid coverage. The existing conservative selection among paid proofs is unchanged.

The public status uses legacy `access_state: paid` to mean authorized access, plus explicit `access_basis: complimentary`, `reason_code: complimentary_access`, `payment_confirmed: false`, and finite `access_until`. Purchase, renewal/cancellation capabilities and recovery objects are unavailable in complimentary presentation. The financial `verified_paid_coverage_until` helper remains empty without real provider proof. Private media URLs and content APIs use the finite canonical content authorization.

A grant refuses unresolved or renewing production billing work so it cannot hide an existing financial obligation. Sandbox history is neither promoted nor changed. No public grant endpoint exists.

## One-time operation on the existing Free Render host

[Render's shell matrix](https://render.com/docs/ssh) excludes Free web services, so the source includes a default-absent startup operation after ordinary production validation, Django deploy checks, migrations and content installation. It performs no provider I/O. All operation variables are removed from the process environment before Gunicorn starts, including rejected inputs. Root/operator applies these values; source tests never use the live database.

Set only for the approved account and remove the persisted Render variables after the receipt:

| Variable | Required value |
| --- | --- |
| `KK_COMPLIMENTARY_ACCESS_OPERATION` | `grant` |
| `KK_COMPLIMENTARY_ACCESS_PARENT_ID` | Exact approved numeric parent ID |
| `KK_COMPLIMENTARY_ACCESS_ENVIRONMENT` | `production` |
| `KK_COMPLIMENTARY_ACCESS_REQUEST_ID` | New canonical lowercase UUID, persisted for retries |
| `KK_COMPLIMENTARY_ACCESS_OWNER_SHA256` | Privately calculate SHA256 of `<numeric-id>:<trimmed-lowercase-email>` |
| `KK_COMPLIMENTARY_ACCESS_VALID_UNTIL` | Explicit aware ISO timestamp within thirty days |
| `KK_COMPLIMENTARY_ACCESS_AUTHORIZED_BY` | Non-personal operator reference, e.g. `user_request_20261112` |
| `KK_COMPLIMENTARY_ACCESS_REASON` | `user_requested_test_access` |

The startup context must be the exact approved HTTPS Render host and qualified hosted-production profile, with production entitlement environment and normal content enforcement/status. A wrong account fingerprint or ineligible parent is rejected. No email, numeric owner ID, fingerprint, token or DB exception is logged.

Success logs a fixed `KK_COMPLIMENTARY_ACCESS_RECEIPT` with grant UUID, environment, expiry, state and changed/replay boolean. Refusals log only `KK_COMPLIMENTARY_ACCESS_REFUSED reason=<static-code>`: `invalid_owner`, `unresolved_financial_work`, `invalid_expiry`, `invalid_request`, `invalid_profile`, `grant_conflict`, `grant_not_found`, or `internal_error`.

For revocation, use `OPERATION=revoke`, the same exact owner/environment/fingerprint/operator/reason, a new stable `REQUEST_ID`, and `KK_COMPLIMENTARY_ACCESS_GRANT_ID` from the grant receipt. Omit `VALID_UNTIL`. A repeated identical revocation is idempotent. Access ends immediately at canonical revocation while independent paid access, if any, remains valid.
