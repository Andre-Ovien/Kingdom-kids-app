"""Exact app-contract terms paid by Square Payments, never automatic Subscriptions.

Coverage is our immutable contract authority. Square Payment.reference_id binds
canonical money to exactly that predeclared UUID, not to guessed invoice dates.
All real transport and financial/receipt rollout remain explicitly disabled.
"""
from datetime import date, datetime, time, timedelta, timezone as datetime_timezone
from uuid import UUID, uuid4
from zoneinfo import ZoneInfo

from django.conf import settings
from django.db import transaction
from django.db.models import Q
from django.utils import timezone
from django.views.decorators.debug import sensitive_variables

from .checkout import (CheckoutBusy, CheckoutConflict, CheckoutRejected, _check_parent, acquire_intent,
                       checkpoint, fingerprint, public_terms, release_intent, reserve_checkout)
from .client import SquareClientError
from .configuration import SquareDisabled, checkout_configuration, configured_client, provider_identifier
from .models import (ParentContentEntitlement, SquareBillingTerm, SquareCheckoutIntent,
                     SquareContentAgreement, SquareSubscriptionIdentity, SquarePaymentCardBinding)
from .plans import ALL_CONTENT_FEATURE
from .term_plans import content_term_plan, term_plan_for_policy, ACTIVE_POLICY_IDS
from .coverage import coverage_end, coverage_hash
from .reconciliation import CanonicalReader, _not_older_payments, _payment_identity, _payment_snapshot


TERM_DISCLOSURE_VERSION = 'usd999-30days-capture-v2'


def term_configuration(*, readonly=False):
    if readonly and not getattr(settings, 'SQUARE_SANDBOX_TERM_RECONCILIATION_ENABLED', False):
        raise SquareDisabled('Square term reconciliation is disabled.')
    if readonly:
        from .configuration import square_configuration, SquareCheckoutConfiguration
        return SquareCheckoutConfiguration(square_configuration(),
            provider_identifier(settings.SQUARE_SANDBOX_LOCATION_ID, 192), '')
    return checkout_configuration(terms=True)


def next_anchor(instant, billing_timezone):
    """Strictly next local28th midnight; calendar arithmetic, not30days."""
    zone = ZoneInfo(billing_timezone)
    local = instant.astimezone(zone)
    year, month = local.year, local.month
    anchor = datetime.combine(date(year, month, 28), time.min, zone)
    if local >= anchor:
        year, month = (year + 1, 1) if month == 12 else (year, month + 1)
        anchor = datetime.combine(date(year, month, 28), time.min, zone)
    return anchor.astimezone(datetime_timezone.utc)


def verify_payment_location(client, config, *, require_active=True):
    merchant = client.retrieve_merchant(config.provider.merchant_id)
    location = client.retrieve_location(config.location_id)
    if (merchant.get('id') != config.provider.merchant_id or merchant.get('country') != 'US'
            or location.get('id') != config.location_id or location.get('country') != 'US'
            or location.get('currency') != 'USD' or (require_active and location.get('status') != 'ACTIVE')):
        raise CheckoutRejected('A canonical US/USD seller location is required.')
    zone = location.get('timezone')
    if not isinstance(zone, str) or len(zone) > 64:
        raise CheckoutRejected('A canonical IANA billing timezone is required.')
    ZoneInfo(zone)
    return zone


def next_term_anchor(instant, billing_timezone, billing_period):
    if billing_period == 'monthly': return next_anchor(instant, billing_timezone)
    if billing_period != 'yearly': raise CheckoutRejected('Unsupported reviewed billing period.')
    zone = ZoneInfo(billing_timezone)
    local = instant.astimezone(zone)
    return datetime(local.year + 1, local.month, 28, tzinfo=zone).astimezone(datetime_timezone.utc)


def term_disclosure(billing_timezone, *, billing_period='monthly', at=None):
    ZoneInfo(billing_timezone)
    try: plan = content_term_plan(billing_period)
    except ValueError: raise CheckoutRejected('Unsupported reviewed billing period.') from None
    if billing_period == 'monthly':
        duration = '30 consecutive elapsed days (720 hours) beginning at the successful payment capture'
        renewal = 'The next charge is authorized only after that full 30-day paid period ends.'
    else:
        duration = '12 calendar months beginning at the successful payment capture'
        renewal = ('The next charge is authorized only at the same local anniversary one year later. '
            'February 29 renews on February 28. A nonexistent anniversary wall time moves forward by its timezone gap; '
            'an ambiguous anniversary uses the later occurrence.')
    data = {'policy_id':plan.policy_id,'policy_sha256':plan.policy_sha256,'billing_period':billing_period,
        'cadence':plan.cadence,'amount_minor':plan.amount_minor,'currency':'USD',
        'coverage_rule':plan.coverage_rule,'disclosure_version':plan.disclosure_version,
        'billing_controller':'app_owned_terms','billing_timezone':billing_timezone,
        'coverage_start':'canonical_successful_payment_capture','first_renewal_at':None,
        'first_renewal_rule':plan.coverage_rule,'can_prorate':False,'free_period':False,
        'environment':'sandbox','country':'US','purchasable':True,
        'web_tokenization':{'intent':'CHARGE_AND_STORE','amount':plan.amount_display,
            'currencyCode':'USD','customerInitiated':True,'sellerKeyedIn':False},
        'disclosure':(f'You authorize Square to save your tokenized card and charge ${plan.amount_display} USD immediately for '
            + duration + '. ' + renewal + f' Annual calendar anniversaries use {billing_timezone}. '
            'The exact paid start and renewal timestamp are confirmed only after capture. '
            'Renewals charge the same full amount for a fresh paid period. There is no free period or proration. '
            'All stories and games are included. You can stop future renewals; already-paid access keeps its original end. '
            'Account deletion stops future app-scheduled payments; a previously authorized in-flight payment can still complete '
            'and must be reconciled.')}
    if billing_period == 'yearly': data.update(monthly_comparison_minor=999,annual_savings_minor=1998)
    data['disclosure_sha256'] = fingerprint(data)
    return data


