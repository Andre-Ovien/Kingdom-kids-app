"""Dedicated one-shot scheduler entrypoint. Never bootstraps or starts a web app."""
import argparse
import base64
import hashlib
from io import StringIO
import json
import os
from pathlib import Path
import signal
import sys


BACKEND = Path(__file__).resolve().parents[1]


def prepare_environment(environ):
    if environ.get('DJANGO_DEBUG') != 'false':
        raise ValueError('Explicit production Django settings are required.')
    if not environ.get('DJANGO_ALLOWED_HOSTS'):
        raise ValueError('The explicit API host configuration is required.')
    # Reuse the exact reviewed web-service derivation, preserving shared signing
    # identity when an operator deliberately supplies the existing Render seeds.
    for target, source in (
        ('DJANGO_SECRET_KEY', 'RENDER_DJANGO_SECRET_SEED'),
        ('DJANGO_JWT_SIGNING_KEY', 'RENDER_JWT_SIGNING_SEED'),
    ):
        if not environ.get(target):
            try:
                seed = base64.b64decode(environ.get(source, ''), validate=True)
            except (ValueError, TypeError):
                raise ValueError('A valid signing configuration is required.') from None
            if len(seed) != 32:
                raise ValueError('A valid signing configuration is required.')
            environ[target] = hashlib.sha512(
                b'kingdom-kids/render-staging/' + target.encode() + b'\0' + seed).hexdigest()
        environ.pop(source, None)


def main(argv=None):
    parser = argparse.ArgumentParser(description='Default-off bounded billing job; never migrates or provisions services.')
    parser.add_argument('--environment', choices=('sandbox', 'production'), required=True)
    parser.add_argument('--stage', choices=('reconcile', 'renew'), required=True)
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--limit', type=int, default=5)
    parser.add_argument('--max-calls', type=int, default=80)
    parser.add_argument('--max-seconds', type=int, default=120)
    options = parser.parse_args(argv)
    if not (1 <= options.limit <= 20 and 1 <= options.max_calls <= 200 and 1 <= options.max_seconds <= 600):
        parser.error('Billing job bounds are invalid.')
    if not options.apply:
        print(json.dumps({'environment': options.environment, 'stage': options.stage, 'status': 'dry_run',
            'provider_calls': 0, 'payment_requests': 0, 'database_writes': 0}, sort_keys=True))
        return 0
    connections = None
    try:
        prepare_environment(os.environ)
        os.chdir(BACKEND)
        sys.path.insert(0, str(BACKEND / 'Core'))
        os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'Core.settings')
        import django
        django.setup()
        from django.core.management import call_command
        from django.db import connections
        from django.db.migrations.executor import MigrationExecutor
        from apps.billing.jobs import request_stop
        signal.signal(signal.SIGTERM, request_stop)
        signal.signal(signal.SIGINT, request_stop)
        call_command('check', deploy=True, fail_level='ERROR', stdout=StringIO(), stderr=StringIO())
        database = connections['default']
        if database.vendor != 'postgresql':
            raise ValueError('Billing deployment jobs require PostgreSQL.')
        executor = MigrationExecutor(database)
        if executor.migration_plan(executor.loader.graph.leaf_nodes()):
            raise ValueError('Apply reviewed release migrations separately before scheduling jobs.')
        call_command('run_square_billing_jobs', environment=options.environment, stage=options.stage,
            apply=True, limit=options.limit, max_calls=options.max_calls, max_seconds=options.max_seconds)
        return 0
    except Exception:
        print(json.dumps({'environment': options.environment, 'stage': options.stage, 'status': 'failed'}, sort_keys=True),
            file=sys.stderr)
        return 1
    finally:
        if connections is not None:
            connections.close_all()


if __name__ == '__main__':
    raise SystemExit(main())
