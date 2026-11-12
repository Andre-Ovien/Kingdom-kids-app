import { createPageNotifications } from './page-notifications.mjs';
export { createToastClock, TOAST_DURATION_MS } from './page-notifications.mjs';

const installations = new WeakMap();
const noticeSelector = '[data-waitlist-status], [data-contact-status], [data-deletion-request-status], [data-deletion-confirm-status]';

export function initFormToasts(doc = globalThis.document) {
  if (!doc?.body || !doc.defaultView?.MutationObserver) return;
  if (installations.has(doc)) return installations.get(doc);
  const win = doc.defaultView, notices = createPageNotifications(doc);
  const show = (region) => {
    const tone = region.dataset.state || region.closest('form')?.dataset.state;
    if (['success', 'error'].includes(tone)) notices.show(region.textContent, { tone, source: region });
  };
  const observer = new win.MutationObserver((changes) => {
    const changed = new Set();
    for (const change of changes) {
      const element = change.target.nodeType === 1 ? change.target : change.target.parentElement;
      const region = element?.closest(noticeSelector);
      if (region) changed.add(region);
    }
    for (const region of changed) show(region);
  });
  doc.querySelectorAll(noticeSelector).forEach((region) => {
    region.classList.add('form-notice-source');
    observer.observe(region, { childList: true, characterData: true, subtree: true });
  });
  const dispose = () => {
    notices.dispose(); observer.disconnect();
    win.removeEventListener('pagehide', pageHidden); installations.delete(doc);
  };
  const pageHidden = (event) => event.persisted ? notices.clear() : dispose();
  win.addEventListener('pagehide', pageHidden);
  installations.set(doc, dispose);
  return dispose;
}
