"""Sandbox evidence and provider-neutral paid periods; rollout is default off."""
import uuid
from datetime import datetime

from django.conf import settings
from django.core.exceptions import ValidationError
from django.db import models
from django.utils import timezone


PAYMENT_ENVIRONMENTS = (('sandbox', 'Sandbox'), ('production', 'Production'))


def environment_constraint(name):
    return models.CheckConstraint(condition=models.Q(environment__in=('sandbox', 'production')), name=name)


class EnvironmentBoundModel(models.Model):
    """Provider references never move between isolated payment environments."""
    environment = models.CharField(max_length=16, choices=PAYMENT_ENVIRONMENTS, default='sandbox', db_index=True)
    ENVIRONMENT_RELATIONS = ()

    class Meta:
        abstract = True

    def save(self, *args, **kwargs):
        if self.environment not in {'sandbox', 'production'}:
            raise ValidationError('A known immutable payment environment is required.')
        if not self._state.adding:
            original = type(self).objects.filter(pk=self.pk).values_list('environment', flat=True).first()
            if original is not None and original != self.environment:
                raise ValidationError('A payment record cannot change environment.')
        for name in self.ENVIRONMENT_RELATIONS:
            identifier = getattr(self, name + '_id')
            model = self._meta.get_field(name).remote_field.model
            if identifier is not None and not model.objects.filter(pk=identifier, environment=self.environment).exists():
                raise ValidationError('Related payment records must share one environment.')
        return super().save(*args, **kwargs)


class SquareCustomerIdentity(EnvironmentBoundModel):
    parent = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE,
                               related_name='square_sandbox_customers')
    merchant_id = models.CharField(max_length=192)
    customer_id = models.CharField(max_length=192)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        constraints = [
            environment_constraint('square_customer_environment'),
            models.UniqueConstraint(fields=('environment', 'parent', 'merchant_id'), name='square_sbx_parent_merchant'),
            models.UniqueConstraint(fields=('environment', 'merchant_id', 'customer_id'), name='square_sbx_customer_identity'),
        ]


class SquareSubscriptionIdentity(EnvironmentBoundModel):
    ENVIRONMENT_RELATIONS = ('customer',)
    # Ownership derives through the customer; no second parent field to drift.
    customer = models.ForeignKey(SquareCustomerIdentity, on_delete=models.CASCADE,
                                 related_name='subscriptions')
    subscription_id = models.CharField(max_length=192)
    provider_status = models.CharField(max_length=64, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        constraints = [environment_constraint('square_subscription_environment'),
            models.UniqueConstraint(fields=('environment', 'subscription_id'), name='square_env_subscription_id')]


class SquareSandboxOperation(EnvironmentBoundModel):
    parent = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE,
                               related_name='square_sandbox_operations')
    merchant_id = models.CharField(max_length=192)
    operation_id = models.UUIDField()
    # Provider key is server-generated, not a caller's cross-tenant UUID.
    provider_idempotency_key = models.UUIDField(default=uuid.uuid4, unique=True, editable=False)
    kind = models.CharField(max_length=40, default='customer.create')
    request_sha256 = models.CharField(max_length=64)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        constraints = [environment_constraint('square_operation_environment'),
                      models.UniqueConstraint(fields=('environment', 'parent', 'merchant_id', 'operation_id'),
                                               name='square_sbx_parent_operation')]


class SquareWebhookReceipt(EnvironmentBoundModel):
    # Minimal durable inbox metadata only: no raw payload, card or customer PII.
    merchant_id = models.CharField(max_length=192)
    event_id = models.CharField(max_length=128)
    event_type = models.CharField(max_length=128)
    object_id = models.CharField(max_length=255, blank=True)
    body_sha256 = models.CharField(max_length=64)
    received_at = models.DateTimeField(auto_now_add=True)
    processing_state = models.CharField(max_length=24, default='pending')
    processing_attempts = models.PositiveIntegerField(default=0)
    processing_lease = models.UUIDField(null=True, blank=True)
    lease_until = models.DateTimeField(null=True, blank=True)
    next_attempt_at = models.DateTimeField(null=True, blank=True)
    processed_at = models.DateTimeField(null=True, blank=True)
    outcome_code = models.CharField(max_length=64, blank=True)

    class Meta:
        constraints = [environment_constraint('square_webhook_environment'),
                      models.UniqueConstraint(fields=('environment', 'merchant_id', 'event_id'),
                                               name='square_sbx_event_identity')]


