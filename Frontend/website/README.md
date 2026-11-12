# Kingdom Kids website

Static Astro website for Kingdom Kids, including the launch waitlist, contact form, public privacy policy, and self-service account deletion.

Use the Node.js version pinned in `.node-version` for local, CI, and release
builds. `package.json` also fails unsupported runtime ranges explicitly.

## Local commands

```sh
npm ci
npm run dev
npm test
npm run check
npm run build
npm run verify:security
npm audit --omit=dev
```

The local Vite server proxies `/api/*` to `http://127.0.0.1:8100`, matching the
phone-review API. To use a backend on a different port, pass a server-only
environment variable, for example
`KINGDOM_KIDS_API_ORIGIN=http://127.0.0.1:8000 npm run dev`.
That proxy exists only during `npm run dev`; it is not embedded in `dist/`.

The production artifact is the static `dist/` directory. Do not deploy the
development/preview server or `node_modules` as the public website. The October
3, 2026 dependency audit upgraded Astro and vulnerable transitive packages.
One unpatched advisory remains in `http-cache-semantics` (CVE-2026-93748), also
reported against its Astro parent. In this project that package is used only by
Astro's build-time remote-image cache; the pages use local images, and neither
the static browser artifact nor the Django API uses that cache. Keep `/api/*`
uncached at the reverse proxy and recheck the advisory before adding server
rendering or authenticated remote images. See the
[upstream advisory](https://github.com/advisories/GHSA-ch52-4w7c-c8xp).

## Production routing

The public site is hosted on Vercel. Set its project root to `Frontend/website`,
build command to `npm run build`, and output directory to `dist`.
`vercel.json` proxies only these four same-origin public paths to the verified
HTTPS backend `https://kingdom-kids-checkout-staging.onrender.com`, preserving
each path rather than sending visitors to a developer machine:

- `POST /api/accounts/waitlist/`
- `POST /api/accounts/contact/`
- `POST /api/accounts/account-deletion/request/`
- `POST /api/accounts/account-deletion/confirm/`

The API paths have explicit browser/CDN `no-store` headers. No login, paid
checkout, admin, or arbitrary API routes are exposed by this configuration.
If the production backend changes, update the four reviewed destinations and
the routing test together. Keep backend throttling enabled and do not log
form bodies or email-verification codes. Vercel documents external rewrites
as reverse proxies: <https://vercel.com/docs/routing/rewrites>.

Waitlist registration records the address and consent; it does not send a
confirmation email. Its duplicate-safe acknowledgement is HTTP `202` JSON.
The contact form at `/contact/` sends `{title, email, message, website,
request_id?}` to Django. Resend credentials, sender and fixed recipient are
server-only. A visitor's email is Reply-To, not a caller-selected recipient.
Contact delivery remains unavailable until the backend email configuration
and verified sender are ready; the page shows an error and retains the text.

Shared form handlers require the expected `202` JSON acknowledgement, so a
static host's HTML page cannot appear as a successful submission. They block
overlapping submissions, allow an explicit retry after errors, and use one
bounded 60-second request (including the response body) without automatic
retries. Contact retries of an unchanged message retain an in-memory UUID;
editing the message starts a new submission. Nothing is persisted to browser
storage. This client guard does not replace backend idempotency or throttles.

After deployment, a GET to each POST-only public API route should reach Django
and return method-not-allowed, rather than Vercel `NOT_FOUND`. Only an actual
consented form submission plus delivery confirmation qualifies working email.
No Resend key or SMTP credential belongs in Astro environment variables or
browser assets.

## HTTPS and security headers

Redirect HTTP to HTTPS and configure these headers at the production CDN/host:

- `Strict-Transport-Security: max-age=31536000; includeSubDomains` after every covered subdomain is HTTPS-ready.
- `Content-Security-Policy` with `default-src 'self'`, `base-uri 'self'`, `frame-ancestors 'none'`, `form-action 'self'`, `connect-src 'self'`, and only the required self-hosted image/font/style sources. Generate SHA-256 hashes for every generated inline script and style block—including the account-deletion module—instead of enabling broad `unsafe-inline` execution.
- `X-Content-Type-Options: nosniff`
- `Referrer-Policy: strict-origin-when-cross-origin`
- `Permissions-Policy: camera=(), microphone=(), geolocation=()`
- `Cross-Origin-Opener-Policy: same-origin`

Recalculate CSP hashes after every build that changes inline script or style content.

## Privacy launch gate

The centralized provisional privacy contact is:

```text
privacy@kingdom-kids.app
```

This inbox **must be provisioned, monitored, and tested before launch**. Before publishing, also finalize production hosting/email vendors, processing regions, contracts, log retention, backup rotation, and any international-transfer terms, then update `/privacy/` if those facts change the pre-launch policy.

The public Google Play account-deletion URL is:

```text
https://kingdom-kids.app/account-deletion/
```

## Release smoke tests

Run these against the deployed production origin, not only `astro preview`:

1. Confirm `/`, `/contact/`, `/privacy/`, and `/account-deletion/` return `200`, canonical URLs use HTTPS, and legal links are reachable without the app.
2. Submit a consented valid and invalid waitlist address through the deployed same-origin `/api` path and confirm responses are not cached. Test the contact form with an operator-approved recipient/test message; confirm `202` and actual inbox delivery, then test mail-disabled `503` without losing the entered message.
3. Create a disposable parent account with child activity. On `/account-deletion/`, verify an unknown email receives the same request response and a wrong, expired, or over-attempted code cannot delete anything.
4. Complete the emailed-code flow and explicit final confirmation; confirm the page reports success, subsequent login fails, associated child/profile activity is gone, and any same-email waitlist row is gone.
5. Inspect cookies, local storage, session storage, browser logs, proxy logs, and analytics/network tooling to confirm challenge handles and email codes were not persisted or logged.
6. Test offline, timeout, `429`, and API `5xx` responses; status updates must remain understandable to keyboard and screen-reader users.
7. Verify TLS, redirects, CSP, HSTS, framing protection, MIME protection, referrer policy, and permissions policy with the actual CDN configuration.

## Artwork

The website reuses approved Bible-story and mascot artwork from the mobile project. Remove unused files from `public/` before final deployment to reduce upload size.
