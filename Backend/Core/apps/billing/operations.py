"""Internal preparation/identity seams; no network dispatch or paid grants."""
import hashlib
import json
from uuid import UUID

from django.db import IntegrityError, transaction
from django.views.decorators.debug import sensitive_variables

from .configuration import square_configuration
from .models import SquareCustomerIdentity, SquareSandboxOperation, SquareSubscriptionIdentity


class SquareOperationConflict(Exception):
    pass


class SquareOwnershipError(Exception):
    pass


def _parent(parent):
    if not parent.pk or not parent.is_active or not parent.is_email_verified:
        raise SquareOwnershipError('A verified active parent is required.')


def _identity(value):
    if (not isinstance(value, str) or not value or len(value) > 192
            or any(ord(character) <= 32 or ord(character) == 127 for character in value)):
        raise SquareOwnershipError('Invalid sandbox identity.')
    try:
        value.encode('utf-8')
    except UnicodeEncodeError:
        raise SquareOwnershipError('Invalid sandbox identity.') from None
    return value


@sensitive_variables()
def reserve_customer_operation(*, parent, operation_id, email_address):
    """Persist a stable key before a future explicit customer call, not during it.

    Caller supplies synthetic sandbox email explicitly; parent.email is never
    automatically sent. No payload/PII is persisted, and no I/O occurs in locks.
    """
    config = square_configuration()
    _parent(parent)
    from django.core.validators import validate_email
    validate_email(email_address)
    operation_id = UUID(str(operation_id))
    body = {'email_address': email_address, 'reference_id': str(parent.pk)}
    digest = hashlib.sha256(json.dumps(body, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    operation, _ = SquareSandboxOperation.objects.get_or_create(
        environment='sandbox', parent=parent, merchant_id=config.merchant_id, operation_id=operation_id,
        defaults={'kind': 'customer.create', 'request_sha256': digest})
    if operation.kind != 'customer.create' or operation.request_sha256 != digest:
        raise SquareOperationConflict('An operation cannot be reused with different input.')
    return operation


def bind_customer_identity(*, parent, customer_id):
    """Trusted backend response-binding seam, never a public caller-supplied ID API."""
    config = square_configuration()
    _parent(parent)
    customer_id = _identity(customer_id)
    try:
        with transaction.atomic():
            identity, _ = SquareCustomerIdentity.objects.get_or_create(
                environment='sandbox', parent=parent, merchant_id=config.merchant_id, defaults={'customer_id': customer_id})
            if identity.customer_id != customer_id:
                raise SquareOwnershipError('A sandbox identity is already bound.')
            return identity
    except IntegrityError:
        raise SquareOwnershipError('Sandbox customer belongs to another parent.') from None


def bind_subscription_identity(*, parent, customer_identity_id, subscription_id):
    config = square_configuration()
    _parent(parent)
    subscription_id = _identity(subscription_id)
    with transaction.atomic():
        customer = SquareCustomerIdentity.objects.filter(
            pk=customer_identity_id, environment='sandbox', parent=parent, merchant_id=config.merchant_id).first()
        if customer is None:
            raise SquareOwnershipError('Sandbox customer not found for this parent.')
        identity, _ = SquareSubscriptionIdentity.objects.get_or_create(
            environment='sandbox', subscription_id=subscription_id, defaults={'customer': customer})
        if identity.customer_id != customer.pk:
            raise SquareOwnershipError('Sandbox subscription belongs to another parent.')
        return identity