PAID_CONTENT_PROVIDERS = ('square', 'app_store')


def valid_proof_identifier(value):
    if (not isinstance(value, str) or not 1 <= len(value) <= 192
            or any(character.isspace() or ord(character) < 32 or ord(character) == 127 for character in value)):
        return False
    try:
        value.encode('utf-8')
        return True
    except UnicodeEncodeError:
        return False


class ParentContentEntitlement(models.Model):
    """Server-verified paid period; no public grant API or webhook writer exists.

    Renewal cancellation leaves the already-paid period intact. Revocation is
    explicit/effective at revoked_at; paid coverage is [valid_from, valid_until).
    """
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    parent = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE,
                               related_name='content_entitlements')
    feature_code = models.CharField(max_length=64)
    provider = models.CharField(max_length=32, choices=(('square', 'Square'), ('app_store', 'App Store')))
    environment = models.CharField(max_length=16, choices=(('sandbox', 'Sandbox'), ('production', 'Production')))
    provider_account_id = models.CharField(max_length=192)
    source_reference = models.CharField(max_length=192)
    valid_from = models.DateTimeField()
    valid_until = models.DateTimeField()
    payment_verified_at = models.DateTimeField()
    revoked_at = models.DateTimeField(null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        constraints = [
            models.CheckConstraint(condition=models.Q(valid_until__gt=models.F('valid_from')),
                                   name='paid_content_positive_period'),
            models.CheckConstraint(condition=models.Q(environment__in=('sandbox', 'production')),
                                   name='paid_content_known_environment'),
            models.CheckConstraint(condition=models.Q(provider__in=PAID_CONTENT_PROVIDERS),
                                   name='paid_content_known_provider'),
            models.CheckConstraint(condition=(~models.Q(provider_account_id='') & ~models.Q(source_reference='')),
                                   name='paid_content_nonempty_proof'),
            models.UniqueConstraint(fields=('provider', 'environment', 'provider_account_id',
                                            'source_reference', 'feature_code'),
                                    name='paid_content_proof_feature'),
        ]

    def clean(self):
        super().clean()
        if (self.provider not in PAID_CONTENT_PROVIDERS
                or not valid_proof_identifier(self.provider_account_id)
                or not valid_proof_identifier(self.source_reference)):
            raise ValidationError('A supported provider and valid server evidence identifiers are required.')
        for value in (self.valid_from, self.valid_until, self.payment_verified_at, self.revoked_at):
            if value is not None and (not isinstance(value, datetime) or timezone.is_naive(value)):
                raise ValidationError('Paid-period timestamps must be timezone-aware.')

    def save(self, *args, **kwargs):
        if not self._state.adding:
            original = type(self).objects.filter(pk=self.pk).values_list('environment', flat=True).first()
            if original is not None and original != self.environment:
                raise ValidationError('A paid proof cannot change environment.')
        self.full_clean()
        return super().save(*args, **kwargs)


class SquareCheckoutIntent(EnvironmentBoundModel):
    """Server-owned purchase intent. Provider customer details are not ownership.

    Open includes uncertain requests and bound subscriptions. No client endpoint
    closes an intent: a local timeout must never permit a second subscription.
    """
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    parent = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE,
                               related_name='square_checkout_intents')
    merchant_id = models.CharField(max_length=192)
    location_id = models.CharField(max_length=192)
    variation_id = models.CharField(max_length=255)
    policy_id = models.CharField(max_length=96)
    policy_sha256 = models.CharField(max_length=64)
    disclosure_version = models.CharField(max_length=96)
    disclosure_sha256 = models.CharField(max_length=64, blank=True)
    billing_timezone = models.CharField(max_length=64, blank=True)
    consented_at = models.DateTimeField()
    reauthenticated_at = models.DateTimeField()
    provider_idempotency_key = models.UUIDField(default=uuid.uuid4, unique=True, editable=False)
    customer_idempotency_key = models.UUIDField(default=uuid.uuid4, unique=True, editable=False)
    card_idempotency_key = models.UUIDField(default=uuid.uuid4, unique=True, editable=False)
    request_sha256 = models.CharField(max_length=64)
    card_request_sha256 = models.CharField(max_length=64, blank=True)
    checkout_mode = models.CharField(max_length=16, default='direct')
    is_open = models.BooleanField(default=True)
    state = models.CharField(max_length=32, default='reserved')
    payment_link_id = models.CharField(max_length=192, blank=True)
    order_template_id = models.CharField(max_length=192, blank=True)
    checkout_url = models.URLField(max_length=2048, blank=True)
    subscription_id = models.CharField(max_length=255, blank=True)
    customer_id = models.CharField(max_length=192, blank=True)
    card_id = models.CharField(max_length=255, blank=True)
    subscription_version = models.PositiveBigIntegerField(default=0)
    subscription_sha256 = models.CharField(max_length=64, blank=True)
    provider_status = models.CharField(max_length=32, blank=True)
    processing_lease = models.UUIDField(null=True, blank=True)
    lease_until = models.DateTimeField(null=True, blank=True)
    outcome_code = models.CharField(max_length=64, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)
    reconciliation_invoice_cursor = models.CharField(max_length=255, blank=True)

    class Meta:
        constraints = [
            environment_constraint('square_checkout_environment'),
            models.UniqueConstraint(fields=('environment', 'parent', 'policy_id'), condition=models.Q(is_open=True),
                                    name='square_one_open_parent_policy'),
            *[models.UniqueConstraint(fields=('environment', 'merchant_id', field), condition=~models.Q(**{field: ''}),
                                      name='square_checkout_' + suffix)
              for field, suffix in [('payment_link_id', 'link'), ('order_template_id', 'template'),
                                    ('subscription_id', 'subscription')]],
            models.UniqueConstraint(fields=('environment', 'merchant_id', 'customer_id'),
                condition=models.Q(checkout_mode='direct') & ~models.Q(customer_id=''),
                name='square_direct_owned_customer'),
        ]


