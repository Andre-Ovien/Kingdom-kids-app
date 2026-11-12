"""Short-lived checkout handoffs; never store an app token or raw code."""
import uuid

from django.conf import settings
from django.core.exceptions import ValidationError
from django.db import models
from django.utils import timezone


class ParentCheckoutHandoff(models.Model):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    parent = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE,
                               related_name='checkout_handoffs')
    environment = models.CharField(max_length=16, default='sandbox')
    purpose = models.CharField(max_length=16)
    billing_period = models.CharField(max_length=16, blank=True)
    origin = models.URLField(max_length=512)
    code_digest = models.CharField(max_length=64, unique=True)
    parent_auth_fingerprint = models.CharField(max_length=64)
    created_at = models.DateTimeField(default=timezone.now)
    expires_at = models.DateTimeField()
    origin_access_expires_at = models.DateTimeField()
    consumed_at = models.DateTimeField(null=True, blank=True)
    session_expires_at = models.DateTimeField(null=True, blank=True)
    revoked_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        indexes = [models.Index(fields=('expires_at',), name='checkout_handoff_expiry'),
                   models.Index(fields=('parent', 'environment', 'created_at'), name='checkout_handoff_parent')]
        constraints = [
            models.CheckConstraint(condition=models.Q(environment__in=('sandbox', 'production')),
                                   name='checkout_handoff_environment'),
            models.CheckConstraint(condition=(models.Q(purpose='purchase', billing_period__in=('monthly', 'yearly'))
                | models.Q(purpose='manage', billing_period='')), name='checkout_handoff_purpose'),
            models.CheckConstraint(condition=models.Q(expires_at__gt=models.F('created_at')),
                                   name='checkout_handoff_positive_ttl'),
            models.CheckConstraint(condition=(models.Q(session_expires_at__isnull=True)
                | models.Q(session_expires_at__lte=models.F('origin_access_expires_at'))),
                                   name='checkout_session_origin_bound'),
        ]

    def save(self, *args, **kwargs):
        if not self._state.adding:
            old = type(self).objects.filter(pk=self.pk).values().first()
            immutable = ('parent_id', 'environment', 'purpose', 'billing_period', 'origin', 'code_digest',
                         'parent_auth_fingerprint', 'created_at', 'expires_at', 'origin_access_expires_at')
            if old and (any(old[field] != getattr(self, field) for field in immutable)
                        or (old['session_expires_at'] is not None
                            and old['session_expires_at'] != self.session_expires_at)):
                raise ValidationError('A checkout handoff cannot be reassigned or extended.')
        self.full_clean()
        return super().save(*args, **kwargs)
