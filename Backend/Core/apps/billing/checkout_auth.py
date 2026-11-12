"""Checkout-scoped authentication; never add this to global account auth."""
import json
import re

from django.views.decorators.debug import sensitive_variables
from rest_framework.authentication import BaseAuthentication, get_authorization_header
from rest_framework.exceptions import AuthenticationFailed

from .browser_handoff import TOKEN_PREFIX, HandoffUnavailable, authenticate_checkout_session

_INTENT_PATH = re.compile(r'^/api/billing/square/checkout-intents/'
    r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/'
    r'(?P<action>confirm/|prepare-card/|cancel/|restart/)?$')


class CheckoutSessionAuthentication(BaseAuthentication):
    @sensitive_variables()
    def authenticate(self, request):
        parts = get_authorization_header(request).split()
        if not parts or parts[0].lower() != b'bearer':
            return None
        # Ordinary app JWTs continue through the normal verified-parent auth.
        if len(parts) == 2 and not parts[1].startswith(TOKEN_PREFIX.encode('ascii')):
            return None
        try:
            if len(parts) != 2:
                raise HandoffUnavailable()
            token = parts[1].decode('ascii')
            row = authenticate_checkout_session(token=token, request=request)
            path, method = request.path, request.method
            allowed = ((method == 'GET' and path == '/api/billing/content-access/')
                       or (method == 'POST' and path == '/api/billing/checkout-handoffs/revoke/'))
            if path == '/api/billing/square/checkout-intents/':
                allowed = row.purpose == 'purchase' and method in ('GET', 'POST')
            match = _INTENT_PATH.fullmatch(path)
            if match:
                action = match.group('action') or ''
                allowed = (not action and method == 'GET') or (
                    method == 'POST' and action in ('confirm/', 'prepare-card/', 'cancel/', 'restart/'))
                if row.purpose == 'manage' and method == 'POST':
                    allowed = action == 'cancel/'
                    if action == 'confirm/':
                        raw = request.body
                        if len(raw) <= 8192 and request.content_type == 'application/json':
                            data = json.loads(raw.decode('utf-8'))
                            allowed = (isinstance(data, dict) and set(data) == {'password'}
                                and isinstance(data['password'], str) and 1 <= len(data['password']) <= 1024)
            if not allowed:
                raise HandoffUnavailable()
            return row.parent, row
        except (HandoffUnavailable, UnicodeError, ValueError, TypeError):
            raise AuthenticationFailed('Checkout session is unavailable or expired.') from None

    def authenticate_header(self, request):
        return 'Bearer'
