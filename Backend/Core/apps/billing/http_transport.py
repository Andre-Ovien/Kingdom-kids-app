"""Explicit opt-in, fixed-origin TLS transports with disjoint environments.

Promoted from the reviewed component-canary adapter. No import-time connection,
proxy environment, redirects or retry. Every send also checks the default-off
builtin-transport switch; explicit test factories remain separately injected.
"""
from django.conf import settings
import http.client
import re
import socket
import ssl
from threading import Timer
from urllib.parse import urlsplit

from django.views.decorators.debug import sensitive_variables
from .client import SquareClientError, SquareHttpResult


class _SquareTLSTransport:
    @sensitive_variables()
    def send(self, *, method, url, headers, body, timeout_seconds, max_response_bytes):
        connection = None
        deadline = None
        try:
            prefix = 'SQUARE_' + self.environment.upper()
            if (getattr(settings, prefix + '_HTTP_TRANSPORT_ENABLED', False) is not True
                    or getattr(settings, prefix + '_ENABLED', False) is not True
                    or settings.SQUARE_ENVIRONMENT != self.environment):
                raise ValueError
            parsed = urlsplit(url)
            if (parsed.scheme != 'https' or parsed.hostname != self.hostname
                    or parsed.port not in (None, 443) or parsed.username or parsed.password
                    or parsed.fragment or not parsed.path.startswith('/v2/')
                    or any(part in {'.', '..'} for part in parsed.path.split('/'))
                    or any(ord(char) <= 32 or ord(char) == 127 for char in url)
                    or method not in {'GET', 'POST', 'DELETE'}
                    or not isinstance(body, bytes) or len(body) > 65_536
                    or type(timeout_seconds) is not int or not 1 <= timeout_seconds <= 15
                    or type(max_response_bytes) is not int or not 1 <= max_response_bytes <= 1_048_576):
                raise ValueError
            required = {'Authorization', 'Square-Version', 'Content-Type', 'Accept'}
            if (not isinstance(headers, dict) or set(headers) != required
                    or not re.fullmatch(r'Bearer [!-~]{1,4096}', headers['Authorization'])
                    or not re.fullmatch(r'[0-9]{4}-[0-9]{2}-[0-9]{2}', headers['Square-Version'])
                    or headers['Content-Type'] != 'application/json' or headers['Accept'] != 'application/json'):
                raise ValueError
            connection = http.client.HTTPSConnection(self.hostname,
                timeout=timeout_seconds, context=ssl.create_default_context())
            connection.set_debuglevel(0)
            sockets = []
            def abort():
                active = sockets[-1] if sockets else getattr(connection, 'sock', None)
                if active is not None:
                    try: active.shutdown(socket.SHUT_RDWR)
                    except OSError: pass
                connection.close()
            deadline = Timer(timeout_seconds * 2 + 2, abort)
            deadline.daemon = True
            deadline.start()
            path = parsed.path + ('?' + parsed.query if parsed.query else '')
            connection.request(method, path, body=body, headers=headers)
            if getattr(connection, 'sock', None) is not None:
                sockets.append(connection.sock)
            response = connection.getresponse()
            if 300 <= response.status < 400:
                raise ValueError
            raw = response.read(max_response_bytes + 1)
            if len(raw) > max_response_bytes:
                raise ValueError
            return SquareHttpResult(response.status, raw)
        except Exception:
            raise SquareClientError('Sandbox transport failed; the result may be uncertain.') from None
        finally:
            if deadline is not None:
                deadline.cancel()
            if connection is not None:
                connection.close()


class SandboxTransport(_SquareTLSTransport):
    environment = 'sandbox'
    hostname = 'connect.squareupsandbox.com'


class ProductionTransport(_SquareTLSTransport):
    environment = 'production'
    hostname = 'connect.squareup.com'


def make_transport():
    return SandboxTransport()