class SquareInvoiceEvidence(EnvironmentBoundModel):
    ENVIRONMENT_RELATIONS = ('intent',)
    """Minimal canonical observations; a paid invoice alone is not coverage.

    No provider body, customer PII, card/token data or arbitrary service dates
    are stored. Coverage remains empty until an independently reviewed resolver
    can identify the exact covered cycle of this specific invoice.
    """
    intent = models.ForeignKey(SquareCheckoutIntent, on_delete=models.CASCADE,
                               related_name='invoice_evidence')
    merchant_id = models.CharField(max_length=192)
    invoice_id = models.CharField(max_length=255)
    charge_order_id = models.CharField(max_length=192)
    invoice_version = models.PositiveBigIntegerField()
    subscription_version = models.PositiveBigIntegerField()
    canonical_sha256 = models.CharField(max_length=64)
    invoice_status = models.CharField(max_length=32)
    payment_evidence = models.JSONField(default=list)
    billing_facts = models.JSONField(default=dict)
    amount_minor = models.PositiveBigIntegerField(default=0)
    refunded_minor = models.PositiveBigIntegerField(default=0)
    currency = models.CharField(max_length=3, default='USD')
    outcome_code = models.CharField(max_length=64)
    valid_from = models.DateTimeField(null=True, blank=True)
    valid_until = models.DateTimeField(null=True, blank=True)
    revoked_at = models.DateTimeField(null=True, blank=True)
    observed_at = models.DateTimeField(default=timezone.now)

    class Meta:
        constraints = [
            environment_constraint('square_invoice_environment'),
            models.UniqueConstraint(fields=('environment', 'merchant_id', 'invoice_id'), name='square_invoice_proof'),
            models.UniqueConstraint(fields=('environment', 'merchant_id', 'charge_order_id'), name='square_invoice_order'),
        ]


