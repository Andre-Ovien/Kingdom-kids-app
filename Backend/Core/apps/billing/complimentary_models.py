"""Finite operator-authorized access, separate from every payment/provider ledger."""
import uuid
from datetime import datetime, timedelta
from django.conf import settings
from django.core.exceptions import ValidationError
from django.db import models
from django.utils import timezone
from .plans import ALL_CONTENT_FEATURE


class ParentComplimentaryAccessGrant(models.Model):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    parent = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.SET_NULL, null=True,
                               related_name='complimentary_access_grants')
    environment = models.CharField(max_length=16, default='sandbox', db_index=True)
    feature_code = models.CharField(max_length=64, default=ALL_CONTENT_FEATURE)
    request_reference = models.UUIDField(unique=True)
    owner_sha256 = models.CharField(max_length=64)
    valid_from = models.DateTimeField(default=timezone.now)
    valid_until = models.DateTimeField()
    authorized_by = models.CharField(max_length=96)
    reason_code = models.CharField(max_length=64)
    created_at = models.DateTimeField(default=timezone.now)
    revoked_at = models.DateTimeField(null=True, blank=True)
    revocation_reference = models.UUIDField(null=True, blank=True, unique=True)
    revoked_by = models.CharField(max_length=96, blank=True)

    class Meta:
        indexes = [models.Index(fields=('parent', 'environment', 'feature_code', 'valid_until'),
                                name='complimentary_owned_access')]
        constraints = [
            models.CheckConstraint(condition=models.Q(environment__in=('sandbox', 'production')),
                                   name='complimentary_environment'),
            models.CheckConstraint(condition=models.Q(feature_code=ALL_CONTENT_FEATURE),
                                   name='complimentary_all_content'),
            models.CheckConstraint(condition=models.Q(valid_until__gt=models.F('valid_from')),
                                   name='complimentary_finite_period'),
            models.CheckConstraint(condition=(models.Q(revoked_at__isnull=True, revocation_reference__isnull=True, revoked_by='')
                | (models.Q(revoked_at__isnull=False, revocation_reference__isnull=False) & ~models.Q(revoked_by=''))),
                                   name='complimentary_revocation_audit'),
        ]

    def clean(self):
        for value in (self.valid_from, self.valid_until, self.created_at, self.revoked_at):
            if value is not None and (not isinstance(value, datetime) or timezone.is_naive(value)):
                raise ValidationError('Complimentary access requires aware finite timestamps.')
        if self.valid_from and self.valid_until and self.valid_until - self.valid_from > timedelta(days=30):
            raise ValidationError('Complimentary test access is limited to thirty days.')

    def save(self, *args, **kwargs):
        if not self._state.adding:
            old = type(self).objects.filter(pk=self.pk).values().first()
            frozen = ('environment', 'feature_code', 'request_reference', 'owner_sha256', 'valid_from',
                      'valid_until', 'authorized_by', 'reason_code', 'created_at')
            if old and (any(old[name] != getattr(self, name) for name in frozen)
                        or self.parent_id is not None and self.parent_id != old['parent_id']):
                raise ValidationError('A complimentary authorization cannot change owner, scope or period.')
            if old and old['revoked_at'] is not None and any(old[name] != getattr(self, name)
                    for name in ('revoked_at', 'revocation_reference', 'revoked_by')):
                raise ValidationError('A complimentary revocation cannot be undone or replaced.')
        self.full_clean()
        return super().save(*args, **kwargs)
