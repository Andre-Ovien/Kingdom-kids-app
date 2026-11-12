"""Mock-only tests: no keys, DNS, socket, provider or database calls."""
from unittest.mock import Mock, patch
from django.test import SimpleTestCase, override_settings
from . import http_transport as transport
from .client import SquareClientError
HEADERS = {'Authorization': 'Bearer synthetic-not-a-real-token', 'Square-Version': '2026-09-16',
           'Content-Type': 'application/json', 'Accept': 'application/json'}


@override_settings(SQUARE_SANDBOX_ENABLED=True, SQUARE_ENVIRONMENT="sandbox",
    SQUARE_SANDBOX_HTTP_TRANSPORT_ENABLED=True)
class TransportTests(SimpleTestCase):
    def send(self, **overrides):
        return transport.SandboxTransport().send(**{
            'method': 'POST', 'url': 'https://connect.squareupsandbox.com/v2/payments',
            'headers': HEADERS, 'body': b'{"synthetic":true}',
            'timeout_seconds': 5, 'max_response_bytes': 1024, **overrides})

    def test_no_production_redirect_origin_or_cleartext_connection(self):
        with patch.object(transport.http.client, 'HTTPSConnection', side_effect=AssertionError('Unexpected connection')) as factory:
            for url in ['https://connect.squareup.com/v2/payments', 'http://connect.squareupsandbox.com/v2/payments',
                        'https://connect.squareupsandbox.com.evil.invalid/v2/payments',
                        'https://user:secret@connect.squareupsandbox.com/v2/payments',
                        'https://connect.squareupsandbox.com/v2/../other']:
                with self.assertRaises(SquareClientError): self.send(url=url)
            factory.assert_not_called()

    def test_single_send_default_tls_no_debug_or_proxy_and_always_close(self):
        connection = Mock(); connection.sock = None
        response = connection.getresponse.return_value
        response.status = 200; response.read.return_value = b'{"payment":{"id":"synthetic"}}'
        context = object()
        with patch.object(transport.ssl, 'create_default_context', return_value=context), \
                patch.object(transport.http.client, 'HTTPSConnection', return_value=connection) as factory:
            result = self.send()
        factory.assert_called_once_with('connect.squareupsandbox.com', timeout=5, context=context)
        connection.set_debuglevel.assert_called_once_with(0)
        connection.request.assert_called_once(); response.read.assert_called_once_with(1025)
        self.assertEqual(result.status_code, 200); connection.close.assert_called_once()

    def test_redirect_is_refused_without_second_send_or_body_read(self):
        connection = Mock(); connection.sock = None
        connection.getresponse.return_value.status = 307
        with patch.object(transport.ssl, 'create_default_context', return_value=object()), \
                patch.object(transport.http.client, 'HTTPSConnection', return_value=connection):
            with self.assertRaises(SquareClientError): self.send()
        connection.request.assert_called_once()
        connection.getresponse.return_value.read.assert_not_called()
        connection.close.assert_called_once()

    def test_response_cap_and_errors_do_not_leak_or_retry(self):
        connection = Mock(); connection.sock = None
        response = connection.getresponse.return_value
        response.status = 200; response.read.return_value = b'x' * 1025
        with patch.object(transport.ssl, 'create_default_context', return_value=object()), \
                patch.object(transport.http.client, 'HTTPSConnection', return_value=connection):
            with self.assertRaises(SquareClientError) as error: self.send()
        self.assertNotIn('synthetic-not-a-real-token', str(error.exception))
        connection.request.assert_called_once(); connection.close.assert_called_once()

    def test_request_budget_and_header_injection_refused_before_connect(self):
        with patch.object(transport.http.client, 'HTTPSConnection', side_effect=AssertionError('Unexpected connection')) as factory:
            for values in [{'body': b'x' * 65537}, {'timeout_seconds': 16},
                           {'max_response_bytes': 1048577},
                           {'headers': {**HEADERS, 'Authorization': 'Bearer synthetic\r\nInjected: secret'}}]:
                with self.assertRaises(SquareClientError): self.send(**values)
            factory.assert_not_called()



@override_settings(SQUARE_SANDBOX_ENABLED=True,SQUARE_ENVIRONMENT='sandbox',
                   SQUARE_SANDBOX_HTTP_TRANSPORT_ENABLED=False)
class TransportConfigurationTests(SimpleTestCase):
    def test_builtin_disabled_and_production_send_never_connect(self):
        with patch.object(transport.http.client,'HTTPSConnection') as factory:
            with self.assertRaises(SquareClientError):TransportTests().send()
            with override_settings(SQUARE_SANDBOX_HTTP_TRANSPORT_ENABLED=True,SQUARE_ENVIRONMENT='production'):
                with self.assertRaises(SquareClientError):TransportTests().send()
            factory.assert_not_called()
    def test_configured_client_requires_optin_or_explicit_callable_no_string_import(self):
        from .configuration import configured_client,SquareConfigurationError
        from .test_checkout import CHECKOUT_CONFIG
        with override_settings(**CHECKOUT_CONFIG):
            with self.assertRaises(SquareConfigurationError):configured_client()
            with override_settings(SQUARE_SANDBOX_HTTP_TRANSPORT_ENABLED=True):
                self.assertIsInstance(configured_client().transport,transport.SandboxTransport)
            fake=Mock()
            with override_settings(SQUARE_SANDBOX_TRANSPORT_FACTORY=lambda:fake):
                self.assertIs(configured_client().transport,fake)
            with override_settings(SQUARE_SANDBOX_TRANSPORT_FACTORY='os.system'), patch(
                    'django.utils.module_loading.import_string',side_effect=AssertionError('No arbitrary import')):
                with self.assertRaises(SquareConfigurationError):configured_client()
            with override_settings(SQUARE_ENVIRONMENT='production',SQUARE_SANDBOX_HTTP_TRANSPORT_ENABLED=True):
                with self.assertRaises(SquareConfigurationError):configured_client()
    def test_deadline_aborts_socket_and_cleanup_cancels_timer_even_on_failure(self):
        connection=Mock();active=Mock();connection.sock=active;response=connection.getresponse.return_value
        response.status=200;timer=Mock();abort=[]
        def make_timer(duration,callback):
            self.assertEqual(duration,12);abort.append(callback);return timer
        def slow_read(limit):
            abort[0]();raise TimeoutError('Synthetic private data must not escape')
        response.read.side_effect=slow_read
        with override_settings(SQUARE_SANDBOX_HTTP_TRANSPORT_ENABLED=True), \
                patch.object(transport.http.client,'HTTPSConnection',return_value=connection), \
                patch.object(transport,'Timer',side_effect=make_timer):
            with self.assertRaises(SquareClientError) as error:TransportTests().send()
        self.assertNotIn('private data',str(error.exception));active.shutdown.assert_called_once()
        timer.start.assert_called_once();timer.cancel.assert_called_once()
        self.assertTrue(timer.daemon);self.assertGreaterEqual(connection.close.call_count,1)
        connection.request.assert_called_once()
