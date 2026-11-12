import { createPageNotifications } from './page-notifications.mjs';

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function appReturnUrl(context) {
  if (!context || Object.keys(context).length !== 2 || !uuid.test(context.attempt || '') || !uuid.test(context.state || '')) return null;
  const query = new URLSearchParams({ attempt: context.attempt.toLowerCase(), state: context.state.toLowerCase() });
  return 'kingdomkids://payments/return/?' + query;
}

export function initPaymentReturn(doc = globalThis.document, win = globalThis.window, options = {}) {
  const context = options.context ?? win?.__kkPaymentReturn;
  if (win) delete win.__kkPaymentReturn;
  const open = doc?.getElementById('open-app'), status = doc?.getElementById('return-status');
  if (!open || !status || !win) return;
  const notices = createPageNotifications(doc, options);
  const setTimer = options.setTimer ?? setTimeout, clearTimer = options.clearTimer ?? clearTimeout;
  const target = appReturnUrl(context);
  let timer, disposed = false;
  if (target) { open.href = target; open.hidden = false; }
  const reset = () => { clearTimer(timer); open.removeAttribute('aria-busy'); };
  const clicked = () => {
    if (disposed || !target) return;
    reset(); open.setAttribute('aria-busy', 'true');
    status.textContent = 'Opening Kingdom Kids. Your payment will be checked securely in the app.';
    notices.show(status.textContent, { source: status });
    timer = setTimer(() => {
      reset(); status.textContent = 'If the app did not open, open Kingdom Kids from your home screen.';
    }, 1500);
  };
  const pageHidden = (event) => {
    reset(); notices.clear();
    if (event.persisted) return;
    disposed = true; notices.dispose(); open.removeAttribute('href'); open.hidden = true;
    open.removeEventListener('click', clicked); win.removeEventListener('pagehide', pageHidden);
  };
  open.addEventListener('click', clicked); win.addEventListener('pagehide', pageHidden);
  return { dispose: () => pageHidden({ persisted: false }) };
}
