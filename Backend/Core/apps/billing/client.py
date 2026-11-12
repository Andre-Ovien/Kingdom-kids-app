"""Backend client seam; no default network transport or checkout dispatcher."""
from dataclasses import dataclass, field
import json
from typing import Protocol
from uuid import UUID
from urllib.parse import quote, urlencode

from django.core.exceptions import ValidationError
from django.core.validators import validate_email
from django.views.decorators.debug import sensitive_variables

from .configuration import provider_identifier, square_configuration, SquareConfigurationError, SquareDisabled
from .parsing import strict_json


SANDBOX_ORIGIN = 'https://connect.squareupsandbox.com'
PRODUCTION_ORIGIN = 'https://connect.squareup.com'


class SquareClientError(Exception):
    pass


class SquareResourceNotFound(SquareClientError):
    """A canonical GET returned404; no provider body or URL is retained."""


@dataclass(frozen=True)
class SquareHttpResult:
    status_code: int
    body: bytes = field(repr=False)


class SquareTransport(Protocol):
    def send(self, *, method, url, headers, body, timeout_seconds, max_response_bytes) -> SquareHttpResult:
        """Transport must enforce bounds and never follow credential-bearing redirects."""


class SquareSandboxClient:
    environment = 'sandbox'
    origin = SANDBOX_ORIGIN
    def __init__(self, transport=None):
        self.transport = transport

    def _authorize_operation(self, method, path, payload=None):
        if self.environment != 'production':
            return
        if path.startswith(('/v2/subscriptions', '/v2/online-checkout', '/v2/catalog', '/v2/invoices')):
            raise SquareDisabled('Historical subscription adapters are Sandbox only.')
        if method == 'GET':
            return
        from django.conf import settings
        from .configuration import require_checkout_enabled, require_production_qualified
        require_production_qualified()
        if getattr(settings, 'SQUARE_PRODUCTION_TERM_BILLING_ENABLED', False) is not True:
            raise SquareDisabled('Production financial operations are disabled.')
        if method != 'POST' or path not in {'/v2/payments', '/v2/customers', '/v2/cards'}:
            raise SquareDisabled('Production operation is outside the reviewed payment adapter.')
        if path == '/v2/payments' and isinstance(payload, dict) and payload.get('customer_details', {}).get('customer_initiated') is False:
            if getattr(settings, 'SQUARE_PRODUCTION_RENEWALS_ENABLED', False) is not True:
                raise SquareDisabled('Production renewal dispatch is disabled.')
        else:
            require_checkout_enabled(environment='production')

    @sensitive_variables()
    def _request_result(self, method, path, payload=None, query=None):
        """Fixed-origin, bounded, single-send seam. Never retries mutations.

        Path arguments are constructed only by the typed methods below. A
        transport is explicitly supplied; no production/default network exists.
        """
        config = square_configuration(environment=self.environment)
        self._authorize_operation(method, path, payload)
        if self.transport is None:
            raise SquareClientError('No Square sandbox transport is configured; no request was sent.')
        if method not in {'GET', 'POST', 'DELETE'} or not path.startswith('/v2/') or '?' in path or '#' in path:
            raise SquareClientError('Invalid Square request.')
        try:
            body = json.dumps(payload, separators=(',', ':'), allow_nan=False).encode() if payload is not None else b''
            if len(body) > 65_536:
                raise ValueError
            bound = getattr(self.transport, 'environment', self.environment)
            if isinstance(bound, str) and bound != self.environment:
                raise ValueError
            url = self.origin + path
            if query:
                url += '?' + urlencode(query)
            result = self.transport.send(method=method, url=url,
                headers={'Authorization': 'Bearer ' + config.access_token,
                         'Square-Version': config.api_version, 'Content-Type': 'application/json',
                         'Accept': 'application/json'}, body=body,
                timeout_seconds=config.timeout_seconds, max_response_bytes=config.max_response_bytes)
            if isinstance(result, SquareHttpResult) and result.status_code == 404 and method == 'GET':
                raise SquareResourceNotFound('Square resource is absent.')
            if (not isinstance(result, SquareHttpResult) or type(result.status_code) is not int
                    or not 200 <= result.status_code < 300 or not isinstance(result.body, bytes)
                    or len(result.body) > config.max_response_bytes):
                raise ValueError
            return result
        except SquareResourceNotFound:
            raise
        except Exception:
            raise SquareClientError('Square sandbox request failed or its result is uncertain.') from None

    @sensitive_variables()
    def request(self, method, path, payload=None, query=None):
        """Normal endpoints still require a strict, nonempty JSON object."""
        try:
            result = self._request_result(method, path, payload, query)
            data = strict_json(result.body)
            if not isinstance(data, dict) or data.get('errors'):
                raise ValueError
            return data
        except (SquareResourceNotFound, SquareConfigurationError, SquareDisabled):
            raise
        except Exception:
            raise SquareClientError('Square sandbox request failed or its result is uncertain.') from None

    @staticmethod
    def path_id(value):
        return quote(provider_identifier(value), safe='')

    def retrieve(self, collection, identifier, envelope):
        allowed = {'merchants', 'locations', 'catalog/object', 'subscriptions', 'invoices', 'orders', 'payments', 'refunds', 'cards', 'customers', 'online-checkout/payment-links'}
        if collection not in allowed:
            raise SquareClientError('Unsupported Square resource.')
        data = self.request('GET', '/v2/' + collection + '/' + self.path_id(identifier))
        resource = data.get(envelope)
        if not isinstance(resource, dict) or resource.get('id') != identifier:
            raise SquareClientError('Square resource identity did not match.')
        return resource

    def retrieve_merchant(self, identifier):
        return self.retrieve('merchants', identifier, 'merchant')

    def retrieve_location(self, identifier):
        return self.retrieve('locations', identifier, 'location')

    def retrieve_catalogue_object(self, identifier):
        return self.retrieve('catalog/object', identifier, 'object')

    def retrieve_subscription(self, identifier):
        return self.retrieve('subscriptions', identifier, 'subscription')

    def retrieve_invoice(self, identifier):
        return self.retrieve('invoices', identifier, 'invoice')

    def retrieve_order(self, identifier):
        return self.retrieve('orders', identifier, 'order')

    def retrieve_payment(self, identifier):
        return self.retrieve('payments', identifier, 'payment')

    def retrieve_refund(self, identifier):
        return self.retrieve('refunds', identifier, 'refund')

    def retrieve_card(self, identifier):
        return self.retrieve('cards', identifier, 'card')

    @sensitive_variables()
    def disable_card(self, identifier, *, customer_id):
        """One scoped disable attempt, verified by canonical GET, never a retry.

        Some successful DisableCard responses have no JSON body. That exception
        is limited to this typed operation; generic request parsing stays strict.
        A timeout or empty response never means success by itself.
        """
        config = square_configuration(environment=self.environment)
        identifier = provider_identifier(identifier)
        customer_id = provider_identifier(customer_id, 192)
        def verify_owner(card):
            if (card.get('id') != identifier or card.get('customer_id') != customer_id
                    or card.get('merchant_id') != config.merchant_id
                    or type(card.get('enabled')) is not bool):
                raise SquareClientError('Canonical card ownership/state did not match.')
        before = self.retrieve_card(identifier)
        verify_owner(before)
        if before['enabled'] is False:
            return {'id': identifier, 'enabled': False}
        try:
            result = self._request_result('POST', '/v2/cards/' + self.path_id(identifier) + '/disable', {})
            if result.body.strip():
                data = strict_json(result.body)
                if not isinstance(data, dict) or data.get('errors'):
                    raise SquareClientError('Card disable outcome requires canonical verification.')
        except Exception:
            # No repeated POST: an accepted-but-lost result is resolved by GET.
            pass
        after = self.retrieve_card(identifier)
        verify_owner(after)
        if after['enabled'] is not False:
            raise SquareClientError('Card disable is not canonically verified; do not assume success.')
        return {'id': identifier, 'enabled': False}

    def retrieve_customer(self, identifier):
        return self.retrieve('customers', identifier, 'customer')

    def retrieve_payment_link(self, identifier):
        return self.retrieve('online-checkout/payment-links', identifier, 'payment_link')

    def search_subscriptions(self, *, location_id, customer_id=None, cursor=None):
        payload = {'limit': 100, 'query': {'filter': {'location_ids': [provider_identifier(location_id)]}}}
        if customer_id is not None:
            payload['query']['filter']['customer_ids'] = [provider_identifier(customer_id, 192)]
        if cursor is not None:
            if not isinstance(cursor, str) or not 1 <= len(cursor) <= 4096:
                raise SquareClientError('Invalid Square cursor.')
            payload['cursor'] = cursor
        return self.request('POST', '/v2/subscriptions/search', payload)

    @sensitive_variables()
    def create_card(self, *, customer_id, source_id, idempotency_key, postal_code='94103'):
        if (not isinstance(source_id, str) or not source_id.startswith('cnon:') or not 6 <= len(source_id) <= 16_384
                or any(ord(char) <= 32 or ord(char) == 127 for char in source_id)):
            raise SquareClientError('Invalid tokenized card source.')
        if not isinstance(postal_code, str) or len(postal_code) != 5 or not postal_code.isascii() or not postal_code.isdigit():
            raise SquareClientError('Invalid US Sandbox billing postal code.')
        data = self.request('POST', '/v2/cards', {
            'idempotency_key': str(UUID(str(idempotency_key))), 'source_id': source_id,
            'card': {'customer_id': provider_identifier(customer_id, 192),
                     'billing_address': {'postal_code': postal_code}}})
        card = data.get('card')
        if (not isinstance(card, dict) or card.get('customer_id') != customer_id or card.get('enabled') is not True):
            raise SquareClientError('Square card binding did not match.')
        provider_identifier(card.get('id'))
        return card['id']

    def create_card_from_payment(self, *, customer_id, payment_id, term_id, idempotency_key):
        """Modern Web CHARGE_AND_STORE: store exactly the paid instrument.

        The caller first validates canonical payment state/age/ownership. Do not
        substitute a separately supplied card nonce, postal code or customer.
        """
        data = self.request('POST', '/v2/cards', {
            'idempotency_key': str(UUID(str(idempotency_key))),
            'source_id': provider_identifier(payment_id, 192),
            'card': {'customer_id': provider_identifier(customer_id, 192),
                     'reference_id': str(UUID(str(term_id)))}})
        card = data.get('card')
        if (not isinstance(card, dict) or card.get('customer_id') != customer_id
                or card.get('reference_id') != str(term_id) or card.get('enabled') is not True):
            raise SquareClientError('Square payment-backed card binding did not match.')
        return provider_identifier(card.get('id'))

    def list_cards(self, *, customer_id, cursor=None):
        query = {'customer_id': provider_identifier(customer_id, 192)}
        if cursor:
            if not isinstance(cursor, str) or len(cursor) > 4096:
                raise SquareClientError('Invalid card pagination cursor.')
            query['cursor'] = cursor
        return self.request('GET', '/v2/cards', query=query)

    @sensitive_variables()
    def create_subscription(self, *, location_id, customer_id, card_id, variation_id, idempotency_key):
        raise SquareClientError('Automatic Square Subscription creation is retired; use current capture-bound terms.')

    @sensitive_variables()
    def create_payment_link(self, *, location_id, variation_id, idempotency_key):
        raise SquareClientError('Historical hosted subscription checkout is retired and cannot create a payment link.')

    def cancel_subscription(self, identifier):
        # Square exposes no idempotency_key for this endpoint. The leased
        # cancellation outbox reads canonical state before any retry and verifies
        # the scheduled canceled_date after the single request.
        return self.request('POST', '/v2/subscriptions/' + self.path_id(identifier) + '/cancel')

    def delete_payment_link(self, identifier):
        return self.request('DELETE', '/v2/online-checkout/payment-links/' + self.path_id(identifier))

    @sensitive_variables()
    def create_term_payment(self, *, term_id, location_id, customer_id, card_id,
                            idempotency_key, buyer_present, verification_token=None, charge_source_id=None, amount_minor=999):
        if type(amount_minor) is not int or amount_minor not in {999, 9990}:
            raise SquareClientError('Payment amount is outside the reviewed commercial plans.')
        source = provider_identifier(card_id) if charge_source_id is None else charge_source_id
        if charge_source_id is not None:
            if (not buyer_present or verification_token is not None or card_id
                    or not isinstance(source, str) or not source.startswith('cnon:')
                    or not 6 <= len(source) <= 16_384
                    or any(ord(c) <= 32 or ord(c) == 127 for c in source)):
                raise SquareClientError('Invalid modern Web payment source.')
        payload = {'idempotency_key': str(UUID(str(idempotency_key))),
            'reference_id': str(UUID(str(term_id))), 'source_id': source,
            'customer_id': provider_identifier(customer_id, 192),
            'location_id': provider_identifier(location_id, 192),
            'amount_money': {'amount': amount_minor, 'currency': 'USD'}, 'autocomplete': True,
            'customer_details': {'customer_initiated': bool(buyer_present)}}
        if verification_token is not None:
            if (not isinstance(verification_token, str) or not 1 <= len(verification_token) <= 16_384
                    or any(ord(char) <= 32 or ord(char) == 127 for char in verification_token)):
                raise SquareClientError('Invalid buyer verification token.')
            payload['verification_token'] = verification_token
        return self.request('POST', '/v2/payments', payload)

    def list_payments(self, *, location_id, begin_time, end_time, cursor=None):
        query = {'location_id': provider_identifier(location_id, 192), 'begin_time': begin_time,
                 'end_time': end_time, 'limit': 100, 'sort_order': 'ASC'}
        if cursor:
            if not isinstance(cursor, str) or len(cursor) > 4096:
                raise SquareClientError('Invalid payment pagination cursor.')
            query['cursor'] = cursor
        return self.request('GET', '/v2/payments', query=query)

    @sensitive_variables()
    def create_customer(self, *, email_address, reference_id, idempotency_key):
        config = square_configuration(environment=self.environment)
        self._authorize_operation('POST', '/v2/customers')
        if self.transport is None:
            raise SquareClientError('No Square sandbox transport is configured; no request was sent.')
        try:
            validate_email(email_address)
            if not isinstance(email_address, str) or len(email_address) > 254:
                raise ValueError
            if not isinstance(reference_id, str) or not 1 <= len(reference_id) <= 100:
                raise ValueError
            key = str(UUID(str(idempotency_key)))
        except (ValidationError, TypeError, ValueError):
            raise SquareClientError('Invalid customer operation input.') from None
        # Deliberately no subscription/card/payment mutation in this foundation.
        body = json.dumps({'email_address': email_address, 'reference_id': reference_id,
                           'idempotency_key': key}, separators=(',', ':')).encode()
        try:
            bound = getattr(self.transport, 'environment', self.environment)
            if isinstance(bound, str) and bound != self.environment:
                raise ValueError
            result = self.transport.send(method='POST', url=self.origin + '/v2/customers',
                headers={'Authorization': 'Bearer ' + config.access_token,
                         'Square-Version': config.api_version, 'Content-Type': 'application/json',
                         'Accept': 'application/json'}, body=body,
                timeout_seconds=config.timeout_seconds, max_response_bytes=config.max_response_bytes)
            if (not isinstance(result, SquareHttpResult) or not isinstance(result.body, bytes)
                    or len(result.body) > config.max_response_bytes or not 200 <= result.status_code < 300):
                raise ValueError
            payload = strict_json(result.body)
            if not isinstance(payload, dict) or not isinstance(payload.get('customer'), dict):
                raise ValueError
            if self.environment == 'production' and payload['customer'].get('reference_id') != reference_id:
                raise ValueError
            customer_id = payload['customer'].get('id')
            if not isinstance(customer_id, str) or not 1 <= len(customer_id) <= 192:
                raise ValueError
            customer_id.encode('utf-8')
            if any(ord(character) <= 32 or ord(character) == 127 for character in customer_id):
                raise ValueError
            return customer_id
        except Exception:
            # Never surface a bearer token, raw provider error/body or PII.
            # A timeout is ambiguous: retry only the SAME stored operation key.
            raise SquareClientError('Square sandbox request failed or its result is uncertain.') from None


class SquareProductionClient(SquareSandboxClient):
    """Same reviewed protocol with an immutable, separate production endpoint."""
    environment = 'production'
    origin = PRODUCTION_ORIGIN
