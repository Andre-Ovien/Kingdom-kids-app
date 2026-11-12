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
  billing_contact: 'Complete your billing name, email, address and postal code, then choose Pay again.',
  consent_required: 'Accept the billing agreement and confirm your password before choosing Pay again.',
  page_not_visible: 'Return to this checkout tab, review the agreement and choose Pay again.',
  review_before_payment: 'Keep this checkout tab visible and accept the agreement before choosing Pay again.',
  verification_canceled: 'Card verification was canceled. Review your details and choose Pay again.',
  verification_incomplete: 'Complete card verification in the secure Square form, then choose Pay again.',
  verification_configuration: 'Card verification could not start. Choose Check payment to reload the secure card form.',
  tokenization_unavailable: 'Card verification could not finish. Choose Check payment to reload the secure card form.',
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
export function validQuote(q, period) {
  const p = plans[period];
  return Boolean(p && q && q.environment === 'sandbox' && q.country === 'US' && q.purchasable === true &&
    q.billing_period === period && q.currency === 'USD' && q.amount_minor === p.amount &&
    q.cadence === p.cadence && q.coverage_rule === p.rule && q.first_renewal_rule === p.rule &&
    q.coverage_start === 'canonical_successful_payment_capture' && q.first_renewal_at === null &&
    q.billing_controller === 'app_owned_terms' && q.can_prorate === false && q.free_period === false &&
    typeof q.billing_timezone === 'string' && q.billing_timezone.length <= 64 &&
    typeof q.disclosure_version === 'string' && q.disclosure_version.length > 0 && q.disclosure_version.length <= 96 &&
    /^[a-f0-9]{64}$/.test(q.disclosure_sha256 || '') && typeof q.disclosure === 'string' &&
    q.disclosure.length > 0 && q.disclosure.length <= 16000 && !('renewal_anchor_day' in q) &&
    q.web_tokenization?.intent === 'CHARGE_AND_STORE' &&
    q.web_tokenization.amount === (p.amount / 100).toFixed(2) && q.web_tokenization.currencyCode === 'USD' &&
    q.web_tokenization.customerInitiated === true && q.web_tokenization.sellerKeyedIn === false);
}
export function validAccess(data, parent) {
  if (!data || data.schema_version !== 1 || data.parent_id !== parent || data.environment !== 'sandbox' ||
      !['paid', 'unpaid', 'unknown'].includes(data.access_state) || !Number.isFinite(Date.parse(data.evaluated_at)) ||
      !['available', 'unavailable', 'unknown'].includes(data.checkout?.state)) return false;
  return data.access_state !== 'paid' || (Number.isFinite(Date.parse(data.access_until)) &&
    Date.parse(data.access_until) > Date.parse(data.evaluated_at));
}
export class PurchaseFlow {
  constructor({ api, tokenize, parent, canCharge = () => true }) {
    this.api = api; this.tokenize = tokenize; this.parent = parent;
    this.period = 'monthly'; this.quote = null; this.intent = ''; this.attempted = false;
    this.reserveAttempted = false; this.sourceAllowed = false; this.access = null;
    this.canCharge = canCharge; this.busy = false;
  }
  setQuote(quote, period) {
    if (!validQuote(quote, period) || (this.intent && this.period !== period)) throw new Refused();
    this.period = period; this.quote = quote;
  }
  async readAccess() {
    const result = await this.api('/api/billing/content-access/', 'GET');
    if (!validAccess(result, this.parent)) throw new Refused();
    this.access = result;
    const recovery = result.purchase_recovery;
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
    if (!password || password.length > 1024 || !validQuote(this.quote, this.period)) throw new Refused();
    return { password, accepted: true, billing_period: this.period,
      disclosure_version: this.quote.disclosure_version, disclosure_sha256: this.quote.disclosure_sha256 };
  }
  acceptIntent(result) {
    if (!uuid.test(result?.id || '')) throw new Refused();
    this.intent = result.id; // Preserve the owned reference even if later validation fails.
    if (!validQuote(result.terms, this.period) || result.terms.disclosure_sha256 !== this.quote.disclosure_sha256) throw new Refused();
    if (result.current_term) { this.attempted = true; this.sourceAllowed = false; throw new Refused(); }
    this.sourceAllowed = true;
  }
  async purchase(password, contact) {
    if (this.busy) throw new Refused();
    this.busy = true;
    let token = null;
    try {
      if (this.attempted || !this.access || this.access.access_state === 'paid' ||
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
    if (!this.intent || this.access?.purchase_recovery?.restart_allowed !== true ||
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
  let access = '', signedInEmail = '', flow = null, card = null, busy = false, generation = 0, selectedPeriod = 'monthly';
  let cardMount = null, mountSerial = 0;
  const active = (value) => { if (generation !== value || !access) throw new Refused(); };
  const message = (value, code = '') => {
    $('message').textContent = value; $('message').setAttribute('data-checkout-code', code);
  };
  function sync() {
    document.querySelectorAll('button').forEach((button) => { button.disabled = busy; });
    $('monthly').disabled = busy || Boolean(flow?.intent) || Boolean(flow?.reserveAttempted);
    $('yearly').disabled = $('monthly').disabled;
    $('pay').disabled = busy || !card || !flow?.quote || flow.attempted || !$('consent').checked ||
      flow.access?.access_state === 'paid' || (flow.access?.access_state !== 'unpaid' && !flow.sourceAllowed);
    $('restart').disabled = busy || !flow?.intent || !$('consent').checked || !flow?.quote;
  }
  async function perform(operation) {
    if (busy) return;
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
    finally { if (scope === generation) { busy = false; update(); } }
  }
  async function api(path, method = 'GET', body) {
    if (!path.startsWith('/api/') || path.startsWith('//')) throw new Refused();
    const requestGeneration = generation, requestAccess = access;
    const controller = new AbortController(), timer = setTimeout(() => controller.abort(), 40000);
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
          requestGeneration === generation && requestAccess === access) access = '';
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
    const data = { givenName: value('given-name'), familyName: value('family-name'), email: value('billing-email'),
      addressLines: [value('address')], city: value('city'), state: value('region'),
      postalCode: value('postal'), countryCode: value('country').toUpperCase() };
    if (!data.givenName || !data.familyName || !data.email || !$('billing-email').checkValidity() ||
        !data.addressLines[0] || !data.city || !data.postalCode || !/^[A-Z]{2}$/.test(data.countryCode)) throw new BeforePayment('billing_contact');
    return data;
  }
  async function loadSdk(scope) {
    if (!window.Square) await new Promise((resolve, reject) => {
      const script = document.createElement('script');
      const timer = setTimeout(() => { script.remove(); reject(new Refused()); }, 20000);
      script.src = 'https://sandbox.web.squarecdn.com/v1/square.js';
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
    const scope = generation;
    const result = await api(base + '?billing_period=' + period); active(scope);
    flow.setQuote(result, period); $('consent').checked = false;
    $('terms').textContent = result.disclosure;
    if (!card && (flow.access?.access_state === 'unpaid' || flow.sourceAllowed)) await loadSdk(scope);
  }
  function update() {
    const period = flow?.period || selectedPeriod, p = plans[period];
    $('monthly').setAttribute('aria-pressed', String(period === 'monthly'));
    $('yearly').setAttribute('aria-pressed', String(period === 'yearly'));
    $('plan-name').textContent = p.label; $('price').textContent = '$' + (p.amount / 100).toFixed(2);
    $('unit').textContent = p.unit; $('plan-badge').textContent = period === 'yearly' ? '2 MONTHS FREE' : 'ALL ACCESS';
    $('coverage').textContent = period === 'yearly' ? '12 full calendar months from your successful payment.' :
      'A full 30 days of access from your successful payment.';
    $('renewal-label').textContent = period === 'yearly' ? 'Renew on your yearly anniversary' : 'Renew every 30 days';
    $('pay').textContent = 'Pay $' + (p.amount / 100).toFixed(2) + ' & start';
    $('login-form').hidden = Boolean(access);
    $('account-identity').hidden = !access;
    $('account-identity').textContent = access ? 'Signed in as ' + signedInEmail + '. Use this same parent account in Kingdom Kids.' : '';
    $('sign-out').hidden = !access; $('recovery').hidden = !flow?.intent && !flow?.reserveAttempted;
    $('retry-access').hidden = !access || Boolean(flow?.intent) ||
      (flow?.access?.access_state !== 'unknown' && flow?.access?.checkout?.state === 'available');
    const paid = Boolean(access) && flow?.access?.access_state === 'paid'; $('complete').hidden = !paid;
    const recovery = flow?.access?.purchase_recovery;
    $('payment-area').hidden = !access || (!flow?.intent &&
      (paid || flow?.access?.checkout?.state !== 'available'));
    $('payment-title').textContent = paid ? 'Manage your plan' : 'Payment details';
    $('agreement').hidden = paid; $('consent').closest('label').hidden = paid;
    $('restart').hidden = recovery?.restart_allowed !== true || flow?.access?.access_state !== 'unpaid';
    $('recover').hidden = recovery?.restart_allowed === true || (flow?.sourceAllowed && !flow?.attempted);
    $('recover').textContent = recovery?.setup_required ? 'Complete plan setup' : 'Recover existing payment';
    $('stop-renewals').hidden = recovery?.renewals_enabled !== true;
    if (paid) { $('pay').hidden = true; $('card-container').hidden = true; $('contact').hidden = true;
      $('access-date').textContent = 'Your already-paid access keeps its confirmed coverage period.'; }
    else { $('pay').hidden = false; $('card-container').hidden = false; $('contact').hidden = false; }
    sync();
  }
  async function refresh() {
    const result = await flow.readAccess();
    message(result.access_state === 'paid' ? (result.purchase_recovery?.setup_required ?
      'Your paid access is verified. Complete plan setup before future renewals can begin.' : 'Your paid access has been verified.') :
      result.checkout.state !== 'available' ? 'Checkout is unavailable at this address. Parent account settings in the app remain accessible.' :
      result.access_state === 'unpaid' ? 'Review the billing agreement before continuing.' :
      'Access could not yet be confirmed. Your account is still signed in. Check or recover an existing purchase.');
  }
  $('login-form').addEventListener('submit', (event) => { event.preventDefault(); perform(async () => {
    let password = takePassword('login-password'); const scope = generation;
    try {
      const result = await api('/api/accounts/login/', 'POST', { email: $('email').value.trim(), password });
      if (generation !== scope || typeof result.access !== 'string' || result.access.length > 16384 ||
          !result.user?.id || result.user.email_verified !== true ||
          typeof result.user.email !== 'string' || !result.user.email || result.user.email.length > 254) throw new Refused();
      access = result.access;
      signedInEmail = result.user.email;
      flow = new PurchaseFlow({ api: async (...args) => { active(scope); const value = await api(...args); active(scope); return value; },
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
      if (flow.access.checkout.state === 'available') await quote(flow.period);
    } finally { password = ''; }
  }); });
  for (const period of ['monthly', 'yearly']) $(period).onclick = () => perform(async () => {
    if (flow?.intent || flow?.reserveAttempted) throw new Refused();
    if (flow) await quote(period);
    else { selectedPeriod = period; message('Sign in to confirm the selected plan with the server.'); }
  });
  $('consent').onchange = sync;
  $('pay').onclick = () => perform(async () => {
    if (!$('consent').checked) throw new BeforePayment('consent_required');
    await flow.purchase(takePassword('purchase-password'), contact()); await refresh();
  });
  $('check').onclick = () => perform(async () => { await refresh(); if (flow.sourceAllowed && (!flow.quote || !card)) await quote(flow.period); });
  $('retry-access').onclick = () => perform(async () => {
    await refresh();
    if (flow.access.checkout.state === 'available' && (flow.access.access_state === 'unpaid' || flow.sourceAllowed)) await quote(flow.period);
  });
  $('recover').onclick = () => perform(async () => { await flow.recover(takePassword('purchase-password')); await refresh(); });
  $('restart').onclick = () => perform(async () => {
    if (!$('consent').checked) throw new Refused();
    await flow.restart(takePassword('purchase-password'));
    await refresh();
    message('The previous purchase was safely closed. Review this agreement, then choose Pay to start again.');
  });
  $('stop-renewals').onclick = () => perform(async () => {
    await flow.stopRenewals(takePassword('purchase-password'));
    message('Future renewals are stopped. Already-paid access keeps its original end.');
  });
  function clear() {
    generation++; access = ''; signedInEmail = ''; flow = null; busy = false;
    $('card-container').replaceChildren(); cardMount = null;
    for (const input of document.querySelectorAll('input')) { if (input.type === 'checkbox') input.checked = false;
      else input.value = input.id === 'country' ? 'US' : ''; }
    destroyCard(card);
    card = null; $('terms').textContent = '';
    message('Signed out of this page. Your app session is unchanged.'); update();
  }
  $('sign-out').onclick = clear;
  window.addEventListener('pagehide', clear);
  if (location.protocol !== 'https:' || !window.isSecureContext || location.origin !== runtime.origin ||
      runtime.environment !== 'sandbox' || !runtime.application_id.startsWith('sandbox-')) {
    message('Secure parent checkout is not configured for this address.');
    document.querySelectorAll('button').forEach((button) => { button.disabled = true; });
    return;
  }
  update();
}
if (typeof document !== 'undefined') attachPage();
