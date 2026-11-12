"""Django mail over Resend HTTPS; fixed origin, no automatic retries or logging."""
from email.utils import parseaddr
import http.client
import json
import re
import ssl
import uuid

from django.conf import settings
from django.core.exceptions import ImproperlyConfigured, ValidationError
from django.core.mail.backends.base import BaseEmailBackend
from django.core.validators import validate_email
from django.views.decorators.debug import sensitive_variables


class ResendDeliveryError(RuntimeError):
    """Safe to expose to application logs; never contains provider content."""


def sender_address(value):
    if not isinstance(value, str) or len(value) > 320 or any(ord(c) < 32 or ord(c) == 127 for c in value):
        raise ImproperlyConfigured('Configure a valid verified Resend sender.')
    try:
        _, address = parseaddr(value, strict=True)
        validate_email(address)
    except (ValueError, ValidationError):
        raise ImproperlyConfigured('Configure a valid verified Resend sender.') from None
    return address


@sensitive_variables()
def validate_configuration():
    key = getattr(settings, 'RESEND_API_KEY', '')
    domain = getattr(settings, 'RESEND_VERIFIED_DOMAIN', '')
    sender = sender_address(settings.DEFAULT_FROM_EMAIL)
    timeout = getattr(settings, 'EMAIL_TIMEOUT', 10)
    if (not isinstance(key, str) or not 16 <= len(key) <= 256 or not key.isascii()
            or any(ord(c) <= 32 or ord(c) == 127 for c in key)):
        raise ImproperlyConfigured('Configure the server-only Resend sending key.')
    if (not isinstance(domain, str) or not re.fullmatch(r'[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?', domain)
            or domain in {'localhost', 'resend.dev'} or '..' in domain
            or sender.rsplit('@', 1)[1].lower() != domain):
        raise ImproperlyConfigured('RESEND_VERIFIED_DOMAIN must match the verified sender domain.')
    if type(timeout) not in (int, float) or not 1 <= timeout <= 30:
        raise ImproperlyConfigured('Resend HTTPS timeout must be between 1 and 30 seconds.')
    return key, sender, timeout


class EmailBackend(BaseEmailBackend):
    @sensitive_variables()
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.api_key, self.sender, self.timeout = validate_configuration()

    def open(self):
        # No connection/authentication claim: an API send is a separate action.
        return False

    def close(self):
        return None

    @sensitive_variables()
    def send_messages(self, email_messages):
        sent = 0
        for message in email_messages or ():
            try:
                if self._send(message):
                    sent += 1
            except Exception:
                if not self.fail_silently:
                    raise ResendDeliveryError('Email delivery could not be confirmed. Please retry later.') from None
        return sent

    @sensitive_variables()
    def _send(self, message):
        if not message.recipients():
            return False
        if sender_address(message.from_email) != self.sender or message.attachments:
            raise ResendDeliveryError('Unsupported email sender or attachment.')
        if not isinstance(message.subject, str) or len(message.subject) > 998 or any(c in message.subject for c in '\r\n'):
            raise ResendDeliveryError('Invalid email subject.')
        payload = {'from': settings.DEFAULT_FROM_EMAIL, 'subject': message.subject}
        for field in ('to', 'cc', 'bcc', 'reply_to'):
            addresses = getattr(message, field, [])
            if addresses:
                if len(addresses) > 50:
                    raise ResendDeliveryError('Too many email recipients.')
                for address in addresses:
                    sender_address(address)
                payload[field] = list(addresses)
        if message.content_subtype == 'html':
            payload['html'] = message.body
        else:
            payload['text'] = message.body
        for alternative in getattr(message, 'alternatives', ()):
            if alternative.mimetype == 'text/html':
                payload['html'] = alternative.content
            else:
                raise ResendDeliveryError('Unsupported email alternative.')
        body = json.dumps(payload, ensure_ascii=False, allow_nan=False).encode('utf-8')
        if len(body) > 256 * 1024:
            raise ResendDeliveryError('Email exceeds the delivery size limit.')
        key = message.extra_headers.get('Resend-Idempotency-Key') or getattr(message, '_resend_idempotency_key', None)
        if key is None:
            key = str(uuid.uuid4())
            message._resend_idempotency_key = key
        if not isinstance(key, str) or not re.fullmatch(r'[A-Za-z0-9._/-]{1,256}', key):
            raise ResendDeliveryError('Invalid email operation key.')
        connection = http.client.HTTPSConnection('api.resend.com', port=443, timeout=self.timeout,
                                                 context=ssl.create_default_context())
        connection.set_debuglevel(0)
        try:
            connection.request('POST', '/emails', body=body, headers={
                'Authorization': 'Bearer ' + self.api_key,
                'Content-Type': 'application/json', 'Accept': 'application/json',
                'Idempotency-Key': key,
            })
            response = connection.getresponse()
            raw = response.read(65537)
            if response.status != 200 or len(raw) > 65536:
                raise ResendDeliveryError('Email delivery was not accepted.')
            result = json.loads(raw)
            if not isinstance(result, dict) or not isinstance(result.get('id'), str) or not 1 <= len(result['id']) <= 128:
                raise ResendDeliveryError('Invalid email delivery acknowledgement.')
        finally:
            connection.close()
        return True
