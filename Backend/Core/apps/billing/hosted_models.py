"""Independent hosted recurring contracts; old payment terms stay immutable."""
import uuid
from django.conf import settings
from django.core.exceptions import ValidationError
from django.db import models
from django.utils import timezone


class SquareHostedAttempt(models.Model):
 id=models.UUIDField(primary_key=True,default=uuid.uuid4,editable=False)
 environment=models.CharField(max_length=16,default='sandbox',db_index=True)
 parent=models.ForeignKey(settings.AUTH_USER_MODEL,on_delete=models.SET_NULL,null=True,related_name='square_hosted_attempts')
 operation_id=models.UUIDField()
 billing_period=models.CharField(max_length=16)
 policy_id=models.CharField(max_length=96)
 policy_sha256=models.CharField(max_length=64)
 disclosure_sha256=models.CharField(max_length=64)
 merchant_id=models.CharField(max_length=192)
 location_id=models.CharField(max_length=192)
 variation_id=models.CharField(max_length=192)
 amount_minor=models.PositiveIntegerField()
 currency=models.CharField(max_length=3,default='USD')
 provider_idempotency_key=models.UUIDField(default=uuid.uuid4,unique=True,editable=False)
 request_sha256=models.CharField(max_length=64,blank=True)
 request_body=models.JSONField(default=dict)
 return_state=models.UUIDField(default=uuid.uuid4,editable=False)
 authorization_sha256=models.CharField(max_length=64,blank=True)
 authorization_expires_at=models.DateTimeField(null=True,blank=True)
 parent_auth_sha256=models.CharField(max_length=64,blank=True)
 payment_link_id=models.CharField(max_length=192,blank=True)
 order_template_id=models.CharField(max_length=192,blank=True)
 checkout_url=models.URLField(max_length=2048,blank=True)
 subscription_id=models.CharField(max_length=192,blank=True)
 customer_id=models.CharField(max_length=192,blank=True)
 subscription_version=models.PositiveBigIntegerField(default=0)
 reconciliation_invoice_cursor=models.CharField(max_length=192,blank=True)
 subscription_sha256=models.CharField(max_length=64,blank=True)
 provider_status=models.CharField(max_length=32,blank=True)
 renewals_enabled=models.BooleanField(default=False)
 state=models.CharField(max_length=24,default='reserved')
 is_open=models.BooleanField(default=True)
 processing_lease=models.UUIDField(null=True,blank=True)
 lease_until=models.DateTimeField(null=True,blank=True)
 cancel_requested_at=models.DateTimeField(null=True,blank=True)
 canceled_date=models.DateField(null=True,blank=True)
 created_at=models.DateTimeField(default=timezone.now)
 updated_at=models.DateTimeField(auto_now=True)
 class Meta:
  indexes=[models.Index(fields=('environment','parent','state','created_at'),name='hosted_parent_state')]
  constraints=[models.CheckConstraint(condition=models.Q(environment__in=('sandbox','production')),name='hosted_attempt_environment'),
   models.CheckConstraint(condition=models.Q(billing_period='monthly',amount_minor=999,currency='USD')|models.Q(billing_period='yearly',amount_minor=9990,currency='USD'),name='hosted_attempt_price'),
   models.UniqueConstraint(fields=('environment','parent','operation_id'),name='hosted_parent_operation'),
   models.UniqueConstraint(fields=('environment','parent'),condition=models.Q(is_open=True),name='hosted_parent_open_attempt'),
   *[models.UniqueConstraint(fields=('environment','merchant_id',field),condition=~models.Q(**{field:''}),name='hosted_unique_'+field) for field in ('payment_link_id','order_template_id','subscription_id')]]
 def save(self,*args,**kwargs):
  if self.environment not in {'sandbox','production'}:raise ValidationError('Unknown hosted environment.')
  if not self._state.adding:
   fields=('environment','operation_id','billing_period','policy_id','policy_sha256','disclosure_sha256','merchant_id','location_id','variation_id','amount_minor','currency','provider_idempotency_key','return_state','created_at')
   bound=('payment_link_id','order_template_id','subscription_id','customer_id','request_sha256','request_body')
   old=type(self).objects.filter(pk=self.pk).values('parent_id',*fields,*bound).first()
   if old and (any(old[k]!=getattr(self,k) for k in fields) or self.parent_id is not None and self.parent_id!=old['parent_id']):
    raise ValidationError('A hosted checkout cannot change owner or contract.')
   if old and any(old[k] and old[k]!=getattr(self,k) for k in bound):
    raise ValidationError('Frozen hosted provider ownership or request cannot change.')
  return super().save(*args,**kwargs)


