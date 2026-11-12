"""Owned Square-hosted recurring checkout and bounded canonical settlement.

No financial retry happens during reconciliation. Redirects and signed event
bodies are hints only. Original template -> subscription -> invoice -> billed
order -> canonical captured payment is the only entitlement path.
"""
from datetime import timedelta,date
import secrets
from uuid import UUID,uuid4
from zoneinfo import ZoneInfo,ZoneInfoNotFoundError
from urllib.parse import urlencode
from django.conf import settings
from django.contrib.auth import get_user_model
from django.db import transaction
from django.utils import timezone
from django.utils.crypto import constant_time_compare,salted_hmac
from django.views.decorators.debug import sensitive_variables
from .checkout import CheckoutBusy,CheckoutConflict,CheckoutRejected,_check_parent,fingerprint
from .configuration import active_billing_environment,assert_client_environment,provider_identifier,SquareDisabled,SquareConfigurationError
from .client import SquareClientError
from .coverage import coverage_end
from .hosted_models import SquareHostedAttempt,SquareHostedPaymentProof,SquareHostedCancellation
from .hosted_policies import hosted_plan,disclosure
from .hosted_provider import (hosted_configuration,hosted_client,variation_id,approved_provider_url,RETURN_URL,hosted_enabled)
from .models import ParentContentEntitlement,SquareCheckoutIntent
from .plans import ALL_CONTENT_FEATURE
from .permissions import verified_content_access_until
from .reconciliation import CanonicalReader,_timestamp,_payment_snapshot,_payment_identity,_not_older_payments

class HostedParentAuthorizationRejected(CheckoutRejected):pass


def _check_hosted_parent(parent,password):
    try:_check_parent(parent,password)
    except CheckoutRejected:
        raise HostedParentAuthorizationRejected('Fresh parent password confirmation is required.') from None


AUTH_PREFIX='kkhost.'
STATES={'reserved','creating','ready','pending','paid','failed','canceled','review_required'}


def _uuid(value):
    if not isinstance(value,str) or len(value)!=36:raise CheckoutRejected('A valid checkout operation is required.')
    try:return UUID(value)
    except ValueError:raise CheckoutRejected('A valid checkout operation is required.') from None


def _eligible(parent):
    return bool(parent and parent.is_authenticated and parent.is_active and parent.is_email_verified)


def _auth_digest(value):return salted_hmac('kingdom-kids.hosted.authorization.v1',value,algorithm='sha256').hexdigest()
def _parent_digest(parent):return _auth_digest(str(parent.pk)+':'+parent.password)
def source_reference(proof):return 'square-hosted:'+str(proof.pk)


def _validate_location(client,config):
    merchant=client.retrieve_merchant(config.provider.merchant_id);location=client.retrieve_location(config.location_id)
    if (merchant.get('id')!=config.provider.merchant_id or merchant.get('country')!='US'
            or location.get('id')!=config.location_id or location.get('merchant_id')!=config.provider.merchant_id
            or location.get('country')!='US' or location.get('currency')!='USD' or location.get('status')!='ACTIVE'):
        raise CheckoutRejected('A verified US/USD merchant location is required.')
    from zoneinfo import ZoneInfo
    ZoneInfo(location.get('timezone'))
    return location['timezone']


def validate_variation(client,*,identifier,period):
    plan=hosted_plan(period);obj=client.retrieve_catalogue_object(identifier)
    data=obj.get('subscription_plan_variation_data',{});phases=data.get('phases',[])
    if (obj.get('id')!=identifier or obj.get('type')!='SUBSCRIPTION_PLAN_VARIATION' or obj.get('is_deleted') is True
            or len(phases)!=1 or not isinstance(phases[0],dict)
            or phases[0].get('ordinal')!=0 or phases[0].get('periods') is not None
            or phases[0].get('cadence')!=plan.cadence
            or phases[0].get('pricing',{}).get('type')!='STATIC'
            or phases[0].get('pricing',{}).get('price_money')!={'amount':plan.amount,'currency':'USD'}
            or phases[0].get('pricing',{}).get('price') not in (None,{'amount':plan.amount,'currency':'USD'})
            or data.get('monthly_billing_anchor_date') is not None or data.get('can_prorate') is not False):
        raise CheckoutRejected('The canonical recurring plan differs from its approved price or cadence.')
    provider_identifier(data.get('subscription_plan_id'),192)
    return obj


@sensitive_variables()
def quote(*,parent,period,client=None):
    if not _eligible(parent):raise SquareDisabled('A verified active parent is required.')
    env=active_billing_environment();config=hosted_configuration(environment=env)
    client=client or hosted_client(environment=env);assert_client_environment(client,environment=env)
    reader=HostedReader(client,timezone.now()+timedelta(seconds=8))
    _validate_location(reader,config);validate_variation(reader,identifier=variation_id(period,env),period=period)
    return {**disclosure(period,env),'parent_id':str(parent.pk)}