@sensitive_variables()
def reserve_term_checkout(*, parent, password, disclosure_version, disclosure_sha256, accepted,
                          billing_period='monthly', client=None):
    config = term_configuration()
    client = client or configured_client()
    zone = verify_payment_location(client, config)
    terms = term_disclosure(zone, billing_period=billing_period)
    if disclosure_version != terms['disclosure_version'] or disclosure_sha256 != terms['disclosure_sha256']:
        raise CheckoutRejected('Accept the current timezone-specific billing disclosure.')
    return reserve_checkout(parent=parent, password=password, disclosure_version=disclosure_version,
        accepted=accepted, mode='payments', billing_timezone=zone, disclosure_sha256=disclosure_sha256,
        billing_period=billing_period)


def term_reference(term_id):
    return 'square-term:' + str(term_id)


def frozen_term_hash(term, agreement):
    data = {'term_id':str(term.pk),'agreement':str(agreement.pk),'policy':agreement.policy_sha256,
        'merchant':agreement.merchant_id,'location':term.location_id,'customer':term.customer_id,'card':term.card_id,
        'amount':term.amount_minor,'currency':term.currency,'timezone':agreement.billing_timezone,
        'buyer_present':term.buyer_present,'verification_sha256':term.verification_sha256,
        'provider_key':str(term.provider_idempotency_key)}
    if term.coverage_rule:
        data.update(coverage_rule=term.coverage_rule,request_not_before=term.request_not_before.isoformat())
    else:
        # Preserve the exact historical request hash; never rewrite old coverage.
        data.update(valid_from=term.valid_from.isoformat(),valid_until=term.valid_until.isoformat())
    if term.cadence != 'MONTHLY': data['cadence'] = term.cadence
    if term.payment_source_mode != 'saved_card': data['payment_source_mode'] = term.payment_source_mode
    return fingerprint(data)


def _new_term(agreement, start, *, buyer_present=False, verification_token=None, charge_source_id=None):
    plan = term_plan_for_policy(agreement.policy_id)
    if not plan.purchasable: raise CheckoutRejected('Historical billing policies cannot create new payment terms.')
    card_id = agreement.card_id
    if not buyer_present and not card_id:
        binding = SquarePaymentCardBinding.objects.filter(agreement=agreement).first()
        if binding is None: raise CheckoutRejected('A verified payment-backed card is required before renewal.')
        card_id = binding.card_id
    term = SquareBillingTerm(agreement=agreement,request_not_before=start,coverage_rule=plan.coverage_rule,
        amount_minor=plan.amount_minor,currency='USD',cadence=plan.cadence,customer_id=agreement.customer_id,
        card_id=card_id,location_id=agreement.location_id,buyer_present=buyer_present,
        payment_source_mode='web_charge_and_store' if charge_source_id is not None else 'saved_card',
        verification_sha256=(fingerprint({'charge_source_id':charge_source_id}) if charge_source_id is not None
            else fingerprint({'token':verification_token}) if verification_token else ''))
    term.request_sha256 = frozen_term_hash(term,agreement)
    term.save(force_insert=True)
    return term


