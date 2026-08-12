# Kingdom Kids website

Static Astro website for Kingdom Kids, including the launch waitlist, public privacy policy, and self-service account deletion.

Use the Node.js version pinned in `.node-version` for local, CI, and release
builds. `package.json` also fails unsupported runtime ranges explicitly.

## Local commands

```sh
npm ci
npm run dev
npm run check
npm run build
npm run verify:security
npm audit --omit=dev
```

The local Vite server proxies `/api/*` to `http://127.0.0.1:8000`. That proxy exists only during `npm run dev`.

## Production routing requirement

The generated site is static. The production host/CDN **must** reverse-proxy same-origin requests from:

```text
https://kingdom-kids.app/api/*
```

to the HTTPS Django API while preserving the path, HTTP method, JSON body, `Authorization` header, and correct forwarded host/protocol. This route supports:

- `POST /api/accounts/waitlist/`
- `POST /api/accounts/account-deletion/request/`
- `POST /api/accounts/account-deletion/confirm/`

Do not cache `/api/*` responses. Do not log email-verification codes or deletion request bodies. Keep backend throttling enabled. A direct cross-origin API hostname requires an explicit, narrow CORS allowlist and should not replace the same-origin route without a reviewed deployment change.

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

1. Confirm `/`, `/privacy/`, and `/account-deletion/` return `200`, canonical URLs use HTTPS, and legal links are reachable without the app.
2. Submit a valid and invalid waitlist address through the deployed same-origin `/api` path and confirm responses are not cached.
3. Create a disposable parent account with child activity. On `/account-deletion/`, verify an unknown email receives the same request response and a wrong, expired, or over-attempted code cannot delete anything.
4. Complete the emailed-code flow and explicit final confirmation; confirm the page reports success, subsequent login fails, associated child/profile activity is gone, and any same-email waitlist row is gone.
5. Inspect cookies, local storage, session storage, browser logs, proxy logs, and analytics/network tooling to confirm challenge handles and email codes were not persisted or logged.
6. Test offline, timeout, `429`, and API `5xx` responses; status updates must remain understandable to keyboard and screen-reader users.
7. Verify TLS, redirects, CSP, HSTS, framing protection, MIME protection, referrer policy, and permissions policy with the actual CDN configuration.

## Artwork

The website reuses approved Bible-story and mascot artwork from the mobile project. Remove unused files from `public/` before final deployment to reduce upload size.
