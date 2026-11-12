import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { appReturnUrl, initPaymentReturn } from '../src/scripts/payment-return.mjs';
import { domFixture } from './dom-fixture.mjs';

const attempt = '11111111-1111-4111-8111-111111111111', state = '22222222-2222-4222-8222-222222222222';
const page = readFileSync(new URL('../src/pages/payments/return.astro', import.meta.url), 'utf8');
const inline = page.match(/<script is:inline>([\s\S]*?)<\/script>/)[1];
function readContext(search, changes = {}) {
  let cleared;
  const context = { URLSearchParams, location: { origin: 'https://kingdom-kids.app', pathname: '/payments/return/', hash: '', search, ...changes },
    history: { replaceState(_state, _title, path) { cleared = path; } } };
  vm.runInNewContext(inline, context);
  assert.equal(cleared, '/payments/return/');
  return context.__kkPaymentReturn;
}
test('actual first inline script accepts only exact two correlation UUIDs and immediately clears address', () => {
  const context = readContext(`?attempt=${attempt}&state=${state}`);
  assert.equal(context.attempt, attempt); assert.equal(context.state, state);
  assert.equal(appReturnUrl(context), `kingdomkids://payments/return/?attempt=${attempt}&state=${state}`);
  for (const query of ['', `?attempt=${attempt}`, `?attempt=${attempt}&state=${state}&state=${state}`,
    `?attempt=${attempt}&state=${state}&token=private`, `?attempt=${attempt}&state=${state}&payment_id=untrusted`,
    '?attempt=bad&state=bad']) assert.equal(readContext(query), null);
  assert.equal(readContext(`?attempt=${attempt}&state=${state}`, { hash: '#access=private' }), null);
  assert.equal(readContext(`?attempt=${attempt}&state=${state}`, { origin: 'https://attacker.test' }), null);
  assert.equal(readContext(`?attempt=${attempt}&state=${state}`, { pathname: '/payments/return' }), null);
  assert.equal(appReturnUrl({ attempt, state, token: 'private' }), null);
});
test('browser fallback only opens on user action, retains generic status and performs no verification or charge', () => {
  const { doc, options, advance } = domFixture(), elements = { 'open-app': doc.createElement('a'), 'return-status': doc.createElement('p') };
  elements['open-app'].hidden = true; doc.getElementById = (id) => elements[id];
  const listeners = {}, win = { __kkPaymentReturn: { attempt, state },
    addEventListener(name, fn) { listeners[name] = fn; }, removeEventListener(name) { delete listeners[name]; } };
  initPaymentReturn(doc, win, options);
  assert.equal('__kkPaymentReturn' in win, false);
  assert.equal(elements['open-app'].href, `kingdomkids://payments/return/?attempt=${attempt}&state=${state}`);
  assert.equal(elements['open-app'].getAttribute('aria-busy'), undefined);
  elements['open-app'].emit('click'); assert.equal(elements['open-app'].getAttribute('aria-busy'), 'true');
  assert.match(elements['return-status'].textContent, /will be checked.*app/);
  advance(1500); assert.equal(elements['open-app'].getAttribute('aria-busy'), undefined);
  assert.match(elements['return-status'].textContent, /home screen/);
  assert.doesNotMatch(elements['return-status'].textContent, /confirmed|successful|active/);
  listeners.pagehide({ persisted: false }); assert.equal(elements['open-app'].hidden, true);
});
test('exact-path AASA and static headers expose no broad app links, auth requirement or redirect', () => {
  const association = JSON.parse(readFileSync(new URL('../public/.well-known/apple-app-site-association', import.meta.url)));
  assert.deepEqual(association.applinks.details, [{ appIDs: ['GG228DP7G6.app.kingdom-kids.kingdomkids', 'VTV9889TNF.com.andreovien.kingdomkids'],
    components: [{ '/': '/payments/return/', comment: 'Payment return correlation only; the app authenticates and verifies access separately.' }] }]);
  const config = JSON.parse(readFileSync(new URL('../vercel.json', import.meta.url)));
  const headers = Object.fromEntries(config.headers.find((entry) => entry.source === '/.well-known/apple-app-site-association').headers.map((entry) => [entry.key, entry.value]));
  assert.equal(headers['Content-Type'], 'application/json');
  assert.equal((config.redirects ?? []).length, 0);
  assert.ok(config.rewrites.every((entry) => !entry.source.includes('payments') && !entry.source.includes('well-known')));
  assert.match(page, /name="referrer" content="no-referrer"/);
});