@sensitive_variables()
def confirm_term_checkout(*, parent, intent_id, password, source_id=None, verification_token=None,
                           postal_code='94103', charge_source_id=None, client=None, prepare_only=False):
    config = term_configuration(); client = client or configured_client()
    intent, _ = acquire_intent(parent=parent, intent_id=intent_id, password=password, terms=True)
    try:
        if intent.checkout_mode != 'payments' or intent.subscription_id or intent.payment_link_id:
            raise CheckoutConflict('Automatic Square subscriptions cannot run alongside app-owned billing.')
        plan = term_plan_for_policy(intent.policy_id)
        if not plan.purchasable:
            raise CheckoutRejected('Historical billing policies are read-only; fresh current consent is required.')
        modern = charge_source_id is not None
        prior = SquareBillingTerm.objects.filter(agreement__intent_reference=intent.pk, buyer_present=True).order_by('created_at','pk').first()
        if prior is not None and prior.payment_source_mode == 'web_charge_and_store': modern = True
        if modern and (prepare_only or source_id is not None or verification_token is not None or intent.card_id):
            raise CheckoutRejected('Modern charge-and-store cannot mix a prepared card or legacy proof.')
        if charge_source_id is not None:
            if (not isinstance(charge_source_id, str) or not charge_source_id.startswith('cnon:')
                    or not 6 <= len(charge_source_id) <= 16_384
                    or any(ord(c) <= 32 or ord(c) == 127 for c in charge_source_id)):
                raise CheckoutRejected('A fresh CHARGE_AND_STORE Sandbox token is required.')
            try: charge_source_id.encode('utf-8')
            except UnicodeEncodeError:
                raise CheckoutRejected('A fresh CHARGE_AND_STORE Sandbox token is required.') from None
        if not modern and not prepare_only and not intent.card_id:
            raise CheckoutRejected('Prepare the tokenized card and complete buyer verification before payment.')
        if verification_token is not None:
            if (not isinstance(verification_token, str) or not 1 <= len(verification_token) <= 16_384
                    or any(ord(c) <= 32 or ord(c) == 127 for c in verification_token)):
                raise CheckoutRejected('Invalid buyer verification token.')
            try: verification_token.encode('utf-8')
            except UnicodeEncodeError:
                raise CheckoutRejected('Invalid buyer verification token.') from None
        if (SquareSubscriptionIdentity.objects.filter(customer__parent=parent).exists()
                or SquareCheckoutIntent.objects.filter(parent=parent).exclude(pk=intent.pk).filter(
                    ~Q(subscription_id='') | ~Q(payment_link_id='')).exists()):
            raise CheckoutConflict('Existing autonomous billing must be verified closed before this billing mode.')
        zone = verify_payment_location(client, config)
        plan = term_plan_for_policy(intent.policy_id)
        quote = term_disclosure(zone, billing_period=plan.billing_period, at=prior.valid_from if prior else None)
        if intent.billing_timezone != zone or intent.disclosure_sha256 != quote['disclosure_sha256']:
            raise CheckoutConflict('The accepted billing timezone or disclosure changed.')
        if modern and not intent.customer_id:
            if timezone.now() - intent.consented_at > timedelta(minutes=10):
                raise CheckoutConflict('Fresh checkout consent is required before payment preparation.')
            customer = client.create_customer(email_address=f'sandbox-{intent.pk.hex}@example.test',
                reference_id=str(intent.pk), idempotency_key=intent.customer_idempotency_key)
            checkpoint(intent, customer_id=customer)
        if not modern and not intent.card_id:
            if (not isinstance(source_id, str) or not source_id.startswith('cnon:')
                    or not 6 <= len(source_id) <= 16_384 or any(ord(c) <= 32 or ord(c) == 127 for c in source_id)):
                raise CheckoutRejected('A tokenized Sandbox card is required.')
            try: source_id.encode('utf-8')
            except UnicodeEncodeError:
                raise CheckoutRejected('A tokenized Sandbox card is required.') from None
            if not isinstance(postal_code, str) or len(postal_code) != 5 or not postal_code.isascii() or not postal_code.isdigit():
                raise CheckoutRejected('A matching five-digit US Sandbox postal code is required.')
            if timezone.now() - intent.consented_at > timedelta(minutes=10):
                raise CheckoutConflict('Fresh checkout consent is required before card preparation.')
            if not intent.customer_id:
                customer = client.create_customer(email_address=f'sandbox-{intent.pk.hex}@example.test',
                    reference_id=str(intent.pk), idempotency_key=intent.customer_idempotency_key)
                checkpoint(intent, customer_id=customer)
            digest = fingerprint({'source': source_id, 'customer': intent.customer_id, 'postal_code': postal_code})
            if intent.card_request_sha256 and digest != intent.card_request_sha256:
                raise CheckoutConflict('The prior card result is uncertain; do not replace its purchase key.')
            checkpoint(intent, card_request_sha256=digest)
            card = client.create_card(customer_id=intent.customer_id, source_id=source_id,
                postal_code=postal_code, idempotency_key=intent.card_idempotency_key)
            checkpoint(intent, card_id=card)
        if prepare_only:
            release_intent(intent, state='card_ready', outcome_code='buyer_charge_verification_required')
            return SquareCheckoutIntent.objects.get(pk=intent.pk)
        # A buyer verification token is transient; only its digest is persisted.
        with transaction.atomic():
            locked_parent = type(parent).objects.select_for_update().get(pk=parent.pk)
            _check_parent(locked_parent, password)
            current = SquareCheckoutIntent.objects.select_for_update().get(pk=intent.pk, parent=locked_parent)
            if current.processing_lease != intent.processing_lease or current.lease_until <= timezone.now():
                raise CheckoutBusy('Checkout ownership changed.')
            agreement = SquareContentAgreement.objects.filter(intent_reference=intent.pk).first()
            if agreement is None:
                if ((verification_token is None and charge_source_id is None)
                        or timezone.now() - current.consented_at > timedelta(minutes=10)):
                    raise CheckoutRejected('A fresh verified buyer charge and current consent are required.')
                now = timezone.now()
                if current.disclosure_sha256 != term_disclosure(zone, billing_period=plan.billing_period, at=now)['disclosure_sha256']:
                    raise CheckoutConflict('The quoted renewal date changed; fresh consent is required.')
                agreement = SquareContentAgreement.objects.create(parent=locked_parent, intent=current,
                    intent_reference=current.pk, merchant_id=current.merchant_id, location_id=current.location_id,
                    customer_id=current.customer_id, card_id=current.card_id, policy_id=current.policy_id,
                    policy_sha256=plan.policy_sha256, disclosure_version=plan.disclosure_version,
                    disclosure_sha256=current.disclosure_sha256, billing_timezone=zone,
                    consented_at=current.consented_at, next_term_start=None)
                term = _new_term(agreement, now, buyer_present=True, verification_token=verification_token,
                    charge_source_id=charge_source_id)
            else:
                if agreement.parent_id != parent.pk or not agreement.renewals_enabled:
                    raise CheckoutConflict('This recurring agreement is stopped; no new payment is authorized.')
                term = agreement.terms.filter(buyer_present=True).order_by('created_at','pk').first()
            current.state = 'term_reserved'; current.save(update_fields=('state', 'updated_at'))
        release_intent(intent)
        if term.payment_source_mode == 'web_charge_and_store' and term.state == 'paid':
            # A paid source term may have ended while card storage was pending.
            # This path can only store/recover its card; it cannot send a payment.
            activate_payment_card(term_id=term.pk, client=client)
        else:
            dispatch_term_payment(term_id=term.pk, client=client, verification_token=verification_token,
                charge_source_id=charge_source_id)
        return SquareCheckoutIntent.objects.get(pk=intent.pk)
    except Exception as error:
        release_intent(intent, state='uncertain', outcome_code='term_payment_reconciliation_required')
        if isinstance(error, (CheckoutRejected, SquareClientError)): raise
        raise SquareClientError('Square term checkout is unavailable or uncertain.') from None


