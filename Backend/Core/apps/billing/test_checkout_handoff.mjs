import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const source = readFileSync(new URL('./static/billing/checkout_handoff.js', import.meta.url));
const { takeHandoff, redeemHandoff, revokeHandoff } = await import('data:text/javascript;base64,' + source.toString('base64'));
const code = 'a'.repeat(43);
const fixture = (changes = {}) => ({ schema_version: 1, environment: 'sandbox', purpose: 'purchase',
  billing_period: 'monthly', parent: { id: '41', email: 'parent@example.test', email_verified: true },
  checkout_token: 'kkco.' + 'b'.repeat(60), expires_at: new Date(Date.now() + 60000).toISOString(), ...changes });
const runtime = { environment: 'sandbox' };

test('code fragment is cleared before any other operation and app credentials are never read', () => {
  const events = [];
  const result = takeHandoff({ hash: '#handoff=' + code, pathname: '/parent/checkout/', search: '?plan=monthly' },
    { replaceState: (...args) => events.push(args) });
  assert.equal(result, code);
  assert.deepEqual(events, [[null, '', '/parent/checkout/?plan=monthly']]);
});

test('malformed fragments are removed and never accepted as auth or echoed in an error', () => {
  for (const hash of ['#access_token=private-synthetic', '#handoff=short', '#handoff=' + code + '&parent=other']) {
    let removed = false;
    assert.throws(() => takeHandoff({ hash, pathname: '/parent/checkout/', search: '' },
      { replaceState: () => { removed = true; } }), /^Error: Open checkout again from the app\.$/);
    assert.equal(removed, true);
  }
  assert.equal(takeHandoff({ hash: '' }, { replaceState: () => assert.fail('no hash') }), null);
});

test('exchange sends code only to fixed same-origin POST with no cookies redirects or app auth', async () => {
  const seen = [];
  const value = await redeemHandoff(code, { runtime, expectedPlan: 'monthly', fetcher: async (...args) => {
    seen.push(args); return Response.json(fixture());
  } });
  assert.equal(value.parent.id, '41');
  assert.equal(seen[0][0], '/api/billing/checkout-handoffs/redeem/');
  const options = seen[0][1];
  assert.deepEqual(JSON.parse(options.body), { code });
  assert.equal(options.credentials, 'omit'); assert.equal(options.redirect, 'error');
  assert.equal(options.cache, 'no-store'); assert.equal(options.referrerPolicy, 'no-referrer');
  assert.equal(options.headers.Authorization, undefined);
});

test('wrong environment purpose plan parent type token or expiry is rejected', async () => {
  for (const change of [{ environment: 'production' }, { purpose: 'manage' }, { billing_period: 'yearly' },
    { parent: { id: 41, email: 'parent@example.test' } }, { checkout_token: 'an-application-jwt' },
    { expires_at: new Date(Date.now() - 1000).toISOString() },
    { expires_at: new Date(Date.now() + 700000).toISOString() }]) {
    await assert.rejects(redeemHandoff(code, { runtime, expectedPlan: 'monthly',
      fetcher: async () => Response.json(fixture(change)) }), /Open checkout again from the app/);
  }
});

test('explicit manage and production envelopes are separate', async () => {
  const value = await redeemHandoff(code, { runtime: { environment: 'production' }, expectedPurpose: 'manage',
    fetcher: async () => Response.json(fixture({ environment: 'production', purpose: 'manage', billing_period: null })) });
  assert.equal(value.purpose, 'manage'); assert.equal(value.billing_period, null);
});

test('non-JSON errors and oversized bodies fail without retaining the provider response', async () => {
  for (const response of [new Response('private-synthetic', { status: 503 }),
    new Response('x'.repeat(9000), { headers: { 'Content-Type': 'application/json' } })]) {
    await assert.rejects(redeemHandoff(code, { runtime, expectedPlan: 'monthly', fetcher: async () => response }),
      /Open checkout again from the app/);
  }
});

test('sign-out revokes only the checkout token with best-effort fixed-origin request', async () => {
  const calls = [];
  revokeHandoff('ordinary-app-jwt', (...args) => calls.push(args));
  assert.equal(calls.length, 0);
  revokeHandoff(fixture().checkout_token, (...args) => { calls.push(args); return Promise.resolve(); });
  assert.equal(calls[0][0], '/api/billing/checkout-handoffs/revoke/');
  assert.equal(calls[0][1].keepalive, true);
  assert.equal(calls[0][1].credentials, 'omit');
});
