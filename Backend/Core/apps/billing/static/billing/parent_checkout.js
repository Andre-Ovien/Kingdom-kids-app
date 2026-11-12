import { createPageNotifications } from './page_notifications.js';
// Parent checkout. Credentials, JWTs and single-use card sources stay in memory.
const plans = {
  monthly: { amount: 999, cadence: 'DAYS_30', rule: 'elapsed_days_30', label: 'Monthly plan', unit: 'USD every 30 days' },
  yearly: { amount: 9990, cadence: 'ANNUAL', rule: 'calendar_year_1', label: 'Yearly plan', unit: 'USD / year' },
};
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const base = '/api/billing/square/checkout-intents/';
class Refused extends Error { constructor() { super('Action not confirmed.'); } }
const beforePaymentMessages = {
  card_number: 'Check the card number in the secure Square form, then choose Pay again.',
  expiration_date: 'Check the card expiration date in the secure Square form, then choose Pay again.',
  security_code: 'Check the card security code in the secure Square form, then choose Pay again.',
  postal_code: 'Check the billing postal code and the secure Square form, then choose Pay again.',
  card_details: 'Check the highlighted card details in the secure Square form, then choose Pay again.',
  billing_contact: 'Complete your billing name, address and country, then choose Pay again.',
  consent_required: 'Accept the billing agreement and confirm your password before choosing Pay again.',
  page_not_visible: 'Return to this checkout tab, review the agreement and choose Pay again.',
  review_before_payment: 'Keep this checkout tab visible and accept the agreement before choosing Pay again.',
  verification_canceled: 'Card verification was canceled. Review your details and choose Pay again.',
  verification_incomplete: 'Complete card verification in the secure Square form, then choose Pay again.',
  verification_configuration: 'Card verification could not start. Reload the secure card form to try again.',
  tokenization_unavailable: 'Card verification could not finish. Reload the secure card form to try again.',
};
class BeforePayment extends Error {
  constructor(code) {
    const safe = Object.hasOwn(beforePaymentMessages, code) ? code : 'tokenization_unavailable';
    super('No payment was sent. ' + beforePaymentMessages[safe]); this.code = safe;
  }
}
export function tokenizationFailure(value) {
  // SDK errors are untrusted. Read only bounded field/type selectors and never
  // retain/render message, detail, token, PAN or the original error object.
  const errors = Array.isArray(value?.errors) ? value.errors.slice(0, 16) :
    value?.errors && typeof value.errors === 'object' ? [value.errors] : [];
  const fields = new Set();
  for (const error of errors) {
    if (typeof error?.field !== 'string' || error.field.length > 64) continue;
    const field = error.field.toLowerCase().replace(/[ _-]/g, '');
    const names = { cardnumber: 'card_number', expirationdate: 'expiration_date', expiry: 'expiration_date',
      cvv: 'security_code', securitycode: 'security_code', postalcode: 'postal_code', zipcode: 'postal_code' };
    const code = Object.hasOwn(names, field) ? names[field] : '';
    if (code) fields.add(code);
  }
  if (fields.size === 1) return new BeforePayment([...fields][0]);
  if (fields.size > 1 || value?.status === 'Invalid' || value?.status === 'INVALID') return new BeforePayment('card_details');
  if (['Abort', 'Cancel', 'ABORT', 'CANCEL'].includes(value?.status))
    return new BeforePayment('verification_canceled');
  if (value?.name === 'VerifyBuyerError') return new BeforePayment('verification_incomplete');
  if (['InvalidOptionError', 'InvalidPaymentRequestError', 'InvalidConfigurationValueError'].includes(value?.name))
    return new BeforePayment('verification_configuration');
  return new BeforePayment('tokenization_unavailable');
}
export function validQuote(q, period, environment = 'sandbox', billingMode = 'recurring') {
  const p = plans[period];
  return Boolean(p && q && ['sandbox', 'production'].includes(environment) && q.environment === environment && q.country === 'US' && q.purchasable === true &&
    q.billing_period === period && q.currency === 'USD' && q.amount_minor === p.amount &&
    q.cadence === p.cadence && q.coverage_rule === p.rule &&
    (billingMode === 'one_period' ? environment === 'production' && q.billing_mode === 'one_period' &&
      q.automatic_renewal === false && q.card_storage === 'none' && q.first_renewal_rule === null :
      billingMode === 'recurring' && q.billing_mode !== 'one_period' && q.first_renewal_rule === p.rule) &&
    q.coverage_start === 'canonical_successful_payment_capture' && q.first_renewal_at === null &&
    q.billing_controller === 'app_owned_terms' && q.can_prorate === false && q.free_period === false &&
    typeof q.billing_timezone === 'string' && q.billing_timezone.length <= 64 &&
    typeof q.disclosure_version === 'string' && q.disclosure_version.length > 0 && q.disclosure_version.length <= 96 &&
    /^[a-f0-9]{64}$/.test(q.disclosure_sha256 || '') && typeof q.disclosure === 'string' &&
    q.disclosure.length > 0 && q.disclosure.length <= 16000 && !('renewal_anchor_day' in q) &&
    q.web_tokenization?.intent === (billingMode === 'one_period' ? 'CHARGE' : 'CHARGE_AND_STORE') &&
    q.web_tokenization.amount === (p.amount / 100).toFixed(2) && q.web_tokenization.currencyCode === 'USD' &&
    q.web_tokenization.customerInitiated === true && q.web_tokenization.sellerKeyedIn === false);
}
export function validAccess(data, parent, environment = 'sandbox') {
  if (!data || data.schema_version !== 1 || data.parent_id !== parent || !['sandbox', 'production'].includes(environment) || data.environment !== environment ||
      !['paid', 'unpaid', 'unknown'].includes(data.access_state) || !Number.isFinite(Date.parse(data.evaluated_at)) ||
      !['available', 'unavailable', 'unknown'].includes(data.checkout?.state)) return false;
  return data.access_state !== 'paid' || (Number.isFinite(Date.parse(data.access_until)) &&
    Date.parse(data.access_until) > Date.parse(data.evaluated_at));
}
export class PurchaseFlow {
  constructor({ api, tokenize, parent, canCharge = () => true, environment = 'sandbox', purpose = 'purchase', billingMode = 'recurring' }) {
    this.api = api; this.tokenize = tokenize; this.parent = parent;
    if (!['sandbox', 'production'].includes(environment) || !['purchase', 'manage'].includes(purpose) ||
        !['recurring', 'one_period'].includes(billingMode) || (billingMode === 'one_period' && environment !== 'production')) throw new Refused();
    this.billingMode = billingMode;
    this.environment = environment; this.purpose = purpose;
    this.period = 'monthly'; this.quote = null; this.intent = ''; this.attempted = false;
    this.reserveAttempted = false; this.sourceAllowed = false; this.access = null;
    this.canCharge = canCharge; this.busy = false; this.readRevision = 0;
  }
  setQuote(quote, period) {
    if (this.purpose !== 'purchase' || !validQuote(quote, period, this.environment, this.billingMode) || (this.intent && this.period !== period)) throw new Refused();
    this.period = period; this.quote = quote;
  }
  async readAccess({ timeoutMs } = {}) {
    const revision = ++this.readRevision;
    const result = await this.api('/api/billing/content-access/', 'GET', undefined, { timeoutMs });
    if (revision !== this.readRevision || !validAccess(result, this.parent, this.environment)) throw new Refused();
    this.access = result;
    const recovery = this.purpose === 'manage' ? result.management_recovery || result.purchase_recovery : result.purchase_recovery;
    this.recovery = recovery;
    if (recovery?.intent_id) {
      if (!uuid.test(recovery.intent_id) || !plans[recovery.billing_period] ||
          (this.intent && this.intent !== recovery.intent_id)) throw new Refused();
      this.intent = recovery.intent_id; this.period = recovery.billing_period;
      // A local uncertain POST remains sticky even if an early read has not yet
      // observed its server term. Only explicit guarded restart can unlock it.
      this.sourceAllowed = recovery.source_allowed === true && !this.attempted;
      this.attempted = this.attempted || recovery.source_allowed !== true;
    }
    return result;
  }
  consent(password) {
    if (this.purpose !== 'purchase' || !password || password.length > 1024 || !validQuote(this.quote, this.period, this.environment, this.billingMode)) throw new Refused();
    return { password, accepted: true, billing_period: this.period,
      disclosure_version: this.quote.disclosure_version, disclosure_sha256: this.quote.disclosure_sha256 };
  }
  acceptIntent(result) {
    if (!uuid.test(result?.id || '')) throw new Refused();
    this.intent = result.id; // Preserve the owned reference even if later validation fails.
    if (!validQuote(result.terms, this.period, this.environment, this.billingMode) || result.terms.disclosure_sha256 !== this.quote.disclosure_sha256) throw new Refused();
    if (result.current_term) { this.attempted = true; this.sourceAllowed = false; throw new Refused(); }
    this.sourceAllowed = true;
  }
  async purchase(password, contact) {
    if (this.busy) throw new Refused();
    this.busy = true;
    let token = null;
    try {
      if (this.purpose !== 'purchase' || this.attempted || !this.access || this.access.access_state === 'paid' ||
          (this.access.access_state !== 'unpaid' && !this.sourceAllowed)) throw new Refused();
      const consent = this.consent(password);
      if (!this.intent) {
        if (this.reserveAttempted) throw new Refused();
        this.reserveAttempted = true;
        this.acceptIntent(await this.api(base, 'POST', consent));
      } else {
        this.acceptIntent(await this.api(base + this.intent + '/', 'GET'));
      }
      if (!this.canCharge()) throw new BeforePayment('review_before_payment');
      token = await this.tokenize({ ...this.quote.web_tokenization, billingContact: contact });
      if (typeof token !== 'string' || !token.startsWith('cnon:') || token.length > 16384) throw new BeforePayment('tokenization_unavailable');
      if (!this.canCharge()) throw new BeforePayment('review_before_payment');
      this.attempted = true; this.sourceAllowed = false; // Before POST; never automatically retry.
      await this.api(base + this.intent + '/confirm/', 'POST', { password, charge_source_id: token });
      return await this.readAccess();
    } finally { token = null; password = ''; this.busy = false; }
  }
  async recover(password) {
    if (!this.intent || !password || password.length > 1024) throw new Refused();
    this.attempted = true; this.sourceAllowed = false;
    await this.api(base + this.intent + '/confirm/', 'POST', { password });
    return await this.readAccess();
  }
  async restart(password) {
    if (this.purpose !== 'purchase' || !this.intent || this.access?.purchase_recovery?.restart_allowed !== true ||
        this.access.purchase_recovery.intent_id !== this.intent ||
        this.access.access_state !== 'unpaid') throw new Refused();
    const old = this.intent;
    const result = await this.api(base + old + '/restart/', 'POST', this.consent(password));
    this.acceptIntent(result); this.attempted = false; this.reserveAttempted = true;
    // Restart only reserves. Another explicit Pay click is required to tokenize/charge.
    return result;
  }
  async stopRenewals(password) {
    if (!this.intent || !password || password.length > 1024) throw new Refused();
    await this.api(base + this.intent + '/cancel/', 'POST', { password });
    return await this.readAccess();
  }
}