@sensitive_variables()
def authorize(*,parent,operation_id,billing_period,accepted,disclosure_version,disclosure_sha256):
    env=active_billing_environment();config=hosted_configuration(environment=env);operation=_uuid(operation_id)
    expected=disclosure(billing_period,env);plan=hosted_plan(billing_period)
    if accepted is not True or disclosure_version!=expected['disclosure_version'] or disclosure_sha256!=expected['disclosure_sha256']:
        raise CheckoutRejected('Accept the current recurring billing terms before checkout.')
    token=AUTH_PREFIX+secrets.token_urlsafe(32)
    with transaction.atomic():
        current=get_user_model().objects.select_for_update().get(pk=parent.pk)
        if not _eligible(current):raise SquareDisabled('A verified active parent is required.')
        attempt=SquareHostedAttempt.objects.select_for_update().filter(parent=current,environment=env,operation_id=operation).first()
        if attempt and attempt.billing_period!=billing_period:raise CheckoutConflict('Keep the original checkout plan and operation.')
        if attempt is None:
            if SquareHostedAttempt.objects.filter(parent=current,environment=env,is_open=True).exists():
                raise CheckoutConflict('An existing checkout must be checked or canceled before another purchase.')
            if SquareCheckoutIntent.objects.filter(parent=current,environment=env,is_open=True).exists():
                raise CheckoutConflict('An earlier payment must be checked before starting hosted checkout.')
            if verified_content_access_until(current,environment=env) is not None:
                raise CheckoutConflict('Existing paid access is still active; no second purchase is authorized.')
            attempt=SquareHostedAttempt.objects.create(parent=current,environment=env,operation_id=operation,
                billing_period=billing_period,policy_id=plan.policy_id,policy_sha256=plan.policy_sha256,
                disclosure_sha256=disclosure_sha256,merchant_id=config.provider.merchant_id,location_id=config.location_id,
                variation_id=variation_id(billing_period,env),amount_minor=plan.amount)
        if verified_content_access_until(current,environment=env) is not None:
            raise CheckoutConflict('Existing paid access is still active; no second purchase is authorized.')
        if not attempt.is_open or attempt.cancel_requested_at or attempt.subscription_id:
            raise CheckoutConflict('This checkout is already stopped; use its status rather than reopening it.')
        if attempt.policy_sha256!=plan.policy_sha256 or attempt.disclosure_sha256!=disclosure_sha256:
            raise CheckoutConflict('The existing checkout requires its original billing terms.')
        attempt.authorization_sha256=_auth_digest(token);attempt.authorization_expires_at=timezone.now()+timedelta(minutes=10)
        attempt.parent_auth_sha256=_parent_digest(current);attempt.save(update_fields=('authorization_sha256','authorization_expires_at','parent_auth_sha256','updated_at'))
    return {**identity(attempt),'authorization_token':token,'authorization_expires_at':attempt.authorization_expires_at.isoformat()}


def identity(attempt):
    return {'schema_version':1,'parent_id':str(attempt.parent_id),'environment':attempt.environment,
        'attempt_id':str(attempt.pk),'operation_id':str(attempt.operation_id),'billing_period':attempt.billing_period,
        'amount_minor':attempt.amount_minor,'currency':attempt.currency,'return_state':str(attempt.return_state)}


def recovery(parent,environment):
    attempt=SquareHostedAttempt.objects.filter(parent=parent,environment=environment,is_open=True).order_by('-created_at').first()
    if not attempt:
        attempt=SquareHostedAttempt.objects.filter(parent=parent,environment=environment).exclude(subscription_id='').order_by('-created_at').first()
    if not attempt:return None
    return {k:v for k,v in status(attempt).items() if k in {'attempt_id','operation_id','billing_period','state','return_state','payment_confirmed','renewals_enabled'}}


def status(attempt):
    now=timezone.now()
    proof=attempt.payment_proofs.filter(environment=attempt.environment,status='COMPLETED',refunded_minor=0,
        revoked_at__isnull=True,captured_at__lte=now,valid_until__gt=now).order_by('-valid_until').first()
    confirmed=bool(proof and _valid_proof(proof,attempt))
    return {**identity(attempt),'state':attempt.state if attempt.state in STATES else 'review_required',
        'checkout_url':approved_provider_url(attempt.checkout_url,environment=attempt.environment) if attempt.state=='ready' and attempt.checkout_url else None,
        'payment_confirmed':confirmed,'access_state':'paid' if confirmed else 'unknown' if attempt.state in {'ready','creating','pending','review_required'} else 'unpaid',
        'access_until':proof.valid_until.isoformat() if confirmed else None,'renewals_enabled':attempt.renewals_enabled,
        'cancel_requested':attempt.cancel_requested_at is not None,
        'cancellation_confirmed':bool(attempt.cancel_requested_at and not attempt.renewals_enabled and (attempt.canceled_date or attempt.provider_status in {'CANCELED','COMPLETED','DEACTIVATED'} or (attempt.state=='canceled' and not attempt.is_open and not attempt.order_template_id and not attempt.request_body)))}


def _payload(attempt):
    return {'idempotency_key':str(attempt.provider_idempotency_key),
        'order':{'location_id':attempt.location_id,'reference_id':str(attempt.pk),
            'metadata':{'kingdom_kids_attempt':str(attempt.pk)},'line_items':[{'name':'Kingdom Kids '+attempt.billing_period+' subscription',
                'quantity':'1','base_price_money':{'amount':attempt.amount_minor,'currency':'USD'}}]},
        'checkout_options':{'subscription_plan_id':attempt.variation_id,'allow_tipping':False,
            'ask_for_shipping_address':False,'enable_coupon':False,'enable_loyalty':False,
            'redirect_url':RETURN_URL+'?'+urlencode({'attempt':str(attempt.pk),'state':str(attempt.return_state)})}}