def _claim_term(term_id, *, for_dispatch, for_card_storage=False):
    config = term_configuration(readonly=not (for_dispatch or for_card_storage))
    initial = SquareBillingTerm.objects.select_related('agreement').get(pk=term_id)
    parent_id = initial.agreement.parent_id
    with transaction.atomic():
        parent = None
        if parent_id:
            from django.contrib.auth import get_user_model
            parent = get_user_model().objects.select_for_update().filter(pk=parent_id).first()
        agreement = SquareContentAgreement.objects.select_for_update().get(pk=initial.agreement_id)
        term = SquareBillingTerm.objects.select_for_update().get(pk=term_id)
        plan = term_plan_for_policy(agreement.policy_id)
        if (agreement.merchant_id != config.provider.merchant_id or term.location_id != config.location_id
                or agreement.policy_sha256 != plan.policy_sha256 or term.amount_minor != plan.amount_minor
                or term.cadence != plan.cadence or frozen_term_hash(term, agreement) != term.request_sha256
                or term.payment_source_mode not in {'saved_card', 'web_charge_and_store'}
                or term.coverage_rule != plan.coverage_rule
                or (term.payment_source_mode == 'web_charge_and_store' and (not term.buyer_present or term.card_id))):
            raise CheckoutRejected('Frozen term ownership or contract evidence does not match.')
        now = timezone.now()
        if term.processing_lease and term.lease_until and term.lease_until > now:
            raise CheckoutBusy('This term is already being processed.')
        if (for_dispatch or for_card_storage) and (parent is None or not parent.is_active or not parent.email_verified_at
                or agreement.parent_id != parent_id or not agreement.renewals_enabled
                or not plan.purchasable
                or (for_dispatch and now < term.request_not_before)):
            raise CheckoutRejected('No active current-term recurring authorization exists.')
        if term.coverage_rule and term.captured_at is not None:
            if (term.valid_from != term.captured_at or term.valid_until != coverage_end(
                    term.captured_at,term.coverage_rule,agreement.billing_timezone)
                    or term.coverage_sha256 != coverage_hash(term,agreement)):
                raise CheckoutRejected('Bound paid coverage proof changed.')
        term.processing_lease, term.lease_until = uuid4(), now + timedelta(minutes=5)
        term.save(update_fields=('processing_lease', 'lease_until'))
        return term, agreement


def _term_checkpoint(term, **changes):
    with transaction.atomic():
        current = SquareBillingTerm.objects.select_for_update().get(pk=term.pk)
        if (current.processing_lease != term.processing_lease or not current.lease_until
                or current.lease_until <= timezone.now()):
            raise CheckoutBusy('Term processing ownership changed.')
        for key, value in changes.items(): setattr(current, key, value)
        current.save(update_fields=tuple(changes))
    for key, value in changes.items(): setattr(term, key, value)


def _find_term_payment(reader, term):
    begin = term.created_at - timedelta(minutes=1)
    end = max(term.last_dispatched_at or term.dispatched_at or term.created_at, term.created_at) + timedelta(minutes=15)
    cursor, seen, found = None, set(), {}
    for _page in range(3):
        result = reader.list_payments(location_id=term.location_id, begin_time=begin.isoformat(),
                                      end_time=end.isoformat(), cursor=cursor)
        rows = result.get('payments', [])
        if not isinstance(rows, list) or len(rows) > 100:
            raise CheckoutRejected('Invalid canonical payment page.')
        for payment in rows:
            if isinstance(payment, dict) and payment.get('reference_id') == str(term.pk):
                found[provider_identifier(payment.get('id'), 192)] = payment
        cursor = result.get('cursor')
        if not cursor: break
        if not isinstance(cursor, str) or len(cursor) > 4096 or cursor in seen:
            raise CheckoutRejected('Invalid canonical payment pagination.')
        seen.add(cursor)
    else: raise CheckoutRejected('Payment search budget cannot establish uniqueness.')
    if len(found) > 1: raise CheckoutRejected('Multiple payments reference the same frozen term; review required.')
    return next(iter(found), None)


def _authorize_dispatch(term):
    """Linearization point shared with cancel/delete; no network under locks.

    If cancellation wins this lock no new financial request is authorized. If
    dispatch wins, its recorded in-flight operation can complete and remains
    reconcilable after deletion, but cannot authorize a later recurring term.
    """
    parent_id = SquareContentAgreement.objects.values_list('parent_id', flat=True).get(pk=term.agreement_id)
    from django.contrib.auth import get_user_model
    with transaction.atomic():
        parent = get_user_model().objects.select_for_update().filter(pk=parent_id).first() if parent_id else None
        agreement = SquareContentAgreement.objects.select_for_update().get(pk=term.agreement_id)
        current = SquareBillingTerm.objects.select_for_update().get(pk=term.pk)
        now = timezone.now()
        if (parent is None or agreement.parent_id != parent_id or not parent.is_active
                or not parent.email_verified_at or not agreement.renewals_enabled
                or not term_plan_for_policy(agreement.policy_id).purchasable
                or now < current.request_not_before
                or current.processing_lease != term.processing_lease or current.lease_until <= now
                or frozen_term_hash(current, agreement) != current.request_sha256):
            raise CheckoutRejected('This payment is no longer authorized by an active current contract.')
        from .permissions import verified_paid_coverage_until
        if any(verified_paid_coverage_until(parent,environment=environment,at=now) is not None
                for environment in ('sandbox','production')):
            raise CheckoutRejected('Another verified paid period is still active; no overlapping charge is authorized.')
        if not current.buyer_present and now >= coverage_end(current.request_not_before,current.coverage_rule,agreement.billing_timezone):
            raise CheckoutRejected('Expired missed renewal requests cannot be backcharged.')
        if current.buyer_present and now-agreement.consented_at > timedelta(minutes=10):
            raise CheckoutRejected('The first buyer-present charge requires fresh accepted consent.')
        if current.next_attempt_at and current.next_attempt_at > now:
            raise CheckoutBusy('The same financial intent is waiting for its bounded retry window.')
        if current.dispatch_attempts >= 5:
            raise CheckoutRejected('The bounded payment-attempt budget requires manual review.')
        current.dispatched_at = current.dispatched_at or now
        current.last_dispatched_at, current.dispatch_attempts = now, current.dispatch_attempts + 1
        current.state = 'processing'
        current.save(update_fields=('dispatched_at', 'last_dispatched_at', 'dispatch_attempts', 'state'))
    term.dispatched_at, term.last_dispatched_at, term.dispatch_attempts = current.dispatched_at, now, current.dispatch_attempts


