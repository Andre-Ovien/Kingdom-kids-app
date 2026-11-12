"""Future paid-content rollout: disabled until checkout/delivery are ready."""
from contextlib import closing
from django.conf import settings
from django.db.models import Q
from django.utils import timezone
from rest_framework.exceptions import APIException
from rest_framework.permissions import BasePermission

from .models import PAID_CONTENT_PROVIDERS, ParentContentEntitlement, valid_proof_identifier
from .plans import ALL_CONTENT_FEATURE


class PaidContentRequired(APIException):
    status_code = 403
    default_code = 'subscription_required'
    default_detail = {'code': 'subscription_required',
                      'detail': 'An active paid subscription is required.'}


def has_paid_content_access(parent, *, at=None):
    if not settings.PAID_CONTENT_ENFORCEMENT_ENABLED:
        return True  # No new query/restriction in the current rollout.
    return paid_content_access_until(parent, at=at) is not None


def paid_content_access_until(parent, *, at=None):
    """Conservative current-proof expiry for private URL TTL, never future max.

    None also means the rollout is off: callers must not mistake an unrestricted
    development rollout for a verified paid period. A future revocation caps TTL.
    """
    if not settings.PAID_CONTENT_ENFORCEMENT_ENABLED:
        return None
    return verified_paid_coverage_until(parent, environment=settings.PAID_CONTENT_ENTITLEMENT_ENVIRONMENT, at=at)


def verified_paid_coverage_until(parent, *, environment, at=None):
    """Actual current verified proof, independent of rollout/capability flags."""
    if (environment not in {'sandbox', 'production'} or not parent.is_authenticated
            or not parent.is_active or not parent.is_email_verified):
        return None
    now = at if at is not None else timezone.now()
    if timezone.is_naive(now):
        raise ValueError('Entitlement time must be timezone-aware.')
    candidates = ParentContentEntitlement.objects.filter(
        parent=parent, feature_code=ALL_CONTENT_FEATURE, environment=environment,
        provider__in=PAID_CONTENT_PROVIDERS,
        payment_verified_at__lte=now, valid_from__lte=now, valid_until__gt=now,
    ).filter(Q(revoked_at__isnull=True) | Q(revoked_at__gt=now)).only(
        'provider', 'provider_account_id', 'source_reference', 'valid_until', 'revoked_at').order_by('valid_until')
    # Defense against malformed legacy/bulk rows that bypass model validation.
    with closing(candidates.iterator(chunk_size=100)) as rows:
        for row in rows:
            if valid_proof_identifier(row.provider_account_id) and valid_proof_identifier(row.source_reference):
                return min(row.valid_until, row.revoked_at) if row.revoked_at else row.valid_until
    return None


class HasPaidContentAccess(BasePermission):
    def has_permission(self, request, view):
        if not settings.PAID_CONTENT_ENFORCEMENT_ENABLED:
            return True
        if not request.user.is_authenticated:
            return False
        if not has_paid_content_access(request.user):
            raise PaidContentRequired()
        return True