def _contract(attempt,config):
    plan=hosted_plan(attempt.billing_period)
    if (attempt.environment!=config.provider.environment or attempt.merchant_id!=config.provider.merchant_id
            or attempt.location_id!=config.location_id or attempt.policy_id!=plan.policy_id or attempt.policy_sha256!=plan.policy_sha256
            or attempt.amount_minor!=plan.amount or attempt.currency!='USD'):
        raise CheckoutRejected('The owned hosted contract no longer matches its frozen provider scope.')


def _claim(attempt_id,*,parent=None,creating=False,authorization_token=None):
    env=active_billing_environment();config=hosted_configuration(environment=env,readonly=not creating)
    initial=SquareHostedAttempt.objects.get(pk=attempt_id,environment=env,**({'parent':parent} if parent else {}))
    with transaction.atomic():
        owner=get_user_model().objects.select_for_update().filter(pk=initial.parent_id).first()
        attempt=SquareHostedAttempt.objects.select_for_update().get(pk=initial.pk,environment=env)
        _contract(attempt,config);now=timezone.now()
        if attempt.processing_lease and attempt.lease_until and attempt.lease_until>now:raise CheckoutBusy('This checkout is already being checked.')
        if creating:
            if attempt.subscription_id or (owner and verified_content_access_until(owner,environment=env) is not None):
                raise CheckoutConflict('This parent already has paid access or an owned recurring subscription; use management.')
            if (not _eligible(owner) or attempt.cancel_requested_at or not attempt.is_open
                    or not isinstance(authorization_token,str) or not authorization_token.startswith(AUTH_PREFIX)
                    or len(authorization_token)!=len(AUTH_PREFIX)+43 or not attempt.authorization_expires_at
                    or attempt.authorization_expires_at<=now or not constant_time_compare(attempt.authorization_sha256,_auth_digest(authorization_token))
                    or not constant_time_compare(attempt.parent_auth_sha256,_parent_digest(owner))):
                raise CheckoutRejected('Fresh parent authorization is required before opening payment.')
            if attempt.variation_id!=variation_id(attempt.billing_period,env):raise CheckoutConflict('Keep the existing checkout until its provider configuration is checked.')
            if not attempt.request_body:
                attempt.request_body=_payload(attempt);attempt.request_sha256=fingerprint(attempt.request_body)
            if attempt.request_sha256!=fingerprint(attempt.request_body) or attempt.request_body!=_payload(attempt):
                raise CheckoutRejected('The frozen checkout request changed; do not replace its key.')
        attempt.processing_lease=uuid4();attempt.lease_until=now+timedelta(seconds=45)
        if creating and not attempt.payment_link_id:attempt.state='creating'
        attempt.save()
        return attempt,config


def _checkpoint(attempt,**changes):
    with transaction.atomic():
        current=SquareHostedAttempt.objects.select_for_update().get(pk=attempt.pk,environment=attempt.environment)
        if current.processing_lease!=attempt.processing_lease or not current.lease_until or current.lease_until<=timezone.now():
            raise CheckoutBusy('Checkout processing ownership changed.')
        if changes.get('state')=='ready' and (current.parent_id is None or current.cancel_requested_at):
            changes['state']='pending'
        for k,v in changes.items():setattr(current,k,v)
        current.save(update_fields=tuple(changes)+('updated_at',))
    for k,v in changes.items():setattr(attempt,k,v)


@sensitive_variables()
def prepare(*,parent,operation_id,billing_period,authorization_token,client=None):
    env=active_billing_environment();operation=_uuid(operation_id)
    initial=SquareHostedAttempt.objects.get(parent=parent,environment=env,operation_id=operation,billing_period=billing_period)
    attempt,config=_claim(initial.pk,parent=parent,creating=True,authorization_token=authorization_token)
    try:
        client=client or hosted_client(environment=env);assert_client_environment(client,environment=env)
        reader=HostedReader(client,timezone.now()+timedelta(seconds=8))
        _validate_location(reader,config);validate_variation(reader,identifier=attempt.variation_id,period=attempt.billing_period)
        if attempt.payment_link_id:
            link=reader.retrieve_payment_link(attempt.payment_link_id)
        else:
            # Last authorization checkpoint; provider request is outside locks.
            with transaction.atomic():
                owner=get_user_model().objects.select_for_update().get(pk=parent.pk)
                current=SquareHostedAttempt.objects.select_for_update().get(pk=attempt.pk,environment=env)
                hosted_configuration(environment=env)
                if (verified_content_access_until(owner,environment=env) is not None or not _eligible(owner) or current.cancel_requested_at or current.processing_lease!=attempt.processing_lease
                        or current.authorization_expires_at<=timezone.now()
                        or not constant_time_compare(current.parent_auth_sha256,_parent_digest(owner))):
                    raise CheckoutRejected('This hosted checkout is no longer authorized.')
            reader.ensure_budget()
            result=client.create_hosted_subscription_link(payload=attempt.request_body)
            link=result.get('payment_link',{})
        identifier=provider_identifier(link.get('id'),192);order=provider_identifier(link.get('order_id'),192)
        url=approved_provider_url(link.get('url'),environment=env)
        if attempt.payment_link_id and (identifier!=attempt.payment_link_id or order!=attempt.order_template_id):
            raise CheckoutRejected('The provider returned another checkout.')
        template=reader.retrieve_order(order)
        _validate_template(template,attempt,expected_id=order)
        with transaction.atomic():
            owner=get_user_model().objects.select_for_update().filter(pk=parent.pk).first()
            current=SquareHostedAttempt.objects.select_for_update().get(pk=attempt.pk,environment=env)
            allowed=_eligible(owner) and not current.cancel_requested_at and constant_time_compare(current.parent_auth_sha256,_parent_digest(owner))
            _checkpoint(attempt,payment_link_id=identifier,order_template_id=order,checkout_url=url,state='ready' if allowed else 'pending',processing_lease=None,lease_until=None)
        return status(attempt)
    except Exception:
        try:_checkpoint(attempt,state='pending',processing_lease=None,lease_until=None)
        except CheckoutBusy:pass
        raise