def _capture_value(payment, term):
    if not term.coverage_rule or payment.get('status') != 'COMPLETED' or payment.get('source_type') != 'CARD':
        return None
    details = payment.get('card_details')
    timeline = details.get('card_payment_timeline') if isinstance(details,dict) else None
    if not isinstance(details,dict) or details.get('status') != 'CAPTURED' or not isinstance(timeline,dict):
        raise CheckoutRejected('Completed card coverage requires canonical capture proof.')
    from .reconciliation import _timestamp
    captured = _timestamp(timeline.get('captured_at')).astimezone(datetime_timezone.utc)
    authorized = timeline.get('authorized_at')
    if authorized is not None and _timestamp(authorized) > captured:
        raise CheckoutRejected('Canonical capture predates card authorization.')
    if term.dispatched_at is None:
        raise CheckoutRejected('No recorded financial dispatch authorizes this capture proof.')
    earliest = term.dispatched_at
    if (captured > timezone.now()+timedelta(minutes=1) or captured < earliest-timedelta(minutes=1)
            or (not term.buyer_present and captured < term.request_not_before)):
        raise CheckoutRejected('Canonical capture chronology is inconsistent with this payment request.')
    return captured


def _term_payment_identity(payment, term):
    identity = _payment_identity(payment)
    if term.coverage_rule:
        captured = _capture_value(payment,term)
        identity['coverage_captured_at'] = captured.isoformat() if captured else None
    return identity


def _collect_term_payment(reader, term, payment_id):
    payment = reader.retrieve_payment(payment_id)
    if (payment.get('reference_id') != str(term.pk) or payment.get('customer_id') != term.customer_id
            or payment.get('location_id') != term.location_id):
        raise CheckoutRejected('Payment does not belong to this exact frozen parent term.')
    if term.payment_id and payment.get('id') != term.payment_id:
        raise CheckoutRejected('The term already has another bound payment.')
    order_id = payment.get('order_id')
    if order_id is not None: provider_identifier(order_id, 192)
    observed = _payment_snapshot(payment, reader, order_id, term.location_id)
    if term.coverage_rule:
        captured = _capture_value(payment,term)
        observed['captured_at'] = captured.isoformat() if captured else None
        observed['payment_canonical_sha256'] = fingerprint(_term_payment_identity(payment,term))
    if observed['amount_minor'] != term.amount_minor:
        raise CheckoutRejected('Payment amount differs from the confirmed term price.')
    latest = reader.retrieve_payment(payment_id)
    if fingerprint(_term_payment_identity(latest,term)) != observed['payment_canonical_sha256']:
        raise SquareClientError('Canonical payment changed during verification.')
    for refund in observed['refunds']:
        latest_refund = reader.retrieve_refund(refund['id'])
        if (latest_refund.get('payment_id') != payment_id or latest_refund.get('location_id') != term.location_id
                or latest_refund.get('status') != refund['status'] or latest_refund.get('updated_at') != refund['updated_at']
                or latest_refund.get('amount_money') != {'amount': refund['amount_minor'], 'currency': 'USD'}):
            raise SquareClientError('Canonical refund changed during verification.')
    return observed, order_id or ''


def _commit_payment(term, observed, order_id):
    agreement_id = term.agreement_id
    parent_id = SquareContentAgreement.objects.values_list('parent_id', flat=True).get(pk=agreement_id)
    with transaction.atomic():
        parent = None
        if parent_id:
            from django.contrib.auth import get_user_model
            parent = get_user_model().objects.select_for_update().filter(pk=parent_id).first()
        agreement = SquareContentAgreement.objects.select_for_update().get(pk=agreement_id)
        current = SquareBillingTerm.objects.select_for_update().get(pk=term.pk)
        if (current.processing_lease != term.processing_lease or not current.lease_until
                or current.lease_until <= timezone.now() or frozen_term_hash(current, agreement) != current.request_sha256
                or (current.order_id and current.order_id != order_id)):
            raise CheckoutBusy('Current term lease or immutable proof changed.')
        if current.payment_evidence and not _not_older_payments([observed], [current.payment_evidence]):
            raise CheckoutRejected('Older or conflicting financial facts cannot replace this term proof.')
        current.payment_id, current.order_id = observed['id'], order_id
        plan = term_plan_for_policy(agreement.policy_id)
        if current.coverage_rule and observed['status'] == 'COMPLETED' and observed['source_type'] == 'CARD':
            from .reconciliation import _timestamp
            captured = _timestamp(observed.get('captured_at')).astimezone(datetime_timezone.utc)
            if current.captured_at is not None and current.captured_at != captured:
                raise CheckoutRejected('A paid capture instant cannot change or extend an existing term.')
            if current.captured_at is None:
                current.captured_at = current.valid_from = captured
                current.valid_until = coverage_end(captured,current.coverage_rule,agreement.billing_timezone)
                current.coverage_sha256 = coverage_hash(current,agreement)
        current.payment_evidence = observed
        from .reconciliation import _timestamp
        current.payment_updated_at = _timestamp(observed['updated_at'])
        current.canonical_sha256 = fingerprint(observed)
        now, reference = timezone.now(), term_reference(current.pk)
        grants = ParentContentEntitlement.objects.filter(provider='square', environment='sandbox',
            provider_account_id=agreement.merchant_id, source_reference=reference, feature_code=ALL_CONTENT_FEATURE)
        existing = grants.first()
        if existing and (agreement.parent_id is None or existing.parent_id != agreement.parent_id
                or existing.valid_from != current.valid_from or existing.valid_until != current.valid_until):
            raise CheckoutRejected('A financial proof cannot mutate another parent or covered term.')
        if observed['status'] == 'COMPLETED' and observed['source_type'] == 'CARD' and observed['refunded_minor'] == current.amount_minor:
            current.revoked_at = current.revoked_at or now
            current.state, current.outcome_code = 'refunded', 'exact_term_full_refund'
            grants.filter(revoked_at__isnull=True).update(revoked_at=current.revoked_at)
        elif current.revoked_at:
            current.state, current.outcome_code = 'refunded', 'exact_term_full_refund'
        elif observed['refunded_minor']:
            current.state, current.outcome_code = 'review_required', 'partial_refund_review'
        elif observed['status'] == 'COMPLETED' and observed['source_type'] == 'CARD':
            current.state, current.outcome_code = 'paid', 'exact_term_payment_verified'
            if not plan.purchasable:
                current.outcome_code = 'historical_policy_readonly_no_new_grant'
            if plan.purchasable and parent is not None and parent.is_active and parent.email_verified_at and agreement.parent_id == parent_id:
                if existing and (existing.parent_id != parent.pk or existing.valid_from != current.valid_from
                                 or existing.valid_until != current.valid_until):
                    raise CheckoutRejected('A payment proof cannot move parent or covered term.')
                if existing is None:
                    ParentContentEntitlement.objects.create(parent=parent, feature_code=ALL_CONTENT_FEATURE,
                        provider='square', environment='sandbox', provider_account_id=agreement.merchant_id,
                        source_reference=reference, valid_from=current.valid_from, valid_until=current.valid_until,
                        payment_verified_at=now)
                if current.buyer_present and current.payment_source_mode == 'saved_card' and agreement.activated_at is None and agreement.renewals_enabled:
                    agreement.activated_at = now
                if ((current.buyer_present and agreement.next_term_start is None)
                        or (not current.buyer_present and agreement.next_term_start == current.request_not_before)):
                    agreement.next_term_start = current.valid_until
                agreement.save(update_fields=('activated_at','next_term_start'))
        else:
            current.state = 'failed' if observed['status'] in {'FAILED', 'CANCELED'} else 'payment_pending'
            current.outcome_code = 'payment_not_completed'
        current.processing_lease, current.lease_until = None, None
        current.save()
    return current.state


