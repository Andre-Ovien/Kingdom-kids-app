import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const source = readFileSync(new URL('./static/billing/parent_checkout.js', import.meta.url));
const { PurchaseFlow, validQuote, validAccess, tokenizationFailure } = await import('data:text/javascript;base64,' + source.toString('base64'));
const parent = 'parent-fixture';
const id = 'aaaabbbb-1111-2222-3333-444455556666';
function quote(period = 'monthly') {
  const yearly = period === 'yearly';
  return { environment: 'sandbox', country: 'US', purchasable: true, billing_period: period,
    amount_minor: yearly ? 9990 : 999, currency: 'USD', cadence: yearly ? 'ANNUAL' : 'DAYS_30',
    coverage_rule: yearly ? 'calendar_year_1' : 'elapsed_days_30',
    first_renewal_rule: yearly ? 'calendar_year_1' : 'elapsed_days_30',
    coverage_start: 'canonical_successful_payment_capture', first_renewal_at: null,
    billing_controller: 'app_owned_terms', can_prorate: false, free_period: false,
    billing_timezone: 'America/New_York', disclosure_version: 'fixture-current-v2',
    disclosure_sha256: 'a'.repeat(64), disclosure: 'Synthetic recurring authorization.',
    web_tokenization: { intent: 'CHARGE_AND_STORE', amount: yearly ? '99.90' : '9.99',
      currencyCode: 'USD', customerInitiated: true, sellerKeyedIn: false } };
}
function access(state = 'unpaid') {
  return { schema_version: 1, parent_id: parent, environment: 'sandbox', access_state: state,
    evaluated_at: '2026-11-12T10:00:00Z', access_until: state === 'paid' ? '2026-12-12T10:00:00Z' : null,
    checkout: { state: 'available' }, purchase_recovery: null };
}
function fixture(options = {}) {
  const calls = []; let tokenizations = 0;
  const flow = new PurchaseFlow({ parent,
    api: async (path, method, body) => { calls.push({ path, method, body });
      if (options.api) return await options.api(path, method, body);
      if (path === '/api/billing/content-access/') return access('paid');
      return { id, terms: quote(), current_term: null };
    },
    canCharge: options.canCharge || (() => true),
    tokenize: async (details) => { tokenizations++; assert.equal(details.intent, 'CHARGE_AND_STORE');
      return options.tokenize ? await options.tokenize(details) : 'cnon:synthetic-single-use'; },
  });
  flow.setQuote(quote(), 'monthly'); flow.access = access();
  return { flow, calls, count: () => tokenizations };
}

