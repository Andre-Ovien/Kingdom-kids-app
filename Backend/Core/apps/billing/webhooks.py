"""Signature-checked, deduplicated inbox. Does not apply provider/account state."""
import base64
import hashlib
import hmac
from django.views.decorators.debug import sensitive_variables

from .models import SquareWebhookReceipt
from .parsing import strict_json


class SquareWebhookInvalid(Exception):
    pass


class SquareWebhookConflict(Exception):
    pass


@sensitive_variables()
def valid_signature(*, raw_body, signature, configuration):
    if not isinstance(signature, str) or len(signature) != 44:
        return False
    expected = base64.b64encode(hmac.new(configuration.signature_key.encode('utf-8'),
        configuration.notification_url.encode('utf-8') + raw_body, hashlib.sha256).digest())
    try:
        return hmac.compare_digest(signature.encode('ascii'), expected)
    except UnicodeEncodeError:
        return False


@sensitive_variables()
def record_notification(*, raw_body, configuration):
    """Called only after signature verification; no webhook parent ID is trusted."""
    try:
        payload = strict_json(raw_body)
        if not isinstance(payload, dict):
            raise ValueError
        metadata = {}
        for key, maximum in (('merchant_id', 192), ('event_id', 128), ('type', 128)):
            value = payload.get(key)
            if not isinstance(value, str) or not 1 <= len(value) <= maximum or value != value.strip():
                raise ValueError
            value.encode('utf-8')
            if any(ord(character) < 32 or ord(character) == 127 for character in value):
                raise ValueError
            metadata[key] = value
        if metadata['merchant_id'] != configuration.merchant_id:
            raise SquareWebhookInvalid('Unexpected sandbox merchant.')
        data = payload.get('data', {})
        object_id = data.get('id', '') if isinstance(data, dict) else ''
        if not isinstance(object_id, str) or len(object_id) > 255:
            raise ValueError
        object_id.encode('utf-8')
        if any(ord(character) < 32 or ord(character) == 127 for character in object_id):
            raise ValueError
    except (ValueError, UnicodeDecodeError, RecursionError, TypeError):
        raise SquareWebhookInvalid('Invalid signed Square event envelope.') from None
    digest = hashlib.sha256(raw_body).hexdigest()
    receipt, created = SquareWebhookReceipt.objects.get_or_create(
        merchant_id=metadata['merchant_id'], event_id=metadata['event_id'],
        defaults={'event_type': metadata['type'], 'object_id': object_id, 'body_sha256': digest})
    if receipt.body_sha256 != digest:
        raise SquareWebhookConflict('Conflicting duplicate event requires reconciliation.')
    return created