@sensitive_variables()
def reconcile_term(*, term_id, payment_id=None, client=None):
    term_configuration(readonly=True); client = client or configured_client()
    term, agreement = _claim_term(term_id, for_dispatch=False)
    reader = CanonicalReader(client, term.lease_until)
    try:
        config = term_configuration(readonly=True)
        verify_payment_location(reader, config, require_active=False)
        identifier = payment_id or term.payment_id or _find_term_payment(reader, term)
        if not identifier:
            raise CheckoutRejected('Canonical payment is not visible yet; retain the same term/key.')
        observed, order_id = _collect_term_payment(reader, term, identifier)
        return _commit_payment(term, observed, order_id)
    except Exception:
        try: _term_checkpoint(term, state='review_required', outcome_code='payment_reconciliation_required', processing_lease=None, lease_until=None)
        except CheckoutBusy: pass
        raise


@sensitive_variables()
def dispatch_term_payment(*, term_id, verification_token=None, charge_source_id=None, client=None):
    config = term_configuration(); client = client or configured_client()
    term, agreement = _claim_term(term_id, for_dispatch=True)
    reader = CanonicalReader(client, term.lease_until)
    try:
        verify_payment_location(reader, config)
        identifier = term.payment_id
        if identifier is None and term.dispatched_at:
            identifier = _find_term_payment(reader, term)
        if identifier is None:
            modern = term.payment_source_mode == 'web_charge_and_store'
            proof = (fingerprint({'charge_source_id': charge_source_id}) if modern and charge_source_id is not None
                else fingerprint({'token': verification_token}) if not modern and verification_token else '')
            if term.verification_sha256 != proof or (modern and verification_token is not None):
                raise CheckoutConflict('Repeat the same verified buyer request or reconcile; do not change a payment key.')
            _authorize_dispatch(term)
            result = client.create_term_payment(term_id=term.pk, location_id=term.location_id,
                customer_id=term.customer_id, card_id=term.card_id, idempotency_key=term.provider_idempotency_key,
                buyer_present=term.buyer_present, verification_token=verification_token,
                **({'charge_source_id': charge_source_id} if modern else {}),
                **({'amount_minor': term.amount_minor} if term.amount_minor != 999 else {}))
            payment = result.get('payment', {})
            identifier = provider_identifier(payment.get('id'), 192)
            _term_checkpoint(term, payment_id=identifier)
        observed, order_id = _collect_term_payment(reader, term, identifier)
        state = _commit_payment(term, observed, order_id)
    except Exception:
        try: _term_checkpoint(term, state='uncertain', outcome_code='payment_reconciliation_required',
            next_attempt_at=timezone.now()+timedelta(seconds=min(3600, 15*2**min(term.dispatch_attempts, 8))),
            processing_lease=None, lease_until=None)
        except CheckoutBusy: pass
        raise
    if term.payment_source_mode == 'web_charge_and_store' and state == 'paid':
        activate_payment_card(term_id=term.pk, client=client)
    return state


def _payment_backed_card(card, term, agreement):
    if (not isinstance(card, dict) or card.get('customer_id') != term.customer_id
            or card.get('reference_id') != str(term.pk) or card.get('enabled') is not True
            or card.get('merchant_id', agreement.merchant_id) != agreement.merchant_id):
        raise CheckoutRejected('The saved card does not match this exact payment mandate.')
    return provider_identifier(card.get('id'))


def _find_payment_card(reader, term, agreement):
    cursor, seen, matches = None, set(), set()
    for _page in range(3):
        response = reader.list_cards(customer_id=term.customer_id, cursor=cursor)
        cards = response.get('cards', [])
        if not isinstance(cards, list) or len(cards) > 100:
            raise CheckoutRejected('Invalid canonical card page.')
        for card in cards:
            if isinstance(card, dict) and card.get('reference_id') == str(term.pk):
                matches.add(_payment_backed_card(card, term, agreement))
        cursor = response.get('cursor')
        if not cursor: break
        if not isinstance(cursor, str) or len(cursor) > 4096 or cursor in seen:
            raise CheckoutRejected('Invalid canonical card pagination.')
        seen.add(cursor)
    else: raise CheckoutRejected('Card recovery uniqueness exceeds the bounded search budget.')
    if len(matches) > 1:
        raise CheckoutRejected('Multiple cards reference this exact term; review required.')
    return next(iter(matches), None)


def _lock_card_mandate(term):
    """Called only inside an atomic block; no provider calls under these locks."""
    from django.contrib.auth import get_user_model
    parent_id = SquareContentAgreement.objects.values_list('parent_id', flat=True).get(pk=term.agreement_id)
    parent = get_user_model().objects.select_for_update().filter(pk=parent_id).first()
    agreement = SquareContentAgreement.objects.select_for_update().get(pk=term.agreement_id)
    current = SquareBillingTerm.objects.select_for_update().get(pk=term.pk)
    now = timezone.now()
    if (parent is None or not parent.is_active or not parent.email_verified_at
            or agreement.parent_id != parent.pk or not agreement.renewals_enabled
            or current.processing_lease != term.processing_lease or not current.lease_until
            or current.lease_until <= now or current.state != 'paid' or current.revoked_at
            or current.payment_id != term.payment_id or current.valid_from is None or now < current.valid_from
            or frozen_term_hash(current, agreement) != current.request_sha256):
        raise CheckoutRejected('This exact paid card-storage mandate is no longer active.')
    return agreement, current