def _validate_template(order,attempt,*,expected_id=None):
    expected=expected_id or attempt.order_template_id
    if (order.get('id')!=expected or order.get('location_id')!=attempt.location_id
            or order.get('reference_id')!=str(attempt.pk)
            or order.get('metadata',{}).get('kingdom_kids_attempt')!=str(attempt.pk)):
        raise CheckoutRejected('The canonical subscription template does not belong to this checkout.')
    lines=order.get('line_items',[])
    if (len(lines)!=1 or lines[0].get('quantity')!='1'
            or lines[0].get('base_price_money')!={'amount':attempt.amount_minor,'currency':'USD'}
            or order.get('total_money')!={'amount':attempt.amount_minor,'currency':'USD'}
            or order.get('total_tax_money',{'amount':0,'currency':'USD'})!={'amount':0,'currency':'USD'}
            or order.get('total_tip_money',{'amount':0,'currency':'USD'})!={'amount':0,'currency':'USD'}):
        raise CheckoutRejected('The provider template price differs from the approved checkout.')


def _subscription_identity(sub):
    return {k:sub.get(k) for k in ('id','location_id','plan_variation_id','customer_id','card_id','version','status','created_at','start_date','canceled_date','phases','invoice_ids','monthly_billing_anchor_date','price_override_money','tax_percentage')}


def _validate_subscription(reader,sub,attempt):
    if (sub.get('location_id')!=attempt.location_id or sub.get('plan_variation_id')!=attempt.variation_id
            or type(sub.get('version')) is not int or sub['version']<0
            or sub.get('monthly_billing_anchor_date') is not None
            or sub.get('price_override_money') not in (None,{'amount':attempt.amount_minor,'currency':'USD'})
            or sub.get('tax_percentage') not in (None,'0','0.0')
            or sub.get('status') not in {'PENDING','ACTIVE','CANCELED','PAUSED','DEACTIVATED','COMPLETED'}):
        raise CheckoutRejected('The canonical subscription does not match this owned recurring contract.')
    provider_identifier(sub.get('id'),192);provider_identifier(sub.get('customer_id'),192);provider_identifier(sub.get('card_id'),192)
    phases=sub.get('phases',[])
    if len(phases)!=1 or phases[0].get('ordinal')!=0 or phases[0].get('order_template_id')!=attempt.order_template_id:
        raise CheckoutRejected('The immutable checkout-template subscription bridge is missing or ambiguous.')
    _validate_template(reader.retrieve_order(attempt.order_template_id),attempt)
    if attempt.subscription_id and (sub['id']!=attempt.subscription_id or sub['customer_id']!=attempt.customer_id):
        raise CheckoutRejected('The checkout already belongs to another canonical subscription.')
    return sub


def _find_subscription(reader,attempt,hint=None):
    if attempt.subscription_id or hint:
        return _validate_subscription(reader,reader.retrieve_subscription(attempt.subscription_id or hint),attempt)
    found={};cursor=None;seen=set()
    for _ in range(3):
        result=reader.search_subscriptions(location_id=attempt.location_id,cursor=cursor)
        rows=result.get('subscriptions',[])
        if not isinstance(rows,list) or len(rows)>100:raise CheckoutRejected('Unexpected subscription search page.')
        for sub in rows:
            if any(p.get('order_template_id')==attempt.order_template_id for p in sub.get('phases',[]) if isinstance(p,dict)):
                found[sub['id']]=sub
        cursor=result.get('cursor')
        if not cursor:break
        if not isinstance(cursor,str) or len(cursor)>4096 or cursor in seen:raise CheckoutRejected('Unqualified subscription search cursor.')
        seen.add(cursor)
    else:raise CheckoutBusy('Subscription discovery exceeded its bounded search; wait for its signed event.')
    if not found:raise CheckoutBusy('Square has not yet exposed the matching subscription; keep this checkout.')
    if len(found)!=1:raise CheckoutRejected('Multiple subscriptions match one owned checkout; review is required.')
    return _validate_subscription(reader,reader.retrieve_subscription(next(iter(found))),attempt)