class SquareHostedPaymentProof(models.Model):
 id=models.UUIDField(primary_key=True,default=uuid.uuid4,editable=False)
 attempt=models.ForeignKey(SquareHostedAttempt,on_delete=models.PROTECT,related_name='payment_proofs')
 environment=models.CharField(max_length=16,default='sandbox',db_index=True)
 invoice_id=models.CharField(max_length=192)
 payment_id=models.CharField(max_length=192)
 order_id=models.CharField(max_length=192)
 amount_minor=models.PositiveIntegerField()
 refunded_minor=models.PositiveIntegerField(default=0)
 status=models.CharField(max_length=24)
 captured_at=models.DateTimeField(null=True,blank=True)
 valid_until=models.DateTimeField(null=True,blank=True)
 payment_updated_at=models.DateTimeField()
 canonical_sha256=models.CharField(max_length=64)
 payment_evidence=models.JSONField(default=dict)
 revoked_at=models.DateTimeField(null=True,blank=True)
 observed_at=models.DateTimeField(default=timezone.now)
 class Meta:
  indexes=[models.Index(fields=('attempt','environment','status','valid_until'),name='hosted_current_proof')]
  constraints=[models.CheckConstraint(condition=models.Q(environment__in=('sandbox','production')),name='hosted_proof_environment'),
   models.UniqueConstraint(fields=('environment','payment_id'),name='hosted_unique_payment'),
   models.UniqueConstraint(fields=('environment','invoice_id'),name='hosted_unique_invoice')]
 def save(self,*args,**kwargs):
  if not SquareHostedAttempt.objects.filter(pk=self.attempt_id,environment=self.environment).exists():
   raise ValidationError('Hosted proof environment does not match its attempt.')
  if not self._state.adding:
   old=type(self).objects.filter(pk=self.pk).values().first()
   fields=('environment','attempt_id','invoice_id','payment_id','order_id','amount_minor')
   if old and (any(old[k]!=getattr(self,k) for k in fields) or old['captured_at'] is not None and (old['captured_at']!=self.captured_at or old['valid_until']!=self.valid_until)):
    raise ValidationError('A hosted payment cannot change its owner or paid period.')
  return super().save(*args,**kwargs)


class SquareHostedCancellation(models.Model):
 id=models.UUIDField(primary_key=True,default=uuid.uuid4,editable=False)
 attempt=models.OneToOneField(SquareHostedAttempt,on_delete=models.PROTECT,related_name='cancellation_job')
 environment=models.CharField(max_length=16,default='sandbox',db_index=True)
 state=models.CharField(max_length=24,default='pending')
 cancel_dispatched_at=models.DateTimeField(null=True,blank=True)
 verified_at=models.DateTimeField(null=True,blank=True)
 created_at=models.DateTimeField(default=timezone.now)
 class Meta:
  indexes=[models.Index(fields=('environment','state','created_at'),name='hosted_cancel_pending')]
  constraints=[models.CheckConstraint(condition=models.Q(environment__in=('sandbox','production')),name='hosted_cancel_environment')]
 def save(self,*args,**kwargs):
  if not SquareHostedAttempt.objects.filter(pk=self.attempt_id,environment=self.environment).exists():raise ValidationError('Cancellation belongs to another environment.')
  if not self._state.adding:
   old=type(self).objects.filter(pk=self.pk).values('environment','attempt_id').first()
   if old and (old['environment']!=self.environment or old['attempt_id']!=self.attempt_id):raise ValidationError('Cancellation cannot move its owned provider scope.')
  return super().save(*args,**kwargs)