test('only capture-bound current monthly/yearly server quotes are accepted', () => {
  assert.ok(validQuote(quote(), 'monthly')); assert.ok(validQuote(quote('yearly'), 'yearly'));
  for (const bad of [{ ...quote(), amount_minor: 1000 }, { ...quote(), environment: 'production' },
      { ...quote(), first_renewal_at: '2026-11-28' }, { ...quote(), renewal_anchor_day: 28 },
      { ...quote('yearly'), amount_minor: 10789 }]) assert.equal(validQuote(bad, bad.billing_period), false);
});
test('one manual payment binds quote/consent then sends source only; canonical global proof grants', async () => {
  const { flow, calls, count } = fixture();
  assert.equal((await flow.purchase('synthetic-password', {})).access_state, 'paid');
  assert.equal(count(), 1);
  assert.deepEqual(Object.keys(calls[0].body).sort(), ['accepted', 'billing_period', 'disclosure_sha256', 'disclosure_version', 'password']);
  assert.deepEqual(Object.keys(calls[1].body).sort(), ['charge_source_id', 'password']);
  assert.equal(calls[1].path, `/api/billing/square/checkout-intents/${id}/confirm/`);
  assert.equal(calls.length, 3);
});
test('SDK success without a canonical paid proof never grants', async () => {
  const { flow } = fixture({ api: async (path) => path === '/api/billing/content-access/' ? access('unknown') :
    { id, terms: quote(), current_term: null } });
  assert.equal((await flow.purchase('synthetic-password', {})).access_state, 'unknown');
});
test('uncertain confirmation stays locked and manual recovery sends no new source', async () => {
  let uncertain = true;
  const { flow, calls, count } = fixture({ api: async (path) => {
    if (path.endsWith('/confirm/') && uncertain) throw new Error('Synthetic private failure not shown');
    if (path === '/api/billing/content-access/') return access('paid');
    return { id, terms: quote(), current_term: null };
  } });
  await assert.rejects(flow.purchase('synthetic-password', {}));
  const before = calls.length;
  await assert.rejects(flow.purchase('synthetic-password', {}));
  assert.equal(calls.length, before); assert.equal(count(), 1);
  uncertain = false;
  await flow.recover('fresh-synthetic-password');
  assert.deepEqual(calls[before].body, { password: 'fresh-synthetic-password' });
  assert.equal(count(), 1); assert.equal(flow.access.access_state, 'paid');
});
test('lost reserve never creates a second intent automatically', async () => {
  const { flow, calls, count } = fixture({ api: async () => { throw new Error('Synthetic timeout'); } });
  await assert.rejects(flow.purchase('synthetic-password', {}));
  await assert.rejects(flow.purchase('synthetic-password', {}));
  assert.equal(calls.length, 1); assert.equal(count(), 0);
});
test('an early read cannot unlock a local uncertain payment for a fresh source', async () => {
  const { flow } = fixture({ api: async () => ({ ...access('unknown'), purchase_recovery: {
    intent_id: id, billing_period: 'monthly', source_allowed: true } }) });
  flow.intent = id; flow.attempted = true;
  await flow.readAccess();
  assert.equal(flow.attempted, true); assert.equal(flow.sourceAllowed, false);
});
test('already recorded term prevents tokenization and retains exact owned intent', async () => {
  const { flow, count } = fixture({ api: async () => ({ id, terms: quote(), current_term: { coverage_state: 'awaiting_canonical_capture' } }) });
  await assert.rejects(flow.purchase('synthetic-password', {}));
  assert.equal(flow.intent, id); assert.equal(count(), 0); assert.equal(flow.attempted, true);
});
test('consent revoked during tokenization cannot send payment', async () => {
  let consent = true;
  const { flow, calls } = fixture({ canCharge: () => consent,
    tokenize: async () => { consent = false; return 'cnon:synthetic-discarded'; } });
  await assert.rejects(flow.purchase('synthetic-password', {}));
  assert.equal(calls.length, 1); assert.equal(flow.attempted, false);
});
test('safe SDK field errors never include raw SDK text and preserve explicit same-intent retry', async () => {
  for (const [field, code] of [['Card Number','card_number'],['expirationDate','expiration_date'],
      ['CVV','security_code'],['postalCode','postal_code']]) {
    const error = tokenizationFailure({status:'Invalid',errors:[{field,message:'private-sdk-message',detail:'private-card-value'}]});
    assert.equal(error.code,code); assert.match(error.message,/No payment was sent/);
    assert.equal(error.message.includes('private-'),false);
  }
  assert.equal(tokenizationFailure({status:'Invalid',errors:{field:'CVV'}}).code,'security_code');
  assert.equal(tokenizationFailure({status:'Invalid',errors:[{field:'private-unknown-field'}]}).code,'card_details');
  assert.equal(tokenizationFailure({name:'VerifyBuyerError',message:'private-verification-detail'}).code,'verification_incomplete');
  let invalid = true;
  const { flow, calls, count } = fixture({tokenize:async()=>{
    if(invalid)throw tokenizationFailure({status:'Invalid',errors:[{field:'CVV'}]});
    return 'cnon:synthetic-explicit-second-click';
  }});
  await assert.rejects(flow.purchase('synthetic-password',{}),{code:'security_code'});
  assert.equal(flow.intent,id);assert.equal(flow.attempted,false);assert.equal(count(),1);
  assert.equal(calls.filter(call=>call.method==='POST').length,1);
  invalid=false;await flow.purchase('synthetic-password',{});
  assert.equal(calls.filter(call=>call.path=== '/api/billing/square/checkout-intents/' && call.method==='POST').length,1);
  assert.equal(calls.filter(call=>call.path.endsWith('/confirm/')).length,1);assert.equal(count(),2);
});
test('pre-POST guard refusal never tokenizes or charges and explicit retry keeps the same intent', async()=>{
  let allowed=false;
  const { flow,calls,count }=fixture({canCharge:()=>allowed});
  await assert.rejects(flow.purchase('synthetic-password',{}),{code:'review_before_payment'});
  assert.equal(flow.intent,id);assert.equal(flow.attempted,false);assert.equal(count(),0);
  allowed=true;await flow.purchase('synthetic-password',{});
  assert.equal(calls.filter(call=>call.path==='/api/billing/square/checkout-intents/'&&call.method==='POST').length,1);
  assert.equal(calls.filter(call=>call.path.endsWith('/confirm/')).length,1);
});
test('double click cannot race two tokenizations or posts', async () => {
  let finish; const waiting = new Promise((resolve) => { finish = resolve; });
  const { flow, calls, count } = fixture({ tokenize: () => waiting });
  const first = flow.purchase('synthetic-password', {});
  await Promise.resolve(); await Promise.resolve();
  await assert.rejects(flow.purchase('synthetic-password', {}));
  finish('cnon:synthetic-only-once'); await first;
  assert.equal(count(), 1); assert.equal(calls.filter((item) => item.path.endsWith('/confirm/')).length, 1);
});
test('wrong-parent and invalid paid-expiry responses are refused', async () => {
  assert.equal(validAccess({ ...access('paid'), parent_id: 'another-parent' }, parent), false);
  assert.equal(validAccess({ ...access('paid'), access_until: null }, parent), false);
  const { flow } = fixture({ api: async () => ({ ...access('paid'), parent_id: 'another-parent' }) });
  await assert.rejects(flow.readAccess());
});
test('restart only reserves after explicit action, never automatically tokenizes or charges', async () => {
  const { flow, calls, count } = fixture(); flow.intent = id; flow.attempted = true;
  flow.access.purchase_recovery = { intent_id: id, restart_allowed: true };
  await flow.restart('synthetic-password');
  assert.equal(calls.length, 1); assert.ok(calls[0].path.endsWith('/restart/'));
  assert.equal(count(), 0); assert.equal(flow.attempted, false);
});
test('unknown payment cannot use restart or create a new nonce', async () => {
  const { flow, calls, count } = fixture(); flow.intent = id; flow.attempted = true;
  flow.access = access('unknown'); flow.access.purchase_recovery = { restart_allowed: false };
  await assert.rejects(flow.restart('synthetic-password'));
  assert.equal(calls.length, 0); assert.equal(count(), 0);
});

