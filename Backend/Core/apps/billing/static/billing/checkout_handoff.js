// A one-time checkout capability, never an application access/refresh token.
const codePattern = /^[A-Za-z0-9_-]{43}$/;
const tokenPattern = /^kkco\.[A-Za-z0-9_:.-]{40,2000}$/;
const endpoint = '/api/billing/checkout-handoffs/';

export function takeHandoff(location, history) {
  const fragment = location.hash;
  if (!fragment) return null;
  // Clear even malformed fragments before any SDK, provider or API operation.
  history.replaceState(null, '', location.pathname + location.search);
  return parseHandoff(fragment);
}

export function parseHandoff(fragment) {
  const match = /^#handoff=([A-Za-z0-9_-]{43})$/.exec(fragment);
  if (!match) throw new Error('Open checkout again from the app.');
  return match[1];
}

export async function redeemHandoff(code, { fetcher = fetch, runtime, expectedPlan = null, expectedPurpose = 'purchase' }) {
  if (!codePattern.test(code) || !['purchase', 'manage'].includes(expectedPurpose))
    throw new Error('Open checkout again from the app.');
  const abort = new AbortController(), timer = setTimeout(() => abort.abort(), 15000);
  try {
    const response = await fetcher(endpoint + 'redeem/', { method: 'POST',
      headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
      body: JSON.stringify({ code }), cache: 'no-store', credentials: 'omit',
      redirect: 'error', referrerPolicy: 'no-referrer', signal: abort.signal });
    if (!response.ok || !response.headers.get('content-type')?.startsWith('application/json'))
      throw new Error('Open checkout again from the app.');
    const reader = response.body.getReader(); const chunks = []; let length = 0;
    try {
      while (true) {
        const part = await reader.read(); if (part.done) break;
        length += part.value.length;
        if (length > 8192) { abort.abort(); throw new Error('Open checkout again from the app.'); }
        chunks.push(part.value);
      }
    } finally { reader.releaseLock(); }
    const bytes = new Uint8Array(length); let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
    const result = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
    if (result?.schema_version !== 1 || !['sandbox', 'production'].includes(runtime.environment)
        || result.environment !== runtime.environment || result.purpose !== expectedPurpose
        || !result.parent || typeof result.parent.id !== 'string' || !/^[1-9][0-9]{0,18}$/.test(result.parent.id)
        || typeof result.parent.email !== 'string' || !result.parent.email || result.parent.email.length > 254
        || result.parent.email_verified !== true
        || !tokenPattern.test(result.checkout_token || '')
        || !Number.isFinite(Date.parse(result.expires_at)) || Date.parse(result.expires_at) <= Date.now()
        || Date.parse(result.expires_at) > Date.now() + 601000
        || (expectedPurpose === 'purchase' && result.billing_period !== expectedPlan)
        || (expectedPurpose === 'manage' && result.billing_period !== null))
      throw new Error('Open checkout again from the app.');
    return result;
  } finally { clearTimeout(timer); code = ''; }
}

export function revokeHandoff(token, fetcher = fetch) {
  if (typeof token !== 'string' || !token.startsWith('kkco.')) return;
  // Navigation may destroy the page. The server's absolute expiry is the final
  // bound even if this best-effort revocation cannot reach it.
  try {
    Promise.resolve(fetcher(endpoint + 'revoke/', { method: 'POST',
      headers: { 'Content-Type': 'application/json', Accept: 'application/json', Authorization: `Bearer ${token}` },
      body: '{}', cache: 'no-store', credentials: 'omit', redirect: 'error', referrerPolicy: 'no-referrer',
      keepalive: true })).catch(() => {});
  } catch (_) { /* Never log a checkout capability. */ }
}
