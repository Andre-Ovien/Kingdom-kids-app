import { postPublicForm } from './public-form-request.mjs';

export function initWaitlistForm(form, request = postPublicForm) {
  const email = form.querySelector('[data-waitlist-email]');
  const submit = form.querySelector('[data-waitlist-submit]');
  const label = form.querySelector('[data-waitlist-button-label]');
  const status = form.querySelector('[data-waitlist-status]');
  if (!email || !submit || !label || !status || form.dataset.waitlistReady) return;
  form.dataset.waitlistReady = 'true';
  let pending = false;
  let succeeded = false;
  const setState = (state, message, buttonLabel = 'Join the waitlist', invalid = false) => {
    form.dataset.state = state;
    form.setAttribute('aria-busy', String(state === 'loading'));
    status.textContent = message;
    label.textContent = buttonLabel;
    submit.disabled = state === 'loading' || state === 'success';
    submit.setAttribute('aria-disabled', String(submit.disabled));
    email.disabled = submit.disabled;
    email.setAttribute('aria-invalid', String(invalid));
  };
  email.addEventListener('input', () => {
    if (!pending && !succeeded && form.dataset.state === 'error') setState('idle', '');
  });
  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    if (pending || succeeded) return;
    const address = email.value.trim();
    if (!address || !email.validity.valid) {
      setState('error', address
        ? 'Enter a valid email address, such as name@example.com.'
        : 'Enter an email address to join the waitlist.', 'Join the waitlist', true);
      email.focus();
      return;
    }
    pending = true;
    setState('loading', 'Sending your request…', 'Joining…');
    try {
      const result = await request('/api/accounts/waitlist/', { email: address });
      if (result.kind === 'success') {
        succeeded = true;
        setState('success', 'You’re on the list. Check your inbox for confirmation—we’ll email you when Kingdom Kids is ready.', 'Joined');
      } else if (result.kind === 'email_pending') {
        setState('error', 'You’re on the list, but confirmation couldn’t be sent yet. Try again to request it.', 'Retry confirmation');
      } else {
        const messages = {
          invalid: 'Enter a valid email address, such as name@example.com.',
          throttled: 'Too many attempts just now. Wait a moment, then try again.',
          offline: 'You appear to be offline. Reconnect and try again.',
          timeout: 'The request took too long. Please try again.',
        };
        setState('error', messages[result.kind] ?? 'We couldn’t join the waitlist just now. Please try again.',
          'Join the waitlist', result.kind === 'invalid');
        if (result.kind === 'invalid') email.focus();
      }
    } catch {
      setState('error', 'We couldn’t join the waitlist just now. Please try again.');
    } finally {
      pending = false;
    }
  });
}

export function initWaitlistForms(root = document) {
  root.querySelectorAll('[data-waitlist-form]').forEach((form) => initWaitlistForm(form));
}
