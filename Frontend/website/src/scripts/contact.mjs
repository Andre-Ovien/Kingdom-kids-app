import { postPublicForm } from './public-form-request.mjs';

export function initContactForm(form, request = postPublicForm) {
  const fields = form.querySelector('[data-contact-fields]');
  const title = form.querySelector('[data-contact-title]');
  const email = form.querySelector('[data-contact-email]');
  const message = form.querySelector('[data-contact-message]');
  const website = form.querySelector('[data-contact-website]');
  const submit = form.querySelector('[data-contact-submit]');
  const status = form.querySelector('[data-contact-status]');
  if (!fields || !title || !email || !message || !website || !submit || !status || form.dataset.contactReady) return;
  form.dataset.contactReady = 'true';
  fields.disabled = false;
  let pending = false;
  let succeeded = false;
  // Retain an in-memory idempotency key for explicit retries of the same message.
  let submissionKey = '';
  let requestId;
  const setState = (state, text) => {
    form.dataset.state = state;
    form.setAttribute('aria-busy', String(state === 'loading'));
    status.dataset.state = state;
    status.textContent = text;
    fields.disabled = state === 'loading' || state === 'success';
    submit.disabled = fields.disabled;
    submit.textContent = state === 'loading' ? 'Sending…' : state === 'success' ? 'Message sent' : 'Send message';
  };
  for (const input of [title, email, message]) {
    input.addEventListener('input', () => {
      input.setAttribute('aria-invalid', 'false');
      if (!pending && !succeeded && form.dataset.state === 'error') setState('idle', '');
    });
  }
  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    if (pending || succeeded) return;
    for (const input of [title, email, message]) input.setAttribute('aria-invalid', 'false');
    const payload = { title: title.value.trim(), email: email.value.trim(), message: message.value.trim(), website: website.value };
    const invalid = payload.title.length < 2 || payload.title.length > 120 || /[\x00-\x1f\x7f]/.test(payload.title)
      ? [title, 'Enter a subject between 2 and 120 characters on one line.']
      : !payload.email || payload.email.length > 254 || !email.validity.valid
        ? [email, 'Enter a valid email address, such as name@example.com.']
        : payload.message.length < 10 || payload.message.length > 5000
          ? [message, 'Enter a message between 10 and 5,000 characters.'] : null;
    if (invalid) {
      invalid[0].setAttribute('aria-invalid', 'true');
      setState('error', invalid[1]);
      invalid[0].focus();
      return;
    }
    const key = JSON.stringify(payload);
    if (key !== submissionKey) {
      submissionKey = key;
      requestId = globalThis.crypto?.randomUUID?.();
    }
    if (requestId) payload.request_id = requestId;
    pending = true;
    setState('loading', 'Sending your message…');
    try {
      const result = await request('/api/accounts/contact/', payload);
      if (result.kind === 'success') {
        succeeded = true;
        setState('success', 'Thanks. Your message has been received.');
      } else {
        const messages = {
          invalid: 'Check your subject, email address, and message, then try again.',
          throttled: 'Too many messages just now. Please wait before trying again.',
          offline: 'You appear to be offline. Reconnect and try again.',
          timeout: 'The request took too long. Your message is still here so you can try again.',
        };
        setState('error', messages[result.kind] ?? 'We couldn’t send your message just now. Your message is still here; please try again later.');
      }
    } catch {
      setState('error', 'We couldn’t send your message just now. Your message is still here; please try again later.');
    } finally {
      pending = false;
    }
  });
}

export function initContactForms(root = document) {
  root.querySelectorAll('[data-contact-form]').forEach((form) => initContactForm(form));
}