@sensitive_variables()
def activate_payment_card(*, term_id, client=None):
    """Save the instrument from the canonical payment, never recharge it.

    A successful initial payment can grant its original term while card storage
    is pending. Only this verified binding enables future merchant payments.
    Receipt reconciliation remains GET-only and never calls this dispatcher.
    """
    config = term_configuration(); client = client or configured_client()
    term, agreement = _claim_term(term_id, for_dispatch=False, for_card_storage=True)
    reader = CanonicalReader(client, term.lease_until)
    try:
        if term.payment_source_mode != 'web_charge_and_store' or not term.buyer_present or not term.payment_id:
            raise CheckoutRejected('Only the exact modern initial payment can bind its stored card.')
        verify_payment_location(reader, config)
        observed, order_id = _collect_term_payment(reader, term, term.payment_id)
        if observed['status'] != 'COMPLETED' or observed['source_type'] != 'CARD' or observed['refunded_minor']:
            _commit_payment(term, observed, order_id)
            raise CheckoutRejected('Card storage requires an unrefunded completed payment.')
        binding = SquarePaymentCardBinding.objects.filter(agreement=agreement).first()
        card_id = binding.card_id if binding else _find_payment_card(reader, term, agreement)
        if not card_id:
            payment = reader.retrieve_payment(term.payment_id)
            details = payment.get('card_details')
            timeline = details.get('card_payment_timeline') if isinstance(details, dict) else None
            from .reconciliation import _timestamp
            if (not isinstance(details, dict) or details.get('status') not in {'AUTHORIZED', 'CAPTURED'}
                    or not isinstance(details.get('entry_method'), str)
                    or not details['entry_method'] or details['entry_method'] == 'ON_FILE'
                    or not isinstance(timeline, dict)
                    or not timedelta(0) <= timezone.now() - _timestamp(timeline.get('authorized_at')) < timedelta(hours=24)
                    or fingerprint(_term_payment_identity(payment,term)) != observed['payment_canonical_sha256']):
                raise CheckoutRejected('This payment cannot safely source a new card on file.')
            with transaction.atomic():
                current_agreement, _current = _lock_card_mandate(term)
                intent = SquareCheckoutIntent.objects.get(pk=current_agreement.intent_reference)
                key = intent.card_idempotency_key
            card_id = client.create_card_from_payment(customer_id=term.customer_id, payment_id=term.payment_id,
                term_id=term.pk, idempotency_key=key)
        card = reader.retrieve_card(card_id)
        payment = reader.retrieve_payment(term.payment_id)
        details = payment.get('card_details')
        instrument = details.get('card') if isinstance(details, dict) else None
        source_fingerprint = instrument.get('fingerprint') if isinstance(instrument, dict) else None
        if (not isinstance(source_fingerprint, str) or not 1 <= len(source_fingerprint) <= 255
                or card.get('fingerprint') != source_fingerprint
                or fingerprint(_term_payment_identity(payment,term)) != observed['payment_canonical_sha256']):
            raise CheckoutRejected('Canonical payment/card instrument identity is unqualified or changed.')
        if _payment_backed_card(card, term, agreement) != card_id:
            raise CheckoutRejected('Canonical saved card identity changed.')
        latest, latest_order = _collect_term_payment(reader, term, term.payment_id)
        if latest['status'] != 'COMPLETED' or latest['refunded_minor']:
            _commit_payment(term, latest, latest_order)
            raise CheckoutRejected('The source payment no longer authorizes recurring card storage.')
        with transaction.atomic():
            current_agreement, current = _lock_card_mandate(term)
            binding, created = SquarePaymentCardBinding.objects.get_or_create(agreement=current_agreement,
                defaults={'source_term': current, 'payment_id': current.payment_id, 'card_id': card_id,
                    'customer_id': current.customer_id, 'canonical_sha256': fingerprint({
                        'payment': current.payment_id, 'card': card_id, 'customer': current.customer_id,
                        'reference': str(current.pk)})})
            if not created and (binding.source_term_id != current.pk or binding.payment_id != current.payment_id
                    or binding.card_id != card_id or binding.customer_id != current.customer_id):
                raise CheckoutRejected('A recurring card binding cannot change its exact source payment.')
            current_agreement.activated_at = current_agreement.activated_at or timezone.now()
            current_agreement.outcome_code = 'payment_backed_card_verified'
            current_agreement.save(update_fields=('activated_at', 'outcome_code'))
            current.processing_lease, current.lease_until = None, None
            current.save(update_fields=('processing_lease', 'lease_until'))
        return 'card_verified'
    except Exception:
        try: _term_checkpoint(term, processing_lease=None, lease_until=None)
        except CheckoutBusy: pass
        # Do not downgrade or erase a paid term merely because storage failed.
        SquareContentAgreement.objects.filter(pk=agreement.pk, activated_at__isnull=True,
            renewals_enabled=True).update(outcome_code='payment_paid_card_storage_pending')
        raise


@sensitive_variables()
def cancel_agreement(*, parent, intent_id, password):
    term_configuration()
    with transaction.atomic():
        locked = type(parent).objects.select_for_update().get(pk=parent.pk)
        _check_parent(locked, password)
        agreement = SquareContentAgreement.objects.select_for_update().get(parent=locked, intent_reference=intent_id)
        agreement.renewals_enabled, agreement.canceled_at = False, agreement.canceled_at or timezone.now()
        agreement.outcome_code = 'parent_stopped_renewals'; agreement.save()
    return agreement