def _collect_invoice(reader,attempt,sub,invoice_id,zone):
    invoice=reader.retrieve_invoice(invoice_id)
    if (invoice.get('id')!=invoice_id or invoice.get('subscription_id')!=sub['id'] or invoice.get('location_id')!=attempt.location_id
            or invoice.get('primary_recipient',{}).get('customer_id')!=sub['customer_id']
            or invoice_id not in sub.get('invoice_ids',[])):
        raise CheckoutRejected('This invoice does not belong to the exact hosted subscription.')
    order=reader.retrieve_order(provider_identifier(invoice.get('order_id'),192))
    if order.get('location_id')!=attempt.location_id or order.get('total_money')!={'amount':attempt.amount_minor,'currency':'USD'}:
        raise CheckoutRejected('The recurring invoice order differs from its approved amount/location.')
    tenders=order.get('tenders',[])
    if not isinstance(tenders,list) or len(tenders)>1:raise CheckoutRejected('Unqualified invoice tender count.')
    observations=[]
    for tender in tenders:
        payment_id=provider_identifier(tender.get('payment_id') or tender.get('id'),192)
        payment=reader.retrieve_payment(payment_id)
        if payment.get('customer_id')!=sub['customer_id']:
            raise CheckoutRejected('Canonical payment does not match the subscribing customer.')
        observed=_payment_snapshot(payment,reader,order['id'],attempt.location_id)
        if observed['amount_minor']!=attempt.amount_minor:raise CheckoutRejected('Canonical subscription payment amount changed.')
        captured=None
        if observed['status']=='COMPLETED' and observed['source_type']=='CARD':
            details=payment.get('card_details',{});timeline=details.get('card_payment_timeline',{})
            captured=_timestamp(timeline.get('captured_at'))
            if (details.get('status')!='CAPTURED' or captured>timezone.now()+timedelta(minutes=1)
                    or captured<attempt.created_at-timedelta(minutes=1)):
                raise CheckoutRejected('Canonical card capture chronology is unqualified.')
        observed['captured_at']=captured.isoformat() if captured else None
        observed['payment_canonical_sha256']=fingerprint(_hosted_payment_identity(payment))
        latest=reader.retrieve_payment(payment_id)
        if fingerprint(_hosted_payment_identity(latest))!=observed['payment_canonical_sha256']:
            raise SquareClientError('Canonical payment changed during verification.')
        observations.append(observed)
    again=reader.retrieve_invoice(invoice_id);order_again=reader.retrieve_order(order['id'])
    invoice_keys=('id','version','location_id','subscription_id','order_id','status','updated_at','primary_recipient')
    order_keys=('id','version','location_id','tenders','total_money')
    if (fingerprint({k:again.get(k) for k in invoice_keys})!=fingerprint({k:invoice.get(k) for k in invoice_keys})
            or fingerprint({k:order_again.get(k) for k in order_keys})!=fingerprint({k:order.get(k) for k in order_keys})):
        raise SquareClientError('Canonical invoice or order changed during verification.')
    completed=[p for p in observations if p['status']=='COMPLETED' and p['source_type']=='CARD']
    if len(completed)>1:raise CheckoutRejected('Multiple full payments require review rather than duplicate access.')
    if not completed:return None
    if invoice.get('status') not in {'PAID','REFUNDED','PARTIALLY_REFUNDED'}:
        raise CheckoutBusy('Invoice settlement is not yet canonically complete.')
    value=completed[0]
    value.update(invoice_id=invoice_id,order_id=order['id'],subscription_id=sub['id'],customer_id=sub['customer_id'],
        merchant_id=attempt.merchant_id,location_id=attempt.location_id,policy_sha256=attempt.policy_sha256,
        environment=attempt.environment,timezone=zone,coverage_rule=hosted_plan(attempt.billing_period).coverage_rule)
    return value


def _valid_proof(proof,attempt):
    try:
        evidence=proof.payment_evidence;plan=hosted_plan(attempt.billing_period)
        return bool(proof.environment==attempt.environment and proof.status=='COMPLETED' and proof.refunded_minor==0
            and proof.captured_at and proof.valid_until==coverage_end(proof.captured_at,plan.coverage_rule,evidence['timezone'])
            and proof.amount_minor==plan.amount and attempt.policy_sha256==plan.policy_sha256
            and evidence['id']==proof.payment_id and evidence['invoice_id']==proof.invoice_id and evidence['order_id']==proof.order_id
            and evidence['subscription_id']==attempt.subscription_id and evidence['customer_id']==attempt.customer_id
            and evidence['environment']==attempt.environment and evidence['policy_sha256']==attempt.policy_sha256
            and evidence['coverage_rule']==plan.coverage_rule and evidence['merchant_id']==attempt.merchant_id and evidence['location_id']==attempt.location_id
            and evidence['status']=='COMPLETED' and evidence['source_type']=='CARD'
            and evidence['amount_minor']==plan.amount and evidence['refunded_minor']==0
            and evidence['captured_at']==proof.captured_at.isoformat() and fingerprint(evidence)==proof.canonical_sha256)
    except (KeyError,ValueError,TypeError,AttributeError,ZoneInfoNotFoundError):return False


def valid_entitlement(row,parent):
    try:identifier=UUID(row.source_reference.removeprefix('square-hosted:'))
    except (ValueError,AttributeError):return False
    proof=SquareHostedPaymentProof.objects.select_related('attempt').filter(pk=identifier,environment=row.environment,
        attempt__environment=row.environment,attempt__parent=parent,attempt__merchant_id=row.provider_account_id).first()
    return bool(proof and not proof.revoked_at and proof.captured_at==row.valid_from and proof.valid_until==row.valid_until
        and _valid_proof(proof,proof.attempt))


