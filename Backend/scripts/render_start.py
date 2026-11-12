"""Free Render staging: strict settings, serialized migrations, then Gunicorn.

No credentials are generated locally or printed. Render's independently generated
256-bit seeds are expanded to meet the application's existing string-length rules.
"""
import base64
from contextlib import contextmanager
import hashlib
import os
from pathlib import Path
import re
import sys
import time

BACKEND = Path(__file__).resolve().parents[1]
MIGRATION_LOCK = 54255181082000
DISABLED_FLAGS = (
    'SQUARE_SANDBOX_ENABLED', 'SQUARE_SANDBOX_CHECKOUT_ENABLED',
    'SQUARE_SANDBOX_RECONCILIATION_ENABLED', 'SQUARE_SANDBOX_CANCELLATION_ENABLED',
    'SQUARE_SANDBOX_TERM_BILLING_ENABLED', 'SQUARE_SANDBOX_TERM_RECONCILIATION_ENABLED',
    'SQUARE_SANDBOX_HTTP_TRANSPORT_ENABLED', 'PAID_CONTENT_ENFORCEMENT_ENABLED',
    'PARENT_CHECKOUT_SANDBOX_ENABLED', 'PARENT_CONTENT_ACCESS_STATUS_ENABLED',
    'CLOUDINARY_PRIVATE_DELIVERY_ENABLED',
)


class StartupRejected(RuntimeError):
    pass


def prepare_environment(environ):
    """Validate only explicit staging inputs; no environment values enter errors."""
    if environ.get('DJANGO_DEBUG') != 'false' or environ.get('DJANGO_EMAIL_DELIVERY_ENABLED') != 'false':
        raise StartupRejected('Explicit production mode and disabled email are required.')
    if any(environ.get(flag, 'false') != 'false' for flag in DISABLED_FLAGS):
        raise StartupRejected('Financial, checkout and private-media features must stay disabled.')
    for target, seed_name in (
        ('DJANGO_SECRET_KEY', 'RENDER_DJANGO_SECRET_SEED'),
        ('DJANGO_JWT_SIGNING_KEY', 'RENDER_JWT_SIGNING_SEED'),
    ):
        if environ.get(target):
            continue  # Existing explicit keys still face all original Django guards.
        try:
            seed = base64.b64decode(environ.get(seed_name, ''), validate=True)
        except (ValueError, TypeError):
            raise StartupRejected('A valid platform-generated signing seed is required.') from None
        if len(seed) != 32:
            raise StartupRejected('A valid platform-generated signing seed is required.')
        environ[target] = hashlib.sha512(b'kingdom-kids/render-staging/' + target.encode() + b'\0' + seed).hexdigest()
    # Do not retain duplicate seed values in the server's inherited environment.
    environ.pop('RENDER_DJANGO_SECRET_SEED', None)
    environ.pop('RENDER_JWT_SIGNING_SEED', None)
    host = environ.get('RENDER_EXTERNAL_HOSTNAME', '')
    if not re.fullmatch(r'[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.onrender\.com', host):
        raise StartupRejected('The exact Render public hostname is required.')
    if environ.get('DJANGO_ALLOWED_HOSTS', host) != host:
        raise StartupRejected('Only the exact Render public hostname is permitted.')
    environ['DJANGO_ALLOWED_HOSTS'] = host
    # The Blueprint uses only Render's same-region private Key Value URL and
    # blocks every external cache IP. Never opt out of TLS for an arbitrary URL.
    from urllib.parse import urlsplit
    cache = urlsplit(environ.get('DJANGO_CACHE_URL', ''))
    if cache.scheme == 'redis' and (
        environ.get('DJANGO_CACHE_ALLOW_INSECURE') != 'true'
        or not re.fullmatch(r'red-[a-z0-9-]+', cache.hostname or '')
        or cache.port not in (None, 6379)
    ):
        raise StartupRejected('Unencrypted cache must be Render private Key Value only.')
    port = environ.get('PORT', '10000')
    if not port.isdecimal() or not 1024 <= int(port) <= 65535:
        raise StartupRejected('A valid non-privileged application port is required.')
    return port


@contextmanager
def migration_lock(connection_parameters, *, connect=None, clock=time.monotonic, sleep=time.sleep):
    """A separate session lock serializes old/new startup migration attempts."""
    if connect is None:
        import psycopg
        connect = psycopg.connect
    with connect(**connection_parameters, autocommit=True) as lock_connection:
        with lock_connection.cursor() as cursor:
            deadline = clock() + 120
            while True:
                cursor.execute('SELECT pg_try_advisory_lock(%s)', (MIGRATION_LOCK,))
                if cursor.fetchone()[0]:
                    break
                if clock() >= deadline:
                    raise StartupRejected('Another deployment still owns the migration lock.')
                sleep(1)
            try:
                yield
            finally:
                cursor.execute('SELECT pg_advisory_unlock(%s)', (MIGRATION_LOCK,))


def start():
    port = prepare_environment(os.environ)
    os.chdir(BACKEND)
    sys.path.insert(0, str(BACKEND / 'Core'))
    os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'Core.settings')
    import django
    django.setup()  # All original production settings checks remain authoritative.
    from django.core.management import call_command
    from django.db import connections
    call_command('check', deploy=True, fail_level='ERROR')
    database = connections['default']
    if database.vendor != 'postgresql':
        raise StartupRejected('Deployment migrations require PostgreSQL.')
    with migration_lock(database.get_connection_params()):
        call_command('migrate', interactive=False)
    connections.close_all()
    # One synchronous worker fits the Free instance and keeps DB usage bounded.
    # Access logs omit request URLs, which can contain query parameters.
    os.execvp('gunicorn', ['gunicorn', '--chdir', 'Core', 'Core.wsgi:application',
        '--bind', f'0.0.0.0:{port}', '--workers', '1', '--timeout', '30',
        '--graceful-timeout', '30', '--access-logfile', '-',
        '--access-logformat', '%(h)s %(s)s %(L)s', '--error-logfile', '-'])


if __name__ == '__main__':
    try:
        start()
    except Exception:
        # No traceback/environment/connection string is printed at this boundary.
        print('Render startup failed: configuration validation or migrations did not complete.', file=sys.stderr)
        raise SystemExit(1) from None
