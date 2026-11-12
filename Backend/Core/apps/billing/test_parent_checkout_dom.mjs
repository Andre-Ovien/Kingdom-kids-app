// Actual page JS under a synthetic DOM/SDK/fetch. No browser/provider/card data.
import { readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import vm from 'node:vm';
import assert from 'node:assert/strict';
const source = await readFile(new URL('./static/billing/parent_checkout.js', import.meta.url), 'utf8');
const sourceSha = createHash('sha256').update(source).digest('hex');
const later = () => new Promise((resolve) => setTimeout(resolve, 0));
const deferred = () => { let resolve, reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no; }); return {promise, resolve, reject}; };
async function fixture(mode) {
  const elements = new Map(), staticIds = new Set();
  class Element {
    constructor(id = '') { this._id='';this.id=id;this.value='';this._text='';this.hidden=false;this.disabled=false;
      this.checked=false;this.type='text';this.children=[];this.handlers={};this.label={hidden:false};this.parentNode=null;this.attributes={}; }
    set id(value) { if (this._id) elements.delete(this._id); this._id=value; if(value) elements.set(value,this); }
    get id() { return this._id; }
    set textContent(value) { this._text=value; this.replaceChildren(); }
    get textContent() { return this._text; }
    setAttribute(name,value) {this.attributes[name]=value;}
    getAttribute(name) {return this.attributes[name];}
    checkValidity() { return true; }
    closest() { return this.label; }
    addEventListener(name, fn) { this.handlers[name]=fn; }
    append(...children) { for(const child of children) { child.remove?.(); child.parentNode=this; this.children.push(child); } }
    appendChild(child) { this.append(child); return child; }
    replaceChildren(...children) { for(const child of this.children) child.parentNode=null; this.children=[]; this.append(...children); }
    remove() { if(this.parentNode) { const parent=this.parentNode; parent.children=parent.children.filter((child)=>child!==this); this.parentNode=null; } }
    get isConnected() { return staticIds.has(this.id) || Boolean(this.parentNode?.isConnected); }
  }
  const el=(id)=>elements.get(id);
  for(const id of ['monthly','yearly','pay','restart','recover','check','retry-access','stop-renewals','sign-out','login','message',
    'checkout-runtime','plan-name','price','unit','plan-badge','coverage','renewal-label','login-form','recovery',
    'complete','payment-area','payment-title','agreement','consent','card-container','contact','access-date','account-identity',
    'terms','login-password','email','purchase-password','given-name','family-name','billing-email','address','city','region','postal','country']) {
    staticIds.add(id); new Element(id);
  }
  el('consent').type='checkbox';el('country').value='US';
  el('checkout-runtime').textContent=JSON.stringify({environment:'sandbox',origin:'https://localhost:18443',
    application_id:'sandbox-synthetic-app',location_id:'synthetic-location'});
  const buttons=['monthly','yearly','pay','restart','recover','check','retry-access','stop-renewals','sign-out','login'];
  const inputs=['consent','login-password','email','purchase-password','given-name','family-name','billing-email','address','city','region','postal','country'];
  const oldAttach=deferred(), oldToken=deferred(), oldAccess=deferred();
  let created=0, loginCount=0, accessReads=0, confirmCalls=0, destroyCalls=0, tokenizations=0, reserveCalls=0, statusCalls=0;
  const frames = () => {
    const found=[]; const visit=(element)=>{ if(element.sdkFrame) found.push(element.sdkFrame); for(const child of element.children) visit(child); };
    visit(el('card-container')); return found;
  };
  const quote={environment:'sandbox',country:'US',purchasable:true,billing_period:'monthly',currency:'USD',amount_minor:999,
    cadence:'DAYS_30',coverage_rule:'elapsed_days_30',first_renewal_rule:'elapsed_days_30',coverage_start:'canonical_successful_payment_capture',
    first_renewal_at:null,billing_controller:'app_owned_terms',can_prorate:false,free_period:false,billing_timezone:'America/New_York',
    disclosure_version:'synthetic-version',disclosure_sha256:'a'.repeat(64),disclosure:'Synthetic terms',
    web_tokenization:{intent:'CHARGE_AND_STORE',amount:'9.99',currencyCode:'USD',customerInitiated:true,sellerKeyedIn:false}};
  const response=(data,status=200)=>{ const raw=new TextEncoder().encode(JSON.stringify(data));let done=false;
    return{status,ok:status===200,headers:{get:()=> 'application/json'},body:{getReader(){return{
      async read(){if(done)return{done:true};done=true;return{done:false,value:raw};},releaseLock(){}};}}}; };
  const sandbox={ TextDecoder,TextEncoder,Uint8Array,AbortController,setTimeout,clearTimeout,
    document:{getElementById:el,visibilityState:'visible',createElement:()=>new Element(),
      querySelectorAll:(selector)=>(selector==='button'?buttons:inputs).map(el)},
    location:{protocol:'https:',origin:'https://localhost:18443'},
    window:{isSecureContext:true,addEventListener(){},Square:{payments(){return{async card(){
      const id=++created;return{
        async attach(selector) { const mount=el(selector.slice(1)); assert.ok(mount); if(mode==='late_attach'&&id===1) await oldAttach.promise;
          const frame=new Element();frame.sdkFrame=id;mount.appendChild(frame); },
        tokenize(){tokenizations++;
          if(mode==='late_token'&&id===1)return oldToken.promise;
          if(mode==='sdk_invalid'&&tokenizations===1)return Promise.resolve({status:'Invalid',
            errors:[{field:'CVV',message:'private-sdk-message',detail:'private-card-data'}]});
          if(mode==='sdk_thrown_invalid')return Promise.reject({name:'TokenizationError',
            errors:[{field:'Postal Code',message:'private-sdk-message'}]});
          if(mode==='sdk_configuration')return Promise.reject({name:'InvalidOptionError',message:'private-sdk-message'});
          if(mode==='after_token_hidden')sandbox.document.visibilityState='hidden';
          return Promise.resolve({status:'OK',token:'cnon:synthetic-'+tokenizations});},
        destroy(){destroyCalls++;return Promise.reject(new Error('Synthetic SDK cleanup failure'));}
      };
    }};}}},
    fetch:async(path)=>{
      if(path==='/api/accounts/login/') {loginCount++;return response({access:'synthetic-memory-'+loginCount,user:{id:'synthetic-parent-'+loginCount,email:'parent-'+loginCount+'@example.test',email_verified:true}});}
      if(path==='/api/billing/content-access/') {accessReads++; if(mode==='stale_401'&&accessReads===2)return oldAccess.promise;
        return response({schema_version:1,parent_id:'synthetic-parent-'+loginCount,environment:'sandbox',
          access_state:mode==='uncertain_post'&&confirmCalls?'unknown':'unpaid',
          evaluated_at:'2026-11-12T00:00:00Z',access_until:null,checkout:{state:'available'},
          purchase_recovery:mode==='uncertain_post'&&confirmCalls?{intent_id:'11111111-1111-4111-8111-111111111111',
            billing_period:'monthly',source_allowed:true}:null});}
      if(path==='/api/billing/square/checkout-intents/?billing_period=monthly')return response(quote);
      if(path==='/api/billing/square/checkout-intents/') {reserveCalls++;
        if(mode==='before_token_hidden')sandbox.document.visibilityState='hidden';
        if(mode==='before_token_unchecked')el('consent').checked=false;
        return response({id:'11111111-1111-4111-8111-111111111111',terms:quote,current_term:null});}
      if(path==='/api/billing/square/checkout-intents/11111111-1111-4111-8111-111111111111/') {
        statusCalls++;return response({id:'11111111-1111-4111-8111-111111111111',terms:quote,current_term:null});}
      if(path.endsWith('/confirm/')) {confirmCalls++;if(mode==='uncertain_post')throw new Error('private-confirm-reply');return response({});}
      throw new Error('Unexpected synthetic endpoint');
    }
  };
  vm.runInNewContext(source.replace(/^export /gm,''),sandbox,{filename:'actual-parent-checkout.js'});
  const settle=async()=>{await later();await later();};
  const login=async()=>{el('email').value='synthetic@example.test';el('login-password').value='synthetic-password';
    el('login-form').handlers.submit({preventDefault(){}});await settle();};
  const signout=async()=>{el('sign-out').onclick();await settle();assert.equal(el('account-identity').hidden,true);assert.equal(el('account-identity').textContent,'');};
  await login();assert.equal(created,1);
  assert.equal(el('account-identity').hidden,false);
  assert.ok(el('account-identity').textContent.includes('parent-1@example.test'));
  const pay=async()=>{
    el('consent').checked=true;el('consent').onchange();el('purchase-password').value='synthetic-password';
    for(const [id,value]of Object.entries({'given-name':'Test','family-name':'Buyer','billing-email':'synthetic@example.test',
      address:'1 Test Street',city:'Test',region:'NY',postal:'10001',country:'US'}))el(id).value=value;
    el('pay').onclick();await settle();
  };
  if(['sdk_invalid','sdk_thrown_invalid','sdk_configuration'].includes(mode)) {
    await pay();assert.equal(confirmCalls,0);assert.equal(reserveCalls,1);assert.equal(tokenizations,1);
    assert.ok(el('message').textContent.startsWith('No payment was sent.'));
    assert.equal(el('message').textContent.includes('private-'),false);
    assert.equal(el('message').getAttribute('data-checkout-code'),{
      sdk_invalid:'security_code',sdk_thrown_invalid:'postal_code',sdk_configuration:'verification_configuration'}[mode]);
    await settle();assert.equal(confirmCalls,0);assert.equal(tokenizations,1);
    if(mode==='sdk_invalid') {
      assert.deepEqual(frames(),[1]);await pay();assert.equal(reserveCalls,1);assert.equal(statusCalls,1);
      assert.equal(confirmCalls,1);assert.equal(tokenizations,2);
    }
    return {safe_fixed_diagnostic:true,no_automatic_retry:true,same_intent_preserved:true};
  }
  if(['before_token_hidden','before_token_unchecked','after_token_hidden'].includes(mode)) {
    await pay();assert.equal(confirmCalls,0);assert.equal(reserveCalls,1);
    assert.equal(tokenizations,mode==='after_token_hidden'?1:0);
    assert.equal(el('message').getAttribute('data-checkout-code'),mode==='before_token_unchecked'?'consent_required':'page_not_visible');
    assert.ok(el('message').textContent.startsWith('No payment was sent.'));
    if(mode!=='after_token_hidden') {
      sandbox.document.visibilityState='visible';await pay();assert.equal(reserveCalls,1);
      assert.equal(statusCalls,1);assert.equal(confirmCalls,1);
    }
    return {visibility_and_consent_preserved:true,no_post_on_refusal:true,same_intent_manual_retry_only:true};
  }
  if(mode==='uncertain_post') {
    await pay();assert.equal(confirmCalls,1);assert.equal(tokenizations,1);
    assert.equal(el('message').getAttribute('data-checkout-code'),'payment_uncertain');
    assert.equal(el('message').textContent.includes('No payment was sent'),false);
    assert.equal(el('message').textContent.includes('private-confirm'),false);
    el('check').onclick();await settle();await pay();assert.equal(confirmCalls,1);assert.equal(tokenizations,1);
    assert.equal(reserveCalls,1);assert.equal(el('pay').disabled,true);
    return {uncertain_post_never_claims_not_sent:true,early_status_cannot_unlock:true,no_automatic_or_manual_recharge:true};
  }
  if(mode==='rejected_destroy') {
    assert.deepEqual(frames(),[1]);await signout();assert.deepEqual(frames(),[]);await login();assert.deepEqual(frames(),[2]);
    assert.ok(el('account-identity').textContent.includes('parent-2@example.test'));
    return {old_frame_removed_synchronously:true,new_parent_has_only_new_frame:true,sdk_destroy_rejected:true};
  }
  if(mode==='late_attach') {
    assert.deepEqual(frames(),[]);await signout();await login();assert.deepEqual(frames(),[2]);
    const before=el('message').textContent;oldAttach.resolve();await settle();
    assert.deepEqual(frames(),[2]);assert.equal(el('message').textContent,before);assert.equal(el('login-form').hidden,true);
    assert.equal(el('sign-out').disabled,false);
    return {late_old_attach_invisible:true,new_parent_frame_preserved:true,old_completion_did_not_overwrite_new_message_or_busy_state:true};
  }
  if(mode==='late_token') {
    el('consent').checked=true;el('consent').onchange();el('purchase-password').value='synthetic-password';
    for(const [id,value]of Object.entries({'given-name':'Test','family-name':'Buyer','billing-email':'synthetic@example.test',address:'1 Test Street',city:'Test',region:'NY',postal:'10001',country:'US'}))el(id).value=value;
    el('pay').onclick();await settle();await signout();await login();assert.deepEqual(frames(),[2]);
    const before=el('message').textContent;oldToken.reject(new Error('Synthetic late token failure'));await settle();
    assert.deepEqual(frames(),[2]);assert.equal(el('message').textContent,before);assert.equal(el('login-form').hidden,true);
    assert.equal(el('sign-out').disabled,false);assert.equal(confirmCalls,0);
    return {late_old_token_error_preserves_new_card:true,new_parent_message_and_busy_state_preserved:true,old_source_never_confirmed:true};
  }
  if(mode==='stale_401') {
    el('check').onclick();await settle();await signout();await login();assert.deepEqual(frames(),[2]);
    oldAccess.resolve(response({detail:'Synthetic unauthorized'},401));await settle();
    // Force a current-generation render to reveal whether an old reply cleared the new JWT.
    el('consent').onchange();el('monthly').onclick();await settle();
    assert.equal(el('login-form').hidden,true);assert.deepEqual(frames(),[2]);
    return {stale_unauthorized_reply_preserves_new_login:true,new_frame_preserved:true};
  }
  throw new Error('Unsupported synthetic scenario');
}
const scenarios={};
for(const name of ['rejected_destroy','late_attach','late_token','stale_401','sdk_invalid','sdk_thrown_invalid',
  'sdk_configuration','before_token_hidden','before_token_unchecked','after_token_hidden','uncertain_post'])scenarios[name]=await fixture(name);
const result={source_sha256:sourceSha,fake_dom_sdk_only:true,real_network_requests:0,real_card_data:false,scenarios};
console.log(JSON.stringify(result));