def _settlement_closed(attempt,sub,zone):
    """Stopping future renewal does not resolve an in-flight current invoice."""
    ids=sub.get('invoice_ids',[])
    effective=(sub.get('status') in {'CANCELED','COMPLETED','DEACTIVATED'}
        or bool(sub.get('canceled_date') and date.fromisoformat(sub['canceled_date'])<=timezone.now().astimezone(ZoneInfo(zone)).date()))
    if not effective or not ids:return False
    settled=set(attempt.payment_proofs.filter(environment=attempt.environment,status='COMPLETED',invoice_id__in=ids).values_list('invoice_id',flat=True))
    return set(ids)==settled


def _commit(attempt,sub,observations,*,invoice_cursor=None,zone='UTC'):
    with transaction.atomic():
        parent=get_user_model().objects.select_for_update().filter(pk=attempt.parent_id).first()
        current=SquareHostedAttempt.objects.select_for_update().get(pk=attempt.pk,environment=attempt.environment)
        if current.processing_lease!=attempt.processing_lease or not current.lease_until or current.lease_until<=timezone.now():raise CheckoutBusy('Hosted processing ownership changed.')
        if current.subscription_id and (current.subscription_id!=sub['id'] or current.customer_id!=sub['customer_id']):
            raise CheckoutRejected('A hosted subscription cannot move between attempts or customers.')
        digest=fingerprint(_subscription_identity(sub))
        if (sub['version']<current.subscription_version or sub['version']==current.subscription_version and current.subscription_sha256 and digest!=current.subscription_sha256):
            raise CheckoutRejected('Older or conflicting subscription facts cannot replace ownership.')
        current.subscription_id=sub['id'];current.customer_id=sub['customer_id'];current.subscription_version=sub['version']
        current.subscription_sha256=digest;current.provider_status=sub['status']
        if current.canceled_date and str(current.canceled_date)!=sub.get('canceled_date'):
            raise CheckoutRejected('Verified cancellation cannot be silently removed or changed.')
        current.canceled_date=sub.get('canceled_date')
        current.renewals_enabled=sub['status']=='ACTIVE' and not sub.get('canceled_date')
        for evidence in observations:
            old=SquareHostedPaymentProof.objects.select_for_update().filter(environment=current.environment,payment_id=evidence['id']).first()
            if old and (old.attempt_id!=current.pk or not _not_older_payments([evidence],[old.payment_evidence])):
                raise CheckoutRejected('Payment evidence cannot move owner or regress.')
            captured=_timestamp(evidence['captured_at']);end=coverage_end(captured,hosted_plan(current.billing_period).coverage_rule,evidence['timezone'])
            proof=old or SquareHostedPaymentProof(attempt=current,environment=current.environment,invoice_id=evidence['invoice_id'],
                payment_id=evidence['id'],order_id=evidence['order_id'],amount_minor=evidence['amount_minor'],payment_updated_at=_timestamp(evidence['updated_at']))
            proof.refunded_minor=evidence['refunded_minor'];proof.status=evidence['status'];proof.captured_at=captured;proof.valid_until=end
            proof.payment_updated_at=_timestamp(evidence['updated_at']);proof.payment_evidence=evidence;proof.canonical_sha256=fingerprint(evidence)
            if proof.refunded_minor==proof.amount_minor:proof.revoked_at=proof.revoked_at or timezone.now()
            proof.save()
            grants=ParentContentEntitlement.objects.filter(provider='square',environment=current.environment,
                provider_account_id=current.merchant_id,source_reference=source_reference(proof),feature_code=ALL_CONTENT_FEATURE)
            if proof.revoked_at:grants.filter(revoked_at__isnull=True).update(revoked_at=proof.revoked_at)
            elif proof.refunded_minor==0 and _eligible(parent) and _valid_proof(proof,current):
                grant=grants.first()
                if grant and (grant.parent_id!=parent.pk or grant.valid_from!=captured or grant.valid_until!=end):raise CheckoutRejected('A hosted paid proof cannot move parent or extend coverage.')
                if grant is None:ParentContentEntitlement.objects.create(parent=parent,provider='square',environment=current.environment,
                    provider_account_id=current.merchant_id,source_reference=source_reference(proof),feature_code=ALL_CONTENT_FEATURE,
                    valid_from=captured,valid_until=end,payment_verified_at=timezone.now())
        current.state='paid' if current.payment_proofs.filter(status='COMPLETED',refunded_minor=0,revoked_at__isnull=True,valid_until__gt=timezone.now()).exists() else 'pending'
        if sub['status'] in {'CANCELED','COMPLETED','DEACTIVATED'}:current.renewals_enabled=False
        if current.cancel_requested_at or sub.get('canceled_date') or not current.renewals_enabled:
            current.is_open=not _settlement_closed(current,sub,zone)
        if invoice_cursor:current.reconciliation_invoice_cursor=invoice_cursor
        current.processing_lease=None;current.lease_until=None;current.save()
    return current


