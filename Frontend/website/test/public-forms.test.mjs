import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { postPublicForm } from '../src/scripts/public-form-request.mjs';
import { initWaitlistForm } from '../src/scripts/waitlist.mjs';
import { initContactForm } from '../src/scripts/contact.mjs';

const accepted = () => Response.json({ detail: 'Thanks. Your request has been received.' }, { status: 202 });
const endpoint = '/api/accounts/waitlist/';

class Element {
  dataset = {};
  attributes = {};
  listeners = new Map();
  value = '';
  disabled = false;
  textContent = '';
  validity = { valid: true };
  focused = false;
  constructor(children = {}) { this.children = children; }
  querySelector(selector) { return this.children[selector]; }
  setAttribute(key, value) { this.attributes[key] = value; }
  addEventListener(event, handler) {
    const handlers = this.listeners.get(event) ?? [];
    handlers.push(handler); this.listeners.set(event, handlers);
  }
  async emit(event) { await Promise.all((this.listeners.get(event) ?? []).map((handler) => handler({ preventDefault() {} }))); }
  focus() { this.focused = true; }
}
function fixture(kind) {
  const names = kind === 'waitlist'
    ? ['email', 'submit', 'button-label', 'status']
    : ['fields', 'title', 'email', 'message', 'website', 'submit', 'status'];
  const elements = Object.fromEntries(names.map((name) => [name, new Element()]));
  const form = new Element(Object.fromEntries(names.map((name) => [`[data-${kind}-${name}]`, elements[name]])));
  return { form, ...elements };
}

test('202 JSON acknowledgement submits exactly the safe same-origin request', async () => {
  let calls = 0;
  const result = await postPublicForm(endpoint, { email: 'parent@example.com' }, { fetchImpl: async (url, init) => {
    calls++; assert.equal(url, endpoint); assert.equal(init.method, 'POST');
    assert.equal(init.credentials, 'omit'); assert.equal(init.redirect, 'error');
    assert.equal(init.cache, 'no-store'); assert.equal(init.referrerPolicy, 'same-origin');
    assert.deepEqual(JSON.parse(init.body), { email: 'parent@example.com' });
    assert.equal(init.headers.Accept, 'application/json');
    assert.ok(init.signal instanceof AbortSignal); return accepted();
  } });
  assert.deepEqual(result, { kind: 'success' }); assert.equal(calls, 1);
});

test('unknown and cross-origin endpoints never call fetch', async () => {
  let calls = 0;
  for (const path of ['https://unowned.example/api/accounts/waitlist/', '//unowned.example/', '/api/accounts/login/', '/api/accounts/contact/?redirect=bad']) {
    assert.deepEqual(await postPublicForm(path, {}, { fetchImpl: () => { calls++; } }), { kind: 'unavailable' });
  }
  assert.equal(calls, 0);
});

test('HTML/static success, wrong status, malformed/missing/oversized JSON never show joined', async () => {
  const responses = [
    new Response('<html>Static host fallback</html>', { status: 200, headers: { 'content-type': 'text/html' } }),
    new Response('<html>Not JSON</html>', { status: 202, headers: { 'content-type': 'text/html' } }),
    Response.json({ detail: 'wrong contract' }, { status: 201 }),
    new Response('{broken', { status: 202, headers: { 'content-type': 'application/json' } }),
    Response.json({}, { status: 202 }),
    Response.json({ detail: 'x'.repeat(9000) }, { status: 202 }),
  ];
  for (const response of responses) assert.deepEqual(await postPublicForm(endpoint, {}, { fetchImpl: async () => response }), { kind: 'unavailable' });
});

test('validation, throttling and unavailable mail map to controlled retry states', async () => {
  for (const [status, kind] of [[400, 'invalid'], [429, 'throttled'], [503, 'unavailable']]) {
    const response = new Response('Private provider details are never displayed', { status });
    assert.deepEqual(await postPublicForm('/api/accounts/contact/', {}, { fetchImpl: async () => response }), { kind });
  }
});