@sensitive_variables()
def restart_unpaid_checkout(*, parent, intent_id, password, disclosure_version, disclosure_sha256,
                            accepted, billing_period='monthly', client=None):
    """A new purchase only after proven nonpayment, never an uncertain-key reset.

    A never-dispatched initial term can be stopped atomically. A dispatched one
    must first have fresh canonical FAILED/CANCELED proof, no activation and no
    grant. This retains its immutable failed history and requires new consent.
    """
    config = term_configuration(); client = client or configured_client()
    quote = term_disclosure(verify_payment_location(client, config), billing_period=billing_period)
    if accepted is not True or disclosure_version != quote['disclosure_version'] or disclosure_sha256 != quote['disclosure_sha256']:
        raise CheckoutRejected('A fresh current billing disclosure must be accepted before retry.')
    intent = SquareCheckoutIntent.objects.get(pk=intent_id, parent=parent, checkout_mode='payments')
    initial = SquareBillingTerm.objects.filter(agreement__intent_reference=intent.pk, buyer_present=True).order_by('created_at','pk').first()
    if initial and initial.dispatched_at is not None:
        if not initial.payment_id:
            raise CheckoutConflict('An uncertain charge must be reconciled; its key cannot be replaced.')
        reconcile_term(term_id=initial.pk, client=client)
    with transaction.atomic():
        locked_parent = type(parent).objects.select_for_update().get(pk=parent.pk)
        _check_parent(locked_parent, password)
        current = SquareCheckoutIntent.objects.select_for_update().get(pk=intent.pk, parent=locked_parent)
        agreement = SquareContentAgreement.objects.select_for_update().filter(intent_reference=current.pk).first()
        if agreement:
            terms = list(agreement.terms.select_for_update().order_by('valid_from')[:2])
            if agreement.activated_at is not None or len(terms) != 1:
                raise CheckoutConflict('An activated recurring agreement cannot be replaced through signup retry.')
            term = terms[0]
            if term.dispatched_at is not None and (term.state != 'failed'
                    or term.payment_evidence.get('status') not in {'FAILED', 'CANCELED'}
                    or term.payment_evidence.get('refunded_minor') != 0):
                raise CheckoutConflict('Only canonical terminal nonpayment can authorize another purchase.')
            if ParentContentEntitlement.objects.filter(source_reference=term_reference(term.pk),
                    provider='square', environment='sandbox', provider_account_id=agreement.merchant_id).exists():
                raise CheckoutConflict('An existing payment grant cannot be replaced through signup retry.')
            agreement.renewals_enabled = False; agreement.canceled_at = agreement.canceled_at or timezone.now()
            agreement.outcome_code = 'initial_not_paid'; agreement.save()
        elif current.state not in {'reserved', 'card_ready', 'uncertain'}:
            raise CheckoutConflict('This purchase requires reconciliation before retry.')
        current.is_open, current.state = False, 'closed_nonpayment'
        current.save(update_fields=('is_open', 'state', 'updated_at'))
    return reserve_term_checkout(parent=parent, password=password, disclosure_version=disclosure_version,
        disclosure_sha256=disclosure_sha256, accepted=accepted, billing_period=billing_period, client=client)


def prepare_due_term(*, agreement_id):
    term_configuration()
    initial = SquareContentAgreement.objects.get(pk=agreement_id)
    plan = term_plan_for_policy(initial.policy_id)
    if not plan.purchasable or not initial.parent_id:
        raise CheckoutRejected('Historical/deleted agreements cannot renew.')
    from django.contrib.auth import get_user_model
    expired = False
    with transaction.atomic():
        parent = get_user_model().objects.select_for_update().get(pk=initial.parent_id)
        agreement = SquareContentAgreement.objects.select_for_update().get(pk=agreement_id)
        now = timezone.now()
        if (not agreement.renewals_enabled or agreement.activated_at is None or agreement.parent_id != parent.pk
                or not parent.is_active or not parent.email_verified_at or agreement.next_term_start is None
                or now < agreement.next_term_start):
            raise CheckoutRejected('No renewal is due or authorized.')
        if now >= coverage_end(agreement.next_term_start,plan.coverage_rule,agreement.billing_timezone):
            agreement.renewals_enabled = False
            agreement.outcome_code = 'missed_cycle_requires_review'
            agreement.save(update_fields=('renewals_enabled','outcome_code'))
            expired = True
        else:
            term = agreement.terms.filter(request_not_before=agreement.next_term_start).first()
            if term is None: term = _new_term(agreement,agreement.next_term_start)
            # Do not advance a due date or invent coverage before actual capture.
    if expired: raise CheckoutRejected('No automatic catch-up billing for missed expired periods.')
    return term


@sensitive_variables()
def process_due_terms(*, limit=10, client=None):
    term_configuration()
    if type(limit) is not int or not 1 <= limit <= 20:
        raise ValueError('Term batch limit must be between1 and20.')
    client = client or configured_client()
    now = timezone.now()
    identifiers = list(SquareBillingTerm.objects.filter(buyer_present=False,
        agreement__policy_id__in=ACTIVE_POLICY_IDS, agreement__renewals_enabled=True, agreement__activated_at__isnull=False,
        agreement__parent__is_active=True, agreement__parent__email_verified_at__isnull=False,
        request_not_before__lte=now, state__in=('reserved', 'uncertain', 'payment_pending')).filter(
            Q(next_attempt_at__isnull=True) | Q(next_attempt_at__lte=now)).order_by('request_not_before').values_list('pk', flat=True)[:limit])
    remaining = limit - len(identifiers)
    due = list(SquareContentAgreement.objects.filter(policy_id__in=ACTIVE_POLICY_IDS, renewals_enabled=True, activated_at__isnull=False,
        parent__is_active=True, parent__email_verified_at__isnull=False,
        next_term_start__lte=now).order_by('next_term_start').values_list('pk', flat=True)[:remaining])
    for agreement_id in due:
        try: identifiers.append(prepare_due_term(agreement_id=agreement_id).pk)
        except CheckoutRejected: pass
    results = []
    for identifier in dict.fromkeys(identifiers):
        try: results.append(dispatch_term_payment(term_id=identifier, client=client))
        except Exception: results.append('review_required')
    return results