@sensitive_variables()
def reconcile(*,parent,attempt_id,client=None,subscription_hint=None,invoice_hint=None,reader=None):
    attempt,config=_claim(attempt_id,parent=parent)
    try:
        client=client or hosted_client(environment=attempt.environment,readonly=True);assert_client_environment(client,environment=attempt.environment)
        reader=reader or HostedReader(client,timezone.now()+timedelta(seconds=8))
        zone=_validate_location(reader,config)
        try:sub=_find_subscription(reader,attempt,hint=subscription_hint)
        except CheckoutBusy:
            # API-created links are single-use. A canonical still-owned link
            # can be explicitly reopened without a second link/key/payment POST.
            # Its availability is never evidence of unpaid or paid settlement.
            if attempt.subscription_id or not attempt.payment_link_id or subscription_hint:raise
            link=reader.retrieve_payment_link(attempt.payment_link_id)
            if (link.get('id')!=attempt.payment_link_id or link.get('order_id')!=attempt.order_template_id
                    or approved_provider_url(link.get('url'),environment=attempt.environment)!=attempt.checkout_url):
                raise CheckoutRejected('The resumable provider link changed ownership.')
            _validate_template(reader.retrieve_order(attempt.order_template_id),attempt)
            with transaction.atomic():
                owner=get_user_model().objects.select_for_update().filter(pk=attempt.parent_id).first()
                current=SquareHostedAttempt.objects.select_for_update().get(pk=attempt.pk,environment=attempt.environment)
                if (not _eligible(owner) or current.cancel_requested_at or not current.is_open
                        or not constant_time_compare(current.parent_auth_sha256,_parent_digest(owner))
                        or verified_content_access_until(owner,environment=attempt.environment) is not None):
                    raise CheckoutBusy('This checkout must remain pending until ownership and payment are checked.')
                _checkpoint(attempt,state='ready',processing_lease=None,lease_until=None)
            return status(attempt)
        validate_variation(reader,identifier=attempt.variation_id,period=attempt.billing_period)
        ids=sub.get('invoice_ids',[])
        if not isinstance(ids,list) or len(ids)>1000 or len(set(ids))!=len(ids):raise CheckoutRejected('Invoice history is unqualified.')
        # One invoice per pass bounds provider work even when refunds exist.
        # A signed hint targets its exact old proof; ordinary reads rotate a
        # durable cursor so unpaid/older rows cannot starve the remaining chain.
        if invoice_hint:
            selected=[provider_identifier(invoice_hint,192)]
            if invoice_hint not in ids:raise CheckoutRejected('The invoice hint is outside this exact subscription.')
        elif ids:
            cursor=attempt.reconciliation_invoice_cursor
            index=(ids.index(cursor)+1)%len(ids) if cursor in ids else 0
            selected=[provider_identifier(ids[index],192)]
        else:selected=[]
        observations=[]
        for identifier in selected:
            observed=_collect_invoice(reader,attempt,sub,provider_identifier(identifier,192),zone)
            if observed:observations.append(observed)
        again=reader.retrieve_subscription(sub['id'])
        if fingerprint(_subscription_identity(again))!=fingerprint(_subscription_identity(sub)):raise SquareClientError('Subscription changed during verification.')
        return status(_commit(attempt,sub,observations,invoice_cursor=selected[0] if selected else None,zone=zone))
    except Exception:
        try:_checkpoint(attempt,state='pending',processing_lease=None,lease_until=None)
        except CheckoutBusy:pass
        raise


def enqueue_parent_cancellations(parent):
    """Same transaction as account deletion; no provider I/O or parent cascade."""
    pending=[]
    for row in SquareHostedAttempt.objects.select_for_update().filter(parent=parent):
        if row.is_open or row.payment_link_id or row.subscription_id:
            row.cancel_requested_at=row.cancel_requested_at or timezone.now()
            row.authorization_sha256='';row.parent_auth_sha256='';row.authorization_expires_at=timezone.now()
            row.save(update_fields=('cancel_requested_at','authorization_sha256','parent_auth_sha256','authorization_expires_at','updated_at'))
            job,_=SquareHostedCancellation.objects.get_or_create(attempt=row,environment=row.environment)
            if job.state!='verified':pending.append(job.pk)
    if pending:
        # No provider request occurs while account/family deletion locks are held.
        # The retained outbox survives a timeout; later signed events also drain it.
        transaction.on_commit(lambda:_try_deleted_parent_cancellation(pending[0]))


def _try_deleted_parent_cancellation(job_id):
    try:process_cancellation(job_id=job_id)
    except Exception:pass  # Retained pending; never log provider bodies/credentials.


@sensitive_variables()
def cancel(*,parent,attempt_id,password,client=None):
    env=active_billing_environment()
    with transaction.atomic():
        owner=get_user_model().objects.select_for_update().get(pk=parent.pk);_check_hosted_parent(owner,password)
        row=SquareHostedAttempt.objects.select_for_update().get(pk=attempt_id,parent=owner,environment=env)
        row.cancel_requested_at=row.cancel_requested_at or timezone.now();row.save(update_fields=('cancel_requested_at','updated_at'))
        job,_=SquareHostedCancellation.objects.get_or_create(attempt=row,environment=env)
    process_cancellation(job_id=job.pk,client=client)
    row.refresh_from_db();return status(row)