test('only the waitlist delayed-confirmation contract says the address was already saved', async () => {
  const delayed = () => Response.json({ code: 'waitlist_confirmation_delayed', detail: 'Private server wording is not displayed.' }, { status: 503 });
  assert.deepEqual(await postPublicForm(endpoint, {}, { fetchImpl: async () => delayed() }), { kind: 'email_pending' });
  assert.deepEqual(await postPublicForm('/api/accounts/contact/', {}, { fetchImpl: async () => delayed() }), { kind: 'unavailable' });
  assert.deepEqual(await postPublicForm(endpoint, {}, { fetchImpl: async () => Response.json({ code: 'different' }, { status: 503 }) }), { kind: 'unavailable' });
});

test('a saved waitlist entry can explicitly retry confirmation without losing its email', async () => {
  const ui = fixture('waitlist'); ui.email.value = 'parent@example.com'; let calls = 0;
  initWaitlistForm(ui.form, async () => { calls++; return { kind: calls === 1 ? 'email_pending' : 'success' }; });
  await ui.form.emit('submit');
  assert.equal(ui.email.value, 'parent@example.com'); assert.equal(ui.submit.disabled, false);
  assert.equal(ui['button-label'].textContent, 'Retry confirmation');
  assert.match(ui.status.textContent, /You’re on the list/);
  await ui.form.emit('submit'); assert.equal(calls, 2); assert.equal(ui.form.dataset.state, 'success');
  assert.match(ui.status.textContent, /Check your inbox/);
});

test('offline avoids fetch; network and bounded timeout are recoverable without automatic retry', async () => {
  let calls = 0;
  assert.deepEqual(await postPublicForm(endpoint, {}, { online: () => false, fetchImpl: () => { calls++; } }), { kind: 'offline' });
  assert.equal(calls, 0);
  assert.deepEqual(await postPublicForm(endpoint, {}, { fetchImpl: async () => { calls++; throw new Error('untrusted error'); } }), { kind: 'network' });
  assert.equal(calls, 1);
  const timed = await postPublicForm(endpoint, {}, { timeoutMs: 2, fetchImpl: (_url, { signal }) => {
    calls++; return new Promise((_resolve, reject) => signal.addEventListener('abort', () => reject(new Error('aborted')), { once: true }));
  } });
  assert.deepEqual(timed, { kind: 'timeout' }); assert.equal(calls, 2);
});

test('waitlist prevents overlapping and repeated successful submissions, with accessible busy state', async () => {
  const ui = fixture('waitlist'); ui.email.value = ' parent@example.com ';
  let resolve; let calls = 0;
  const request = async (path, body) => { calls++; assert.equal(path, endpoint); assert.equal(body.email, 'parent@example.com'); return new Promise((done) => { resolve = done; }); };
  initWaitlistForm(ui.form, request); initWaitlistForm(ui.form, request);
  const first = ui.form.emit('submit');
  assert.equal(ui.form.attributes['aria-busy'], 'true'); assert.equal(ui.submit.disabled, true);
  await ui.form.emit('submit'); assert.equal(calls, 1);
  resolve({ kind: 'success' }); await first;
  assert.equal(ui.form.dataset.state, 'success'); assert.equal(ui.form.attributes['aria-busy'], 'false');
  assert.equal(ui['button-label'].textContent, 'Joined'); assert.equal(ui.submit.disabled, true);
  await ui.form.emit('submit'); assert.equal(calls, 1);
});

test('waitlist invalid values do not submit; failed entry remains available for explicit retry', async () => {
  const ui = fixture('waitlist'); let calls = 0;
  initWaitlistForm(ui.form, async () => { calls++; return { kind: calls === 1 ? 'unavailable' : 'success' }; });
  await ui.form.emit('submit'); assert.equal(calls, 0); assert.equal(ui.email.focused, true);
  assert.equal(ui.email.attributes['aria-invalid'], 'true');
  ui.email.value = 'parent@example.com'; await ui.email.emit('input'); await ui.form.emit('submit');
  assert.equal(ui.form.dataset.state, 'error'); assert.equal(ui.email.value, 'parent@example.com'); assert.equal(ui.submit.disabled, false);
  await ui.form.emit('submit'); assert.equal(calls, 2); assert.equal(ui.form.dataset.state, 'success');
});