test('production quotes/access require the same explicit runtime environment', async () => {
  const q = { ...quote(), environment: 'production' };
  const a = { ...access(), environment: 'production' };
  assert.equal(validQuote(q, 'monthly'), false);
  assert.equal(validQuote(q, 'monthly', 'production'), true);
  assert.equal(validAccess(a, parent), false);
  assert.equal(validAccess(a, parent, 'production'), true);
  const calls = [];
  const flow = new PurchaseFlow({ parent, environment: 'production', tokenize: async () => 'cnon:fake-production',
    api: async (path, method, body) => { calls.push({path,method,body});
      if(path === '/api/billing/content-access/') return a;
      if(path === basePath()) return {id,terms:q,current_term:null};
      return {}; } });
  function basePath() { return '/api/billing/square/checkout-intents/'; }
  flow.setQuote(q,'monthly'); await flow.readAccess(); await flow.purchase('synthetic-password',{});
  assert.equal(calls.filter((r)=>r.path.endsWith('/confirm/')).length,1);
  assert.equal(calls.find((r)=>r.path.endsWith('/confirm/')).body.charge_source_id,'cnon:fake-production');
  assert.throws(()=>flow.setQuote(quote(),'monthly'));
});

test('manage purpose permits only explicit read recovery/cancel and never quote/source/restart', async () => {
  const calls = []; let tokens = 0;
  const a={...access(),checkout:{state:'unavailable',management_state:'available'},purchase_recovery:null,management_recovery:{
    intent_id:id,billing_period:'monthly',source_allowed:false,restart_allowed:true,renewals_enabled:true}};
  const flow=new PurchaseFlow({parent,purpose:'manage',tokenize:async()=>{tokens++;return 'cnon:forbidden';},
    api:async(path,method,body)=>{calls.push({path,method,body});return path==='/api/billing/content-access/'?a:{};}});
  await flow.readAccess();
  assert.throws(()=>flow.setQuote(quote(),'monthly'));
  await assert.rejects(flow.purchase('synthetic-password',{}));await assert.rejects(flow.restart('synthetic-password'));
  assert.equal(tokens,0);assert.equal(calls.length,1);
  await flow.recover('synthetic-password');await flow.stopRenewals('synthetic-password');
  assert.deepEqual(calls.filter((r)=>r.method==='POST').map((r)=>r.body),[
    {password:'synthetic-password'},{password:'synthetic-password'}]);
});

test('explicit controlled production quote is CHARGE only, never a recurring/Sandbox quote', async () => {
  const q={...quote(),environment:'production',billing_mode:'one_period',automatic_renewal:false,
    card_storage:'none',first_renewal_rule:null,web_tokenization:{...quote().web_tokenization,intent:'CHARGE'}};
  assert.equal(validQuote(q,'monthly','production','one_period'),true);
  assert.equal(validQuote(q,'monthly','production'),false);
  assert.equal(validQuote(q,'monthly','sandbox','one_period'),false);
  assert.equal(validQuote({...q,automatic_renewal:true},'monthly','production','one_period'),false);
  assert.equal(validQuote({...q,web_tokenization:{...q.web_tokenization,intent:'CHARGE_AND_STORE'}},'monthly','production','one_period'),false);
  const calls=[];let tokenized=0;
  const a={...access(),environment:'production',checkout:{state:'available',reason_code:'production_controlled',controlled_parent_eligible:true}};
  const flow=new PurchaseFlow({parent,environment:'production',billingMode:'one_period',
    tokenize:async(details)=>{tokenized++;assert.equal(details.intent,'CHARGE');return 'cnon:one-period';},
    api:async(path,method,body)=>{calls.push({path,method,body});
      if(path==='/api/billing/content-access/')return a;
      if(path==='/api/billing/square/checkout-intents/')return{id,terms:q,current_term:null};return{};}});
  flow.setQuote(q,'monthly');await flow.readAccess();await flow.purchase('synthetic-password',{});
  await assert.rejects(flow.purchase('synthetic-password',{}));
  assert.equal(tokenized,1);assert.equal(calls.filter(c=>c.path.endsWith('/confirm/')).length,1);
});