@sensitive_variables()
def process_cancellation(*,job_id,client=None,reader=None):
    from .client import SquareResourceNotFound
    job=SquareHostedCancellation.objects.select_related('attempt').get(pk=job_id,environment=active_billing_environment())
    attempt,config=_claim(job.attempt_id)
    try:
        client=client or hosted_client(environment=attempt.environment,readonly=True);assert_client_environment(client,environment=attempt.environment)
        reader=reader or HostedReader(client,timezone.now()+timedelta(seconds=8))
        zone=_validate_location(reader,config)
        if attempt.payment_link_id:
            try:link=reader.retrieve_payment_link(attempt.payment_link_id)
            except SquareResourceNotFound:link=None
            if link is not None:
                if link.get('id')!=attempt.payment_link_id or link.get('order_id')!=attempt.order_template_id:
                    raise CheckoutRejected('Cancellation link does not match its owned template.')
                _validate_template(reader.retrieve_order(attempt.order_template_id),attempt)
                reader.ensure_budget();client.delete_payment_link(attempt.payment_link_id)
                try:reader.retrieve_payment_link(attempt.payment_link_id)
                except SquareResourceNotFound:pass
                else:raise CheckoutBusy('The owned checkout link has not yet been revoked.')
        if not attempt.subscription_id:
            if not attempt.order_template_id:
                if attempt.request_body:
                    raise CheckoutBusy('A previously sent checkout creation still requires canonical ownership recovery.')
                _checkpoint(attempt,state='canceled',is_open=False,renewals_enabled=False,processing_lease=None,lease_until=None)
                SquareHostedCancellation.objects.filter(pk=job.pk).update(state='verified',verified_at=timezone.now())
                return 'verified'
            # Absence in a bounded search is not payment failure. Retain this
            # intent/outbox; a late signed subscription event can bind/cancel it.
            sub=_find_subscription(reader,attempt)
            _checkpoint(attempt,subscription_id=sub['id'],customer_id=sub['customer_id'])
        else:sub=_validate_subscription(reader,reader.retrieve_subscription(attempt.subscription_id),attempt)
        terminal=sub.get('status') in {'CANCELED','COMPLETED','DEACTIVATED'}
        if not terminal and not sub.get('canceled_date'):
            # Persist before sending. A lost cancel response gets canonical GETs
            # only on later runs; never an automatic duplicate financial write.
            with transaction.atomic():
                locked=SquareHostedCancellation.objects.select_for_update().get(pk=job.pk)
                if locked.cancel_dispatched_at is not None:raise CheckoutBusy('Cancellation is awaiting canonical proof.')
                locked.cancel_dispatched_at=timezone.now();locked.save(update_fields=('cancel_dispatched_at',))
            reader.ensure_budget();client.cancel_subscription(sub['id'])
        sub=_validate_subscription(reader,reader.retrieve_subscription(sub['id']),attempt)
        if not sub.get('canceled_date') and sub.get('status') not in {'CANCELED','COMPLETED','DEACTIVATED'}:
            raise CheckoutBusy('Future renewal cancellation is not yet canonically verified.')
        if sub['version']<attempt.subscription_version:
            raise CheckoutRejected('Older subscription facts cannot undo a verified cancellation.')
        closed=_settlement_closed(attempt,sub,zone)
        paid_now=status(attempt)['payment_confirmed']
        _checkpoint(attempt,state='canceled' if closed else 'paid' if paid_now else 'pending',renewals_enabled=False,canceled_date=sub.get('canceled_date'),provider_status=sub['status'],
            subscription_version=sub['version'],subscription_sha256=fingerprint(_subscription_identity(sub)),
            is_open=not closed,processing_lease=None,lease_until=None)
        SquareHostedCancellation.objects.filter(pk=job.pk).update(state='verified',verified_at=timezone.now())
        return 'verified'
    except Exception:
        try:_checkpoint(attempt,state='pending',processing_lease=None,lease_until=None)
        except CheckoutBusy:pass
        raise


def _hosted_payment_identity(payment):
    details=payment.get('card_details',{})
    return {**_payment_identity(payment),'card_status':details.get('status'),
        'card_payment_timeline':details.get('card_payment_timeline')}


class HostedReader(CanonicalReader):
    """A request consumes one shared bounded read budget, including event hints."""
    def ensure_budget(self):
        if self.calls>=24 or timezone.now()>=self.deadline:
            raise SquareClientError('Hosted canonical read budget exhausted.')
    def __getattr__(self,name):
        call=super().__getattr__(name)
        def bounded(*args,**kwargs):
            self.ensure_budget()
            return call(*args,**kwargs)
        return bounded


def capability(parent):
    env=active_billing_environment()
    result={'state':'unavailable','reason_code':'not_configured','provider':'square_hosted',
        'fresh_parent_auth_required':False,'handoff_available':False,'management_handoff_available':False,
        'management_state':'unavailable','management_reason_code':'no_owned_purchase',
        'management_recovery':None,'controlled_parent_eligible':False}
    if not _eligible(parent):return result
    owned=SquareHostedAttempt.objects.filter(parent=parent,environment=env).exists()
    if owned:result.update(management_state='available',management_reason_code='owned_purchase')
    try:
        hosted_configuration(environment=env)
        result.update(state='available',reason_code='production_hosted' if env=='production' else 'sandbox_hosted')
    except (SquareDisabled,SquareConfigurationError,ValueError):pass
    return result