test('contact validates actual limits before send, keeps invalid field focus and does not send child/account secrets', async () => {
  const ui = fixture('contact'); let calls = 0;
  initContactForm(ui.form, async () => { calls++; return { kind: 'success' }; });
  assert.equal(ui.fields.disabled, false);
  await ui.form.emit('submit'); assert.equal(calls, 0); assert.equal(ui.title.focused, true);
  ui.title.value = 'Hello'; ui.email.value = 'parent@example.com'; ui.message.value = 'short';
  await ui.form.emit('submit'); assert.equal(calls, 0); assert.equal(ui.message.focused, true);
  ui.message.value = 'A sufficiently long question'; ui.title.value = 'Bad\nsubject';
  await ui.form.emit('submit'); assert.equal(calls, 0);
});

test('contact sends exact trimmed contract once, preserves message after failure, and retries only explicitly', async () => {
  const ui = fixture('contact'); ui.title.value = ' My question '; ui.email.value = ' parent@example.com '; ui.message.value = ' Please help with the app. ';
  let calls = 0; let resolve;
  initContactForm(ui.form, async (path, body) => {
    calls++; assert.equal(path, '/api/accounts/contact/');
    assert.match(body.request_id, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i);
    const { request_id, ...message } = body;
    assert.deepEqual(message, { title: 'My question', email: 'parent@example.com', message: 'Please help with the app.', website: '' });
    if (calls === 1) ui.firstId = request_id; else assert.equal(request_id, ui.firstId);
    return calls === 1 ? new Promise((done) => { resolve = done; }) : { kind: 'success' };
  });
  const first = ui.form.emit('submit'); await ui.form.emit('submit'); assert.equal(calls, 1);
  resolve({ kind: 'unavailable' }); await first;
  assert.equal(ui.form.dataset.state, 'error'); assert.equal(ui.fields.disabled, false);
  assert.equal(ui.message.value, ' Please help with the app. ');
  await ui.form.emit('submit'); assert.equal(calls, 2); assert.equal(ui.form.dataset.state, 'success');
  assert.equal(ui.submit.textContent, 'Message sent'); await ui.form.emit('submit'); assert.equal(calls, 2);
});

test('Vercel proxies only the four exact public paths to the verified HTTPS backend, uncached', async () => {
  const config = JSON.parse(await readFile(new URL('../vercel.json', import.meta.url)));
  const paths = ['/api/accounts/waitlist/', '/api/accounts/contact/', '/api/accounts/account-deletion/request/', '/api/accounts/account-deletion/confirm/'];
  assert.deepEqual(config.rewrites.map((rule) => rule.source), paths);
  for (const { source, destination } of config.rewrites) {
    const url = new URL(destination); assert.equal(url.origin, 'https://kingdom-kids-checkout-staging.onrender.com');
    assert.equal(url.pathname, source); assert.equal(url.search, ''); assert.equal(url.hash, '');
  }
  const apiHeaders = config.headers.find((entry) => entry.source === '/api/:path*');
  assert.ok(apiHeaders);
  for (const header of apiHeaders.headers) assert.equal(header.value, 'no-store');
});

test('editing a failed contact message creates a new in-memory request ID; no storage is used', async () => {
  const ui = fixture('contact'); ui.title.value = 'A question'; ui.email.value = 'parent@example.com'; ui.message.value = 'Please help with this question.';
  const ids = [];
  initContactForm(ui.form, async (_path, body) => { ids.push(body.request_id); return { kind: 'timeout' }; });
  await ui.form.emit('submit'); await ui.form.emit('submit');
  assert.equal(ids[0], ids[1]);
  ui.message.value = 'A different question with enough detail.'; await ui.message.emit('input'); await ui.form.emit('submit');
  assert.notEqual(ids[1], ids[2]); assert.equal(ui.form.dataset.state, 'error');
});