class SquareCancellationOutbox(EnvironmentBoundModel):
    """Survives account deletion; only provider references needed to stop billing.

    No User FK, parent identifier, contact data, token or provider body. Verified
    jobs clear customer/card/template references; production retention policy
    for the minimal provider cancellation receipt still needs qualification.
    """
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    intent_reference = models.UUIDField(unique=True)
    checkout_mode = models.CharField(max_length=16)
    merchant_id = models.CharField(max_length=192)
    location_id = models.CharField(max_length=192, blank=True)
    variation_id = models.CharField(max_length=255, blank=True)
    customer_id = models.CharField(max_length=192, blank=True)
    card_id = models.CharField(max_length=255, blank=True)
    subscription_id = models.CharField(max_length=255, blank=True)
    payment_link_id = models.CharField(max_length=192, blank=True)
    order_template_id = models.CharField(max_length=192, blank=True)
    state = models.CharField(max_length=24, default='pending')
    attempts = models.PositiveIntegerField(default=0)
    processing_lease = models.UUIDField(null=True, blank=True)
    lease_until = models.DateTimeField(null=True, blank=True)
    next_attempt_at = models.DateTimeField(null=True, blank=True)
    link_disabled_at = models.DateTimeField(null=True, blank=True)
    canceled_date = models.DateField(null=True, blank=True)
    verified_at = models.DateTimeField(null=True, blank=True)
    canonical_sha256 = models.CharField(max_length=64, blank=True)
    outcome_code = models.CharField(max_length=64, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        constraints = [environment_constraint('square_cancellation_environment')]


class SquareContentAgreement(EnvironmentBoundModel):
    ENVIRONMENT_RELATIONS = ('intent',)
    """App-owned recurring mandate; never runs an automatic Square Subscription."""
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    parent = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.SET_NULL, null=True,
                               related_name='square_content_agreements')
    intent = models.OneToOneField(SquareCheckoutIntent, on_delete=models.SET_NULL, null=True,
                                 related_name='content_agreement')
    intent_reference = models.UUIDField(unique=True)
    merchant_id = models.CharField(max_length=192)
    location_id = models.CharField(max_length=192)
    customer_id = models.CharField(max_length=192)
    card_id = models.CharField(max_length=255)
    policy_id = models.CharField(max_length=96)
    policy_sha256 = models.CharField(max_length=64)
    disclosure_version = models.CharField(max_length=96)
    disclosure_sha256 = models.CharField(max_length=64)
    billing_timezone = models.CharField(max_length=64)
    consented_at = models.DateTimeField()
    next_term_start = models.DateTimeField(null=True, blank=True)
    renewals_enabled = models.BooleanField(default=True)
    canceled_at = models.DateTimeField(null=True, blank=True)
    activated_at = models.DateTimeField(null=True, blank=True)
    outcome_code = models.CharField(max_length=64, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        constraints = [environment_constraint('square_agreement_environment'),
                      models.UniqueConstraint(fields=('environment', 'parent'), condition=models.Q(renewals_enabled=True),
                                               name='square_one_renewing_parent')]

    def save(self, *args, **kwargs):
        immutable = ('intent_reference', 'merchant_id', 'location_id', 'customer_id', 'card_id',
                     'policy_id', 'policy_sha256', 'disclosure_version', 'disclosure_sha256',
                     'billing_timezone', 'consented_at')
        if self._state.adding is False:
            old = type(self).objects.filter(pk=self.pk).values('parent_id', *immutable).first()
            if old is not None and (any(getattr(self, key) != old[key] for key in immutable)
                    or (self.parent_id is not None and self.parent_id != old['parent_id'])):
                raise ValidationError('A recurring agreement cannot change its owner or frozen mandate.')
        return super().save(*args, **kwargs)


class SquareBillingTerm(EnvironmentBoundModel):
    ENVIRONMENT_RELATIONS = ('agreement',)
    """Immutable app-contract coverage tied to Payment.reference_id == this UUID.

    No provider due date determines these bounds. A term is written before
    financial dispatch and can only grant its own interval after canonical pay.
    """
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    agreement = models.ForeignKey(SquareContentAgreement, on_delete=models.PROTECT, related_name='terms')
    valid_from = models.DateTimeField(null=True, blank=True)
    valid_until = models.DateTimeField(null=True, blank=True)
    amount_minor = models.PositiveIntegerField(default=999)
    currency = models.CharField(max_length=3, default='USD')
    cadence = models.CharField(max_length=16, default='MONTHLY')
    coverage_rule = models.CharField(max_length=32, blank=True)
    request_not_before = models.DateTimeField(null=True, blank=True)
    captured_at = models.DateTimeField(null=True, blank=True)
    coverage_sha256 = models.CharField(max_length=64, blank=True)
    provider_idempotency_key = models.UUIDField(default=uuid.uuid4, unique=True, editable=False)
    customer_id = models.CharField(max_length=192)
    card_id = models.CharField(max_length=255)
    location_id = models.CharField(max_length=192)
    buyer_present = models.BooleanField(default=False)
    payment_source_mode = models.CharField(max_length=32, default='saved_card')
    verification_sha256 = models.CharField(max_length=64, blank=True)
    request_sha256 = models.CharField(max_length=64)
    payment_id = models.CharField(max_length=192, blank=True, null=True)
    order_id = models.CharField(max_length=192, blank=True)
    state = models.CharField(max_length=32, default='reserved')
    dispatched_at = models.DateTimeField(null=True, blank=True)
    last_dispatched_at = models.DateTimeField(null=True, blank=True)
    dispatch_attempts = models.PositiveIntegerField(default=0)
    next_attempt_at = models.DateTimeField(null=True, blank=True)
    processing_lease = models.UUIDField(null=True, blank=True)
    lease_until = models.DateTimeField(null=True, blank=True)
    payment_updated_at = models.DateTimeField(null=True, blank=True)
    canonical_sha256 = models.CharField(max_length=64, blank=True)
    payment_evidence = models.JSONField(default=dict)
    revoked_at = models.DateTimeField(null=True, blank=True)
    outcome_code = models.CharField(max_length=64, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    IMMUTABLE_FIELDS = ('agreement_id', 'amount_minor', 'currency', 'coverage_rule', 'request_not_before',
                        'provider_idempotency_key', 'cadence', 'customer_id', 'card_id', 'location_id',
                        'buyer_present', 'payment_source_mode', 'verification_sha256', 'request_sha256')

    class Meta:
        constraints = [
            environment_constraint('square_term_environment'),
            models.UniqueConstraint(fields=('environment', 'payment_id'),
                condition=models.Q(payment_id__isnull=False) & ~models.Q(payment_id=''),
                name='square_env_term_payment_id'),
            models.UniqueConstraint(fields=('agreement', 'valid_from'), name='square_one_term_start'),
            models.UniqueConstraint(fields=('agreement','request_not_before'),
                condition=~models.Q(coverage_rule=''), name='square_one_pending_term_request'),
            models.CheckConstraint(condition=(
                models.Q(coverage_rule='', valid_from__isnull=False, valid_until__isnull=False,
                    valid_until__gt=models.F('valid_from'), captured_at__isnull=True, coverage_sha256='')
                | (models.Q(coverage_rule__in=('elapsed_days_30','calendar_year_1'), request_not_before__isnull=False)
                   & (models.Q(valid_from__isnull=True, valid_until__isnull=True, captured_at__isnull=True, coverage_sha256='')
                      | (models.Q(valid_from__isnull=False, valid_until__isnull=False, captured_at__isnull=False,
                            valid_from=models.F('captured_at'), valid_until__gt=models.F('valid_from'))
                         & ~models.Q(coverage_sha256=''))))), name='square_positive_term'),
            models.CheckConstraint(condition=(
                models.Q(amount_minor=999, currency='USD', cadence='MONTHLY', coverage_rule='')
                | models.Q(amount_minor=10789, currency='USD', cadence='ANNUAL', coverage_rule='')
                | models.Q(amount_minor=999, currency='USD', cadence='DAYS_30', coverage_rule='elapsed_days_30')
                | models.Q(amount_minor=9990, currency='USD', cadence='ANNUAL', coverage_rule='calendar_year_1')),
                name='square_term_confirmed_price'),
        ]

    def save(self, *args, **kwargs):
        coverage_fields = ('valid_from','valid_until','captured_at','coverage_sha256')
        if not self._state.adding:
            old = type(self).objects.filter(pk=self.pk).values(*self.IMMUTABLE_FIELDS,*coverage_fields).first()
            if old is not None:
                if any(getattr(self, key) != old[key] for key in self.IMMUTABLE_FIELDS):
                    raise ValidationError('A billing term cannot change its frozen payment request.')
                if (old['coverage_rule'] == '' or old['captured_at'] is not None) and any(
                        getattr(self,key) != old[key] for key in coverage_fields):
                    raise ValidationError('A bound paid coverage interval cannot change.')
        values = (self.valid_from,self.valid_until,self.captured_at,self.request_not_before)
        if any(value is not None and timezone.is_naive(value) for value in values):
            raise ValidationError('Billing timestamps must be timezone-aware.')
        if self.coverage_rule:
            unbound = all(getattr(self,key) is None for key in coverage_fields[:3]) and self.coverage_sha256 == ''
            bound = (all(getattr(self,key) is not None for key in coverage_fields[:3])
                and self.valid_from == self.captured_at and self.valid_until > self.valid_from
                and len(self.coverage_sha256) == 64)
            if self.request_not_before is None or not (unbound or bound):
                raise ValidationError('Coverage must be wholly unbound or atomically bound once to capture.')
        return super().save(*args, **kwargs)


class SquarePaymentCardBinding(EnvironmentBoundModel):
    ENVIRONMENT_RELATIONS = ('agreement', 'source_term')
    """Verified card created from one exact paid term, never a second nonce.

    Kept separate so neither the initial immutable request nor the mandate is
    rewritten after payment. Future terms snapshot this canonical stored card.
    """
    agreement = models.OneToOneField(SquareContentAgreement, on_delete=models.PROTECT,
                                    related_name='payment_card_binding')
    source_term = models.OneToOneField(SquareBillingTerm, on_delete=models.PROTECT)
    payment_id = models.CharField(max_length=192)
    card_id = models.CharField(max_length=255)
    customer_id = models.CharField(max_length=192)
    canonical_sha256 = models.CharField(max_length=64)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        constraints = [environment_constraint('square_binding_environment'),
            models.UniqueConstraint(fields=('environment', 'payment_id'), name='square_env_card_payment_id')]

    def save(self, *args, **kwargs):
        if self.source_term_id and self.agreement_id and not SquareBillingTerm.objects.filter(
                pk=self.source_term_id, agreement_id=self.agreement_id, environment=self.environment).exists():
            raise ValidationError('A card binding requires its own environment-bound agreement term.')
        if not self._state.adding:
            old = type(self).objects.filter(pk=self.pk).values().first()
            fields = ('agreement_id', 'source_term_id', 'payment_id', 'card_id', 'customer_id', 'canonical_sha256')
            if old is not None and any(getattr(self, key) != old[key] for key in fields):
                raise ValidationError('An exact-payment card binding cannot be reassigned.')
        return super().save(*args, **kwargs)


from .job_models import SquareBillingJobState  # noqa: E402,F401
from .handoff_models import ParentCheckoutHandoff  # noqa: E402,F401
from .hosted_models import SquareHostedAttempt, SquareHostedPaymentProof  # noqa: E402,F401
from .hosted_models import SquareHostedCancellation  # noqa: E402,F401

from .complimentary_models import ParentComplimentaryAccessGrant  # noqa: E402,F401