function attachPage() {
  const $ = (id) => document.getElementById(id);
  const runtime = JSON.parse($('checkout-runtime').textContent);
  const manageOnly = runtime.purpose === 'manage';
  const billingMode = runtime.billing_mode || 'recurring';
  const requestedPeriod = Object.hasOwn(plans, runtime.selected_plan) ? runtime.selected_plan : null;
  let access = '', signedInEmail = '', flow = null, card = null, busy = false, generation = 0;
  let selectedPeriod = requestedPeriod || 'monthly', planChosen = manageOnly || Boolean(requestedPeriod);
  let cardMount = null, mountSerial = 0, handoffModule = null;
  const notifications = createPageNotifications(document);
  let announcedPaid = false, pollTimer, pollSerial = 0, polling = false;
  let handoffPending = Boolean(location.hash && location.hash !== '#main');
  const active = (value) => { if (generation !== value || !access) throw new Refused(); };
  const message = (value, code = '') => {
    $('message').textContent = value; $('message').setAttribute('data-checkout-code', code);
    if (value) notifications.show(value, { source: $('message'), tone:
      code === 'payment_confirmed' ? 'success' : ['payment_pending', ''].includes(code) ? 'info' : 'error' });
  };
  function stopPolling() { pollSerial++; clearTimeout(pollTimer); polling = false; }
  function startPolling() {
    if (polling || !access || !flow?.attempted || flow.access?.access_state === 'paid' || document.visibilityState !== 'visible') return;
    const scope = generation, ticket = ++pollSerial, deadline = Date.now() + 90000;
    let reads = 0; polling = true; update();
    const current = () => scope === generation && ticket === pollSerial && Boolean(access) && document.visibilityState === 'visible';
    const expired = () => {
      if (scope === generation && ticket === pollSerial) {
        stopPolling(); update();
        if (!access) message('Sign in again to check your existing payment. Do not start another payment.', 'payment_pending');
      }
    };
    const tick = async () => {
      if (!current()) { expired(); return; }
      try { await refresh({ quiet: true, timeoutMs: Math.max(1, Math.min(15000, deadline - Date.now())) }); }
      catch (_) { /* Unknown stays pending; never submit another source. */ }
      if (!current()) { expired(); return; }
      reads++;
      if (flow.access?.access_state === 'paid' || reads >= 6 || Date.now() >= deadline) {
        stopPolling();
        if (flow.access?.access_state !== 'paid') message('Your payment is still being checked. Keep this purchase and check again; do not start another payment.', 'payment_pending');
        update(); return;
      }
      pollTimer = setTimeout(tick, Math.min(8000, 1000 * 2 ** (reads - 1)));
      pollTimer?.unref?.(); // A browser timer is numeric; isolated Node tests need no background process.
    };
    void tick();
  }
  function sync() {
    document.querySelectorAll('button').forEach((button) => { button.disabled = busy; });
    for (const period of ['monthly', 'yearly']) if ($(period))
      $(period).disabled = busy || Boolean(flow?.intent) || Boolean(flow?.reserveAttempted) || planChosen;
    $('pay').disabled = busy || !card || !flow?.quote || flow.attempted || !$('consent').checked ||
      flow.access?.access_state === 'paid' || (flow.access?.access_state !== 'unpaid' && !flow.sourceAllowed);
    $('restart').disabled = busy || !flow?.intent || !$('consent').checked || !flow?.quote;
  }
  async function perform(operation) {
    if (busy) return;
    stopPolling();
    if (flow) flow.readRevision++; // A prior automatic GET cannot replace this action's newer status.
    const scope = generation;
    busy = true; sync();
    try { await operation(); }
    catch (error) { if (scope !== generation) return;
      if (error instanceof BeforePayment && !flow?.attempted) {
        message(error.message, error.code); return;
      }
      message(!access && flow ? 'Sign in again to continue. Your existing purchase can be recovered.' : flow?.reserveAttempted || flow?.intent ?
      'Your payment is not confirmed. Check or recover the existing purchase before trying another payment.' :
      'This action could not be confirmed. Please try again or use parent account settings in the app.',
      flow?.attempted ? 'payment_uncertain' : 'action_unconfirmed'); }
    finally { if (scope === generation) { busy = false; update(); startPolling(); } }
  }
  async function api(path, method = 'GET', body, { timeoutMs = 40000 } = {}) {
    if (!path.startsWith('/api/') || path.startsWith('//')) throw new Refused();
    const requestGeneration = generation, requestAccess = access;
    const controller = new AbortController(), timer = setTimeout(() => controller.abort(), Math.max(1, Math.min(timeoutMs, 40000)));
    try {
      const headers = { Accept: 'application/json' };
      if (body !== undefined) headers['Content-Type'] = 'application/json';
      if (access && path !== '/api/accounts/login/') headers.Authorization = `Bearer ${access}`;
      const response = await fetch(path, { method, headers, body: body === undefined ? undefined : JSON.stringify(body),
        cache: 'no-store', credentials: 'omit', redirect: 'error', referrerPolicy: 'no-referrer', signal: controller.signal });
      if (!response.headers.get('content-type')?.startsWith('application/json')) throw new Refused();
      const reader = response.body.getReader(); let bytes = 0, chunks = [];
      try {
        while (true) { const part = await reader.read(); if (part.done) break;
          bytes += part.value.length; if (bytes > 65536) { controller.abort(); throw new Refused(); } chunks.push(part.value); }
      } finally { reader.releaseLock(); }
      const buffer = new Uint8Array(bytes); let offset = 0;
      for (const chunk of chunks) { buffer.set(chunk, offset); offset += chunk.length; }
      const value = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(buffer));
      chunks = [];
      if (response.status === 401 && path !== '/api/accounts/login/' &&
          requestGeneration === generation && requestAccess === access) {
        // Expiry owns the same cleanup as logout. A later parent must receive
        // a fresh SDK frame, never the previous parent's hidden card form.
        clear({ silent: true });
        message('Sign in again to check your existing payment. Your app session is unchanged.', 'payment_pending');
        update();
      }
      if (!response.ok) throw new Refused();
      return value;
    } finally { clearTimeout(timer); }
  }
  const takePassword = (id) => { const value = $(id).value; $(id).value = ''; return value; };
  const destroyCard = (value) => { try { Promise.resolve(value?.destroy()).catch(() => {}); } catch (_) { /* Best effort. */ } };
  const removeMount = (mount) => {
    if (!mount) return;
    mount.replaceChildren();
    mount.remove();
    if (cardMount === mount) cardMount = null;
  };
  async function bounded(promise, milliseconds) {
    let timer;
    try { return await Promise.race([promise, new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Refused()), milliseconds);
    })]); } finally { clearTimeout(timer); }
  }
  function contact() {
    const value = (id) => $(id).value.trim();
    const data = { givenName: value('given-name'), familyName: value('family-name'), email: signedInEmail,
      addressLines: [value('address')], city: value('city'), state: value('region'),
      countryCode: value('country').toUpperCase() };
    if (!data.givenName || !data.familyName || !data.email ||
        !data.addressLines[0] || !data.city || !/^[A-Z]{2}$/.test(data.countryCode)) throw new BeforePayment('billing_contact');
    return data;
  }
  async function loadSdk(scope) {
    if (manageOnly) throw new Refused();
    if (!window.Square) await new Promise((resolve, reject) => {
      const script = document.createElement('script');
      const timer = setTimeout(() => { script.remove(); reject(new Refused()); }, 20000);
      script.src = runtime.environment === 'production' ? 'https://web.squarecdn.com/v1/square.js' :
        'https://sandbox.web.squarecdn.com/v1/square.js';
      script.onload = () => { clearTimeout(timer); resolve(); };
      script.onerror = () => { clearTimeout(timer); reject(new Refused()); };
      document.head.append(script);
    });
    active(scope);
    // Each SDK attempt owns a distinct DOM target. A late attach can touch only
    // its detached target, never the next parent's card form.
    const mount = document.createElement('div');
    mount.id = `parent-card-${scope}-${++mountSerial}`;
    $('card-container').replaceChildren(mount); cardMount = mount;
    const payments = window.Square.payments(runtime.application_id, runtime.location_id);
    let next, abandoned = false;
    const creation = payments.card();
    creation.then((value) => { if (abandoned || generation !== scope) {
      destroyCard(value); removeMount(mount);
    } }).catch(() => {});
    try {
      next = await bounded(creation, 20000); active(scope);
      await bounded(next.attach('#' + mount.id), 20000); active(scope); card = next;
    } catch (_) { abandoned = true; destroyCard(next); removeMount(mount); throw new Refused(); }
  }
  async function quote(period) {
    if (manageOnly) throw new Refused();
    const scope = generation;
    const result = await api(base + '?billing_period=' + period); active(scope);
    flow.setQuote(result, period); $('consent').checked = false;
    $('terms').textContent = result.disclosure;
    if (!card && cardStepReady()) await loadSdk(scope);
  }
  function cardStepReady() {
    return Boolean(!manageOnly && access && planChosen && flow?.access?.checkout?.state === 'available' && !flow.attempted &&
      flow.access.access_state !== 'paid' && (flow.access.access_state === 'unpaid' || flow.sourceAllowed));
  }
  function update() {
    const period = flow?.period || selectedPeriod, p = plans[period];
    for (const option of ['monthly', 'yearly']) $(option)?.setAttribute('aria-pressed', String(period === option));
    $('plan-name').textContent = p.label; $('price').textContent = '$' + (p.amount / 100).toFixed(2);
    $('unit').textContent = billingMode === 'one_period' ? period === 'monthly' ? 'USD for 30 days' : 'USD for 12 months' : p.unit;
    $('pay').textContent = 'Pay $' + (p.amount / 100).toFixed(2);
    const paid = Boolean(access) && flow?.access?.access_state === 'paid';
    const recovery = flow?.recovery;
    const ready = cardStepReady();
    const restart = Boolean(!manageOnly && access && recovery?.restart_allowed === true && flow?.access?.access_state === 'unpaid');
    const pending = Boolean(!manageOnly && access && !paid && (flow?.attempted || (flow?.reserveAttempted && !flow?.intent) ||
      (flow?.intent && !flow?.sourceAllowed)));
    if ($('plan-step')) $('plan-step').hidden = planChosen || Boolean(access);
    $('selected-plan').hidden = manageOnly || !planChosen || paid;
    $('page-title').textContent = manageOnly ? 'Manage plan' : paid ? 'Payment confirmed' : !planChosen ? 'Choose your plan' :
      !access ? 'Parent sign in' : pending ? 'Check your payment' : ready ? 'Complete payment' : 'Check access';
    $('login-form').hidden = handoffPending || !planChosen || Boolean(access);
    $('account-identity').hidden = !access;
    $('account-identity').textContent = access ? 'Signed in as ' + signedInEmail : '';
    $('sign-out').hidden = !access;
    $('payment-area').hidden = !ready; $('contact').hidden = !ready; $('card-container').hidden = !ready;
    $('authorization').hidden = !ready && !restart;
    $('password-area').hidden = !ready && !(pending && flow?.intent);
    $('pay').hidden = !ready;
    $('recovery').hidden = !pending;
    $('recovery').setAttribute('aria-busy', String(polling));
    $('recovery-copy').textContent = restart ? 'This payment was unsuccessful. Review the agreement before starting again.' :
      'Your payment is not confirmed yet. Check or recover this same payment.';
    if ($('payment-progress')) $('payment-progress').hidden = !polling || paid;
    $('recover').hidden = !pending || !flow?.intent || restart;
    $('restart').hidden = !restart;
    $('retry-access').hidden = !access || paid || pending || (ready && (Boolean(card) || busy));
    $('retry-access').textContent = ready ? 'Reload secure card form' : 'Check access';
    $('complete').hidden = !paid;
    if (manageOnly && access) $('manage-plan').open = true;
    $('access-date').textContent = paid ? billingMode === 'one_period' ? 'Your paid access is active. Automatic renewal is off.' : 'Your subscription is active.' : '';
    $('manage-plan').hidden = !access || (manageOnly ? !flow?.intent : !recovery?.renewals_enabled && !recovery?.setup_required);
    $('setup').hidden = manageOnly ? !flow?.intent || paid : !paid || recovery?.setup_required !== true;
    $('setup').textContent = manageOnly ? 'Check existing payment' : 'Complete card setup';
    $('stop-renewals').hidden = recovery?.renewals_enabled !== true;
    $('secure-note').hidden = !ready;
    sync();
  }
  async function refresh({ quiet = false, timeoutMs } = {}) {
    const result = await flow.readAccess({ timeoutMs });
    if (result.access_state === 'paid') {
      if (!announcedPaid) { announcedPaid = true; message('Payment confirmed. Your access is active.', 'payment_confirmed'); }
      return;
    }
    if (quiet) return;
    message(
      result.checkout.state !== 'available' ? 'Checkout is unavailable at this address. Parent account settings in the app remain accessible.' :
      result.access_state === 'unpaid' || flow.sourceAllowed ? '' :
      'Access could not yet be confirmed. Your account is still signed in. Check or recover an existing purchase.');
  }
  async function acceptSignIn(result, scope) {
    if (generation !== scope || typeof result.access !== 'string' || !result.access || result.access.length > 16384 ||
        !result.user?.id || result.user.email_verified !== true ||
        typeof result.user.email !== 'string' || !result.user.email || result.user.email.length > 254) throw new Refused();
    access = result.access;
    signedInEmail = result.user.email;
    flow = new PurchaseFlow({ environment: runtime.environment, billingMode, purpose: manageOnly ? 'manage' : 'purchase', api: async (...args) => { active(scope); const value = await api(...args); active(scope); return value; },
      parent: String(result.user.id), canCharge: () => {
        active(scope);
        if (!$('consent').checked) throw new BeforePayment('consent_required');
        if (document.visibilityState !== 'visible') throw new BeforePayment('page_not_visible');
        return true;
      }, tokenize: async (details) => { active(scope);
        if (!$('consent').checked) throw new BeforePayment('consent_required');
        if (!card) throw new BeforePayment('tokenization_unavailable');
        const tokenCard = card, tokenMount = cardMount;
        let result;
        try { result = await bounded(tokenCard.tokenize(details), 120000); }
        catch (error) {
          const issue = tokenizationFailure(error);
          if (!['card_number', 'expiration_date', 'security_code', 'postal_code', 'card_details'].includes(issue.code)) {
            destroyCard(tokenCard); removeMount(tokenMount); if (card === tokenCard) card = null;
          }
          throw issue;
        }
        active(scope);
        if (result?.status !== 'OK') {
          const issue = tokenizationFailure(result);
          if (['tokenization_unavailable', 'verification_configuration'].includes(issue.code)) {
            destroyCard(tokenCard); removeMount(tokenMount); if (card === tokenCard) card = null;
          }
          throw issue;
        }
        return result.token; } });
    flow.period = selectedPeriod;
    update();
    await refresh();
    if (!manageOnly && flow.access.checkout.state === 'available' && flow.access.access_state !== 'paid' &&
        (cardStepReady() || flow.access.purchase_recovery?.restart_allowed)) await quote(flow.period);
  }
  $('login-form').addEventListener('submit', (event) => { event.preventDefault(); perform(async () => {
    if (!planChosen) throw new Refused();
    let password = takePassword('login-password'); const scope = generation;
    try {
      await acceptSignIn(await api('/api/accounts/login/', 'POST', { email: $('email').value.trim(), password }), scope);
    } finally { password = ''; }
  }); });
  for (const period of ['monthly', 'yearly']) if ($(period)) $(period).onclick = () => {
    if (busy || planChosen || flow?.intent || flow?.reserveAttempted) return;
    selectedPeriod = period; update();
  };
  if ($('proceed')) $('proceed').onclick = () => {
    if (busy || planChosen) return;
    planChosen = true; message(''); update();
  };
  $('consent').onchange = sync;
  $('pay').onclick = () => perform(async () => {
    if (!$('consent').checked) throw new BeforePayment('consent_required');
    await flow.purchase(takePassword('purchase-password'), contact()); await refresh();
  });
  $('check').onclick = () => perform(async () => { await refresh(); if (!manageOnly && flow.sourceAllowed && (!flow.quote || !card)) await quote(flow.period); });
  $('retry-access').onclick = () => perform(async () => {
    await refresh();
    if (!manageOnly && flow.access.checkout.state === 'available' && (flow.access.access_state === 'unpaid' || flow.sourceAllowed)) await quote(flow.period);
  });
  $('recover').onclick = () => perform(async () => { await flow.recover(takePassword('purchase-password')); await refresh(); });
  $('setup').onclick = () => perform(async () => { await flow.recover(takePassword('manage-password')); await refresh(); });
  $('restart').onclick = () => perform(async () => {
    if (!$('consent').checked) throw new Refused();
    await flow.restart(takePassword('purchase-password'));
    await refresh();
    if (cardStepReady() && (!card || !flow.quote)) await quote(flow.period);
    message('The previous purchase was safely closed. Review this agreement, then choose Pay to start again.');
  });
  $('stop-renewals').onclick = () => perform(async () => {
    await flow.stopRenewals(takePassword('manage-password'));
    message('Future renewals are stopped. Already-paid access keeps its original end.');
  });
  function clear({ silent = false } = {}) {
    stopPolling(); notifications.clear(); announcedPaid = false;
    handoffModule?.revokeHandoff(access);
    handoffPending = false;
    generation++; access = ''; signedInEmail = ''; flow = null; busy = false;
    $('card-container').replaceChildren(); cardMount = null;
    for (const input of document.querySelectorAll('input, select')) { if (input.type === 'checkbox') input.checked = false;
      else input.value = input.id === 'country' ? 'US' : ''; }
    destroyCard(card);
    card = null; $('terms').textContent = ''; $('manage-plan').open = false;
    selectedPeriod = requestedPeriod || 'monthly'; planChosen = manageOnly || Boolean(requestedPeriod);
    message(silent ? '' : 'Signed out of this page. Your app session is unchanged.'); update();
  }
  $('sign-out').onclick = () => clear();
  window.addEventListener('pagehide', () => clear({ silent: true }));
  document.addEventListener?.('visibilitychange', () => {
    if (document.visibilityState !== 'visible') { stopPolling(); update(); }
    else startPolling();
  });
  async function bootstrapHandoff() {
    const fragment = location.hash;
    if (!fragment || fragment === '#main') return;
    // Remove the capability before importing helpers or contacting any API/SDK.
    history.replaceState(null, '', location.pathname + location.search);
    clear({ silent: true });
    handoffPending = true; update();
    const scope = generation;
    await perform(async () => {
      let code = '';
      try {
        const helper = await import('./checkout_handoff.js');
        if (scope !== generation) return;
        handoffModule = helper;
        code = helper.parseHandoff(fragment);
        const result = await helper.redeemHandoff(code, { fetcher: fetch, runtime,
          expectedPlan: requestedPeriod, expectedPurpose: manageOnly ? 'manage' : 'purchase' });
        if (scope !== generation) return;
        await acceptSignIn({ access: result.checkout_token, user: result.parent }, scope);
      } catch (_) {
        if (scope !== generation) return;
        handoffModule?.revokeHandoff(access); access = ''; flow = null; signedInEmail = '';
        message('Open checkout again from the app.');
      } finally { code = ''; if (scope === generation) handoffPending = false; }
    });
  }
  window.addEventListener('hashchange', () => { void bootstrapHandoff(); });
  const countryCodes = 'AD AE AF AG AI AL AM AO AQ AR AS AT AU AW AX AZ BA BB BD BE BF BG BH BI BJ BL BM BN BO BQ BR BS BT BV BW BY BZ CA CC CD CF CG CH CI CK CL CM CN CO CR CU CV CW CX CY CZ DE DJ DK DM DO DZ EC EE EG EH ER ES ET FI FJ FK FM FO FR GA GB GD GE GF GG GH GI GL GM GN GP GQ GR GS GT GU GW GY HK HM HN HR HT HU ID IE IL IM IN IO IQ IR IS IT JE JM JO JP KE KG KH KI KM KN KP KR KW KY KZ LA LB LC LI LK LR LS LT LU LV LY MA MC MD ME MF MG MH MK ML MM MN MO MP MQ MR MS MT MU MV MW MX MY MZ NA NC NE NF NG NI NL NO NP NR NU NZ OM PA PE PF PG PH PK PL PM PN PR PS PT PW PY QA RE RO RS RU RW SA SB SC SD SE SG SH SI SJ SK SL SM SN SO SR SS ST SV SX SY SZ TC TD TF TG TH TJ TK TL TM TN TO TR TT TV TW TZ UA UG UM US UY UZ VA VC VE VG VI VN VU WF WS YE YT ZA ZM ZW'.split(' ');
  const countryNames = new Intl.DisplayNames(['en'], { type: 'region' });
  const options = [...new Set(countryCodes)].map((code) => ({ code, name: countryNames.of(code) }));
  $('country').replaceChildren();
  for (const entry of options.sort((a, b) => a.name.localeCompare(b.name))) {
    const option = document.createElement('option'); option.value = entry.code; option.textContent = entry.name;
    $('country').append(option);
  }
  $('country').value = 'US';
  if (location.protocol !== 'https:' || !window.isSecureContext || location.origin !== runtime.origin ||
      !['sandbox', 'production'].includes(runtime.environment) ||
      (!manageOnly && !(runtime.environment === 'sandbox' ? /^sandbox-[A-Za-z0-9_-]{8,160}$/.test(runtime.application_id) :
        /^sq0id[pb]-[A-Za-z0-9_-]{8,160}$/.test(runtime.application_id)))) {
    message('Secure parent checkout is not configured for this address.');
    document.querySelectorAll('button').forEach((button) => { button.disabled = true; });
    return;
  }
  update();
  if (handoffPending) void bootstrapHandoff();
}
if (typeof document !== 'undefined') attachPage();
