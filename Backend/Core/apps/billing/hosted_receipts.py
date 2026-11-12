"""Signed inbox consumption through bounded canonical READs, never event grants."""
from datetime import timedelta
from uuid import UUID,uuid4
from django.db import transaction
from django.utils import timezone
from django.views.decorators.debug import sensitive_variables
from .checkout import CheckoutRejected,CheckoutBusy,fingerprint
from .configuration import active_billing_environment,assert_client_environment,provider_identifier
from .hosted_models import SquareHostedAttempt,SquareHostedPaymentProof,SquareHostedCancellation
from .hosted_provider import hosted_configuration,hosted_client
from .hosted_checkout import HostedReader,reconcile,process_cancellation,_validate_template,_payload
from .models import SquareWebhookReceipt
from .reconciliation import SUPPORTED_EVENTS


def _target(reader,receipt):
    invoice_id=None
    if receipt.event_type.startswith('subscription.'):
        subscription_id=provider_identifier(receipt.object_id,192)
    elif receipt.event_type.startswith('invoice.'):
        invoice=reader.retrieve_invoice(provider_identifier(receipt.object_id,192))
        subscription_id=provider_identifier(invoice.get('subscription_id'),192)
        invoice_id=provider_identifier(invoice.get('id'),192)
    else:
        if receipt.event_type.startswith('refund.'):
            refund=reader.retrieve_refund(provider_identifier(receipt.object_id,192))
            payment_id=provider_identifier(refund.get('payment_id'),192)
        else:payment_id=provider_identifier(receipt.object_id,192)
        payment=reader.retrieve_payment(payment_id)
        proof=SquareHostedPaymentProof.objects.select_related('attempt').filter(
            environment=receipt.environment,payment_id=payment.get('id'),
            attempt__environment=receipt.environment,attempt__merchant_id=receipt.merchant_id).first()
        if proof:
            return proof.attempt,proof.attempt.subscription_id,proof.invoice_id
        # An initial payment can precede the invoice/subscription events. An
        # unmatched payment is never matched by buyer email/phone/customer alone.
        raise CheckoutBusy('Await the exact owned subscription/invoice binding.')
    subscription=reader.retrieve_subscription(subscription_id)
    phases=subscription.get('phases',[])
    if not isinstance(phases,list):raise CheckoutRejected('Subscription phases require review.')
    templates=[p.get('order_template_id') for p in phases if isinstance(p,dict) and p.get('order_template_id')]
    rows=list(SquareHostedAttempt.objects.filter(environment=receipt.environment,
        merchant_id=receipt.merchant_id,order_template_id__in=templates).select_related('parent')[:2])
    if not rows and len(templates)==1:
        # A CreatePaymentLink response can be lost before its order ID is saved.
        # Only the canonical server-created template's exact frozen reference
        # and metadata may recover that binding, including after parent deletion.
        template=reader.retrieve_order(provider_identifier(templates[0],192))
        try:attempt_id=UUID(template.get('reference_id',''))
        except (ValueError,TypeError,AttributeError):attempt_id=None
        with transaction.atomic():
            candidate=SquareHostedAttempt.objects.select_for_update().filter(pk=attempt_id,
                environment=receipt.environment,merchant_id=receipt.merchant_id).first() if attempt_id else None
            if candidate and candidate.request_body and candidate.request_sha256==fingerprint(candidate.request_body) and candidate.request_body==_payload(candidate):
                _validate_template(template,candidate,expected_id=templates[0])
                if candidate.order_template_id not in ('',templates[0]):raise CheckoutRejected('Canonical template ownership changed.')
                candidate.order_template_id=templates[0];candidate.save(update_fields=('order_template_id','updated_at'))
                rows=[candidate]
    if len(rows)!=1:
        if not rows:return None,subscription_id,invoice_id
        raise CheckoutRejected('More than one checkout claims the canonical subscription.')
    return rows[0],subscription_id,invoice_id


@sensitive_variables()
def process_hosted_receipt(*,receipt_id,client=None):
    env=active_billing_environment();config=hosted_configuration(environment=env,readonly=True)
    lease=uuid4();now=timezone.now()
    with transaction.atomic():
        receipt=SquareWebhookReceipt.objects.select_for_update().get(pk=receipt_id,environment=env,
            merchant_id=config.provider.merchant_id)
        if receipt.processing_state in {'processed','ignored'}:return receipt.processing_state
        if receipt.processing_lease and receipt.lease_until and receipt.lease_until>now:return 'busy'
        receipt.processing_state='processing';receipt.processing_lease=lease
        receipt.lease_until=now+timedelta(seconds=30);receipt.processing_attempts+=1;receipt.save()
    state,code='retry','hosted_canonical_retry'
    try:
        if receipt.event_type not in SUPPORTED_EVENTS or not receipt.object_id:
            state,code='ignored','unsupported_event'
        else:
            client=client or hosted_client(environment=env,readonly=True);assert_client_environment(client,environment=env)
            reader=HostedReader(client,timezone.now()+timedelta(seconds=8))
            attempt,sub_id,invoice_id=_target(reader,receipt)
            if attempt is None:state,code='ignored','no_owned_hosted_template'
            else:
                reconcile(parent=attempt.parent,attempt_id=attempt.pk,client=client,subscription_hint=sub_id,
                    invoice_hint=invoice_id,reader=reader)
                state,code='processed','hosted_canonical_observation'
                # A retained deletion/cancel request is not lost when a late
                # subscription event binds the original in-flight checkout.
                job=SquareHostedCancellation.objects.filter(attempt=attempt,environment=env).first()
                if job and job.state!='verified':
                    # Cancellation has its own bounded operation; signal retry
                    # if still uncertain so Square will redeliver, not re-charge.
                    process_cancellation(job_id=job.pk,client=client,reader=reader)
    except Exception:
        state,code='retry','hosted_canonical_retry'
    finally:
        with transaction.atomic():
            current=SquareWebhookReceipt.objects.select_for_update().get(pk=receipt_id,environment=env)
            if current.processing_lease==lease:
                current.processing_state=state;current.outcome_code=code
                current.processing_lease=None;current.lease_until=None
                current.processed_at=timezone.now() if state in {'processed','ignored'} else None
                current.next_attempt_at=None;current.save()
    return state
