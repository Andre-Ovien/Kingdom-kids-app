export const TOAST_DURATION_MS = 5000;

// Keep a notice available while someone is reading or interacting with it.
export function createToastClock(dismiss, {
  duration = TOAST_DURATION_MS,
  now = () => performance.now(),
  setTimer = setTimeout,
  clearTimer = clearTimeout,
} = {}) {
  let remaining = duration;
  let started = now();
  let cancelled = false;
  const pauses = new Set();
  const expire = () => { if (!cancelled) { cancelled = true; dismiss(); } };
  let timer = setTimer(expire, remaining);
  return {
    pause(reason) {
      if (cancelled || pauses.has(reason)) return;
      if (!pauses.size) { clearTimer(timer); remaining = Math.max(0, remaining - (now() - started)); }
      pauses.add(reason);
    },
    resume(reason) {
      if (cancelled || !pauses.delete(reason) || pauses.size) return;
      started = now();
      timer = setTimer(expire, remaining);
    },
    cancel() { cancelled = true; clearTimer(timer); pauses.clear(); },
    get paused() { return pauses.size > 0; },
  };
}

const installations = new WeakMap();
const noticeSelector = '[data-waitlist-status], [data-contact-status], [data-deletion-request-status], [data-deletion-confirm-status]';

export function initFormToasts(doc = globalThis.document) {
  if (!doc?.body || !doc.defaultView?.MutationObserver) return;
  if (installations.has(doc)) return installations.get(doc);
  const win = doc.defaultView;
  const toast = doc.createElement('div');
  toast.className = 'form-toast';
  toast.hidden = true;
  // The original, visually hidden field descriptions retain their live regions.
  // This visual notice does not announce the same message a second time.
  toast.setAttribute('aria-live', 'off');
  const icon = doc.createElement('span');
  icon.className = 'form-toast__icon';
  icon.setAttribute('aria-hidden', 'true');
  const message = doc.createElement('p');
  message.className = 'form-toast__message';
  const close = doc.createElement('button');
  close.className = 'form-toast__close';
  close.type = 'button';
  close.setAttribute('aria-label', 'Dismiss notification');
  close.textContent = '×';
  const progress = doc.createElement('div');
  progress.className = 'form-toast__progress';
  progress.setAttribute('aria-hidden', 'true');
  toast.append(icon, message, close, progress);
  doc.body.append(toast);
  let clock;
  let source;
  const hide = () => {
    clock?.cancel();
    toast.hidden = true;
    if (toast.contains(doc.activeElement)) {
      source?.closest('form')?.querySelector('input:not(:disabled), button:not(:disabled)')?.focus();
    }
  };
  const pause = (reason) => { clock?.pause(reason); progress.style.animationPlayState = 'paused'; };
  const resume = (reason) => {
    clock?.resume(reason);
    progress.style.animationPlayState = clock?.paused ? 'paused' : 'running';
  };
  close.addEventListener('click', hide);
  toast.addEventListener('mouseenter', () => pause('hover'));
  toast.addEventListener('mouseleave', () => resume('hover'));
  toast.addEventListener('focusin', () => pause('focus'));
  toast.addEventListener('focusout', (event) => { if (!toast.contains(event.relatedTarget)) resume('focus'); });
  const visibilityChanged = () => doc.hidden ? pause('hidden') : resume('hidden');
  doc.addEventListener('visibilitychange', visibilityChanged);
  const show = (region) => {
    const state = region.dataset.state || region.closest('form')?.dataset.state;
    const text = region.textContent.trim();
    if (!text || !['success', 'error'].includes(state)) return;
    clock?.cancel();
    source = region;
    toast.dataset.tone = state;
    icon.textContent = state === 'success' ? '✓' : '!';
    message.textContent = text;
    toast.hidden = false;
    progress.style.animation = 'none';
    // A fresh message always receives its own complete five-second countdown.
    void progress.offsetWidth;
    progress.style.animation = `form-toast-countdown ${TOAST_DURATION_MS}ms linear forwards`;
    clock = createToastClock(hide);
    if (toast.matches(':hover')) pause('hover');
    if (toast.contains(doc.activeElement)) pause('focus');
    visibilityChanged();
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
    hide();
    observer.disconnect();
    doc.removeEventListener('visibilitychange', visibilityChanged);
    win.removeEventListener('pagehide', pageHidden);
    toast.remove();
    installations.delete(doc);
  };
  const pageHidden = (event) => event.persisted ? hide() : dispose();
  win.addEventListener('pagehide', pageHidden);
  installations.set(doc, dispose);
  return dispose;
}
