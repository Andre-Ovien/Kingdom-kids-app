"""Explicit privileged grant/revoke operations; no public endpoint or provider I/O."""
import hashlib
import re
from uuid import UUID
from datetime import datetime, timedelta
from django.contrib.auth import get_user_model
from django.db import transaction
from django.db.models import Q
from django.db.models.functions import Least, Coalesce
from django.utils import timezone
from django.utils.crypto import constant_time_compare
from .complimentary_models import ParentComplimentaryAccessGrant
from .models import SquareHostedAttempt, SquareContentAgreement, SquareBillingTerm, SquareCheckoutIntent
from .plans import ALL_CONTENT_FEATURE

REASON = 'user_requested_test_access'


from .complimentary_errors import ComplimentaryRejected


def owner_fingerprint(parent):
    return hashlib.sha256((str(parent.pk) + ':' + parent.email.strip().lower()).encode()).hexdigest()


def _uuid(value):
    try:
        parsed = UUID(str(value))
        if str(parsed) != str(value): raise ValueError
        return parsed
    except (ValueError, TypeError, AttributeError):
        raise ComplimentaryRejected('An explicit canonical operation reference is required.') from None


def _eligible(parent):
    return bool(parent and parent.pk is not None and parent.is_authenticated and parent.is_active and parent.is_email_verified
                and not parent.is_staff and not parent.is_superuser)


def _owner(parent_id, expected_owner_sha256):
    if type(parent_id) is not int or not 1 <= parent_id <= 9223372036854775807:
        raise ComplimentaryRejected('An exact numeric parent is required.', code='invalid_owner')
    if not isinstance(expected_owner_sha256, str) or not re.fullmatch('[a-f0-9]{64}', expected_owner_sha256):
        raise ComplimentaryRejected('An approved owner fingerprint is required.', code='invalid_owner')
    parent = get_user_model().objects.select_for_update().filter(pk=parent_id).first()
    if not _eligible(parent) or not constant_time_compare(owner_fingerprint(parent), expected_owner_sha256):
        raise ComplimentaryRejected('The approved active verified parent did not match.', code='invalid_owner')
    return parent


def _operator(value):
    if not isinstance(value, str) or not re.fullmatch('[A-Za-z0-9_-]{1,96}', value):
        raise ComplimentaryRejected('A non-personal operator reference is required.')
    return value


def _no_unresolved_financial_work(parent, environment):
    # Do not hide a live provider obligation or an in-flight checkout behind a
    # complimentary-only presentation. These ledgers are never altered here.
    if SquareCheckoutIntent.objects.filter(parent=parent, environment=environment, is_open=True).exists():
        raise ComplimentaryRejected('Owned earlier checkout must be resolved before complimentary access.', code='unresolved_financial_work')
    hosted = SquareHostedAttempt.objects.filter(parent=parent, environment=environment)
    if hosted.filter(Q(renewals_enabled=True) | (Q(is_open=True) & ~Q(request_body={}))).exists():
        raise ComplimentaryRejected('Owned checkout or renewal must be resolved before complimentary access.', code='unresolved_financial_work')
    if SquareContentAgreement.objects.filter(parent=parent, environment=environment, renewals_enabled=True).exists():
        raise ComplimentaryRejected('Owned renewals must be resolved before complimentary access.', code='unresolved_financial_work')
    if SquareBillingTerm.objects.filter(environment=environment, agreement__parent=parent,
            agreement__environment=environment).exclude(state__in=('paid', 'failed', 'refunded', 'canceled')).exists():
        raise ComplimentaryRejected('Owned payment uncertainty must be resolved before complimentary access.', code='unresolved_financial_work')


def grant_access(*, parent_id, environment, request_reference, owner_sha256, valid_until,
                 authorized_by, reason_code, apply=False):
    if environment not in {'sandbox', 'production'} or reason_code != REASON:
        raise ComplimentaryRejected('The approved environment and test-access reason are required.', code='invalid_profile')
    reference = _uuid(request_reference); operator = _operator(authorized_by)
    if not isinstance(valid_until, datetime) or timezone.is_naive(valid_until):
        raise ComplimentaryRejected('An explicit aware expiry is required.', code='invalid_expiry')
    with transaction.atomic():
        parent = _owner(parent_id, owner_sha256)
        existing = ParentComplimentaryAccessGrant.objects.select_for_update().filter(request_reference=reference).first()
        if existing:
            if (existing.parent_id != parent.pk or existing.environment != environment or existing.owner_sha256 != owner_sha256
                    or existing.valid_until != valid_until or existing.authorized_by != operator or existing.reason_code != reason_code):
                raise ComplimentaryRejected('This operation already authorizes a different immutable grant.', code='grant_conflict')
            return existing, False
        now = timezone.now()
        if not now < valid_until <= now + timedelta(days=30):
            raise ComplimentaryRejected('The new expiry must be within the next thirty days.', code='invalid_expiry')
        _no_unresolved_financial_work(parent, environment)
        row = ParentComplimentaryAccessGrant(parent=parent, environment=environment, request_reference=reference,
            owner_sha256=owner_sha256, valid_from=now, valid_until=valid_until,
            authorized_by=operator, reason_code=reason_code)
        if apply: row.save(force_insert=True)
        return row, bool(apply)


def revoke_access(*, parent_id, environment, grant_id, request_reference, owner_sha256, authorized_by, apply=False):
    if environment not in {'sandbox', 'production'}: raise ComplimentaryRejected('A known environment is required.')
    reference = _uuid(request_reference); identifier = _uuid(grant_id); operator = _operator(authorized_by)
    with transaction.atomic():
        parent = _owner(parent_id, owner_sha256)
        row = ParentComplimentaryAccessGrant.objects.select_for_update().filter(pk=identifier,
            parent=parent, environment=environment, owner_sha256=owner_sha256).first()
        if row is None: raise ComplimentaryRejected('The exact owned grant was not found.', code='grant_not_found')
        if row.revoked_at is not None:
            if row.revocation_reference != reference or row.revoked_by != operator:
                raise ComplimentaryRejected('This grant already has another immutable revocation.')
            return row, False
        if apply:
            row.revoked_at = timezone.now(); row.revocation_reference = reference; row.revoked_by = operator
            row.save(update_fields=('revoked_at', 'revocation_reference', 'revoked_by'))
        return row, bool(apply)


def complimentary_coverage_until(parent, *, environment, at=None):
    if environment not in {'sandbox', 'production'} or not _eligible(parent): return None
    now = at if at is not None else timezone.now()
    if timezone.is_naive(now): raise ValueError('Access evaluation requires an aware timestamp.')
    end = ParentComplimentaryAccessGrant.objects.filter(parent=parent, environment=environment,
        feature_code=ALL_CONTENT_FEATURE, valid_from__lte=now, valid_until__gt=now,
        created_at__lte=now).filter(Q(revoked_at__isnull=True) | Q(revoked_at__gt=now)).annotate(
        effective_until=Least('valid_until', Coalesce('revoked_at', 'valid_until'))).order_by('-effective_until').values_list('effective_until', flat=True).first()
    return end
