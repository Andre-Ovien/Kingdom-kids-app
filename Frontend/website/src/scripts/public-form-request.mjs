const publicEndpoints = new Set([
  '/api/accounts/waitlist/',
  '/api/accounts/contact/',
]);

/** Submit once, without credentials, redirects, retries or raw server error messages. */
export async function postPublicForm(endpoint, payload, {
  fetchImpl = globalThis.fetch,
  timeoutMs = 60000,
  online = () => globalThis.navigator?.onLine !== false,
} = {}) {
  if (!publicEndpoints.has(endpoint)) return { kind: 'unavailable' };
  if (!online()) return { kind: 'offline' };
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  let reader;
  try {
    const response = await fetchImpl(endpoint, {
      method: 'POST',
      headers: { Accept: 'application/json', 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
      cache: 'no-store',
      credentials: 'omit',
      redirect: 'error',
      referrerPolicy: 'same-origin',
      signal: controller.signal,
    });
    reader = response.body?.getReader();
    if (response.status === 400) return { kind: 'invalid' };
    if (response.status === 429) return { kind: 'throttled' };
    // Both public endpoints intentionally acknowledge duplicate-safe requests with 202.
    if (response.status !== 202 ||
        !/^application\/json(?:\s*;|$)/i.test(response.headers.get('content-type') ?? '')) {
      return { kind: 'unavailable' };
    }
    if (!reader) return { kind: 'unavailable' };
    const chunks = [];
    let size = 0;
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > 8192) return { kind: 'unavailable' };
      chunks.push(value);
    }
    const bytes = new Uint8Array(size);
    let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
    let body;
    try { body = JSON.parse(new TextDecoder().decode(bytes)); }
    catch { return { kind: 'unavailable' }; }
    return body && typeof body.detail === 'string' && body.detail.trim()
      ? { kind: 'success' }
      : { kind: 'unavailable' };
  } catch {
    return { kind: controller.signal.aborted ? 'timeout' : online() ? 'network' : 'offline' };
  } finally {
    clearTimeout(timeout);
    // Cancel unconsumed/oversized streams; all UI messages remain locally controlled.
    try { await reader?.cancel(); } catch { /* No provider response is logged. */ }
  }
}
