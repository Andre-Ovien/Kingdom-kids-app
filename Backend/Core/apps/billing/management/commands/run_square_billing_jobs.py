"""One explicit bounded scheduler tick; dry-run does not query or mutate DB."""
import json

from django.core.management.base import BaseCommand, CommandError

from apps.billing.jobs import run_jobs


class Command(BaseCommand):
    requires_system_checks = []
    help = 'Default dry-run. Explicit enabled --apply processes one bounded environment-scoped billing job tick.'

    def add_arguments(self, parser):
        parser.add_argument('--environment', choices=('sandbox', 'production'), required=True)
        parser.add_argument('--stage', choices=('reconcile', 'renew'), required=True)
        parser.add_argument('--apply', action='store_true')
        parser.add_argument('--limit', type=int, default=5)
        parser.add_argument('--max-calls', type=int, default=80)
        parser.add_argument('--max-seconds', type=int, default=120)

    def handle(self, *args, **options):
        if not (1 <= options['limit'] <= 20 and 1 <= options['max_calls'] <= 200
                and 1 <= options['max_seconds'] <= 600):
            raise CommandError('Billing job bounds are invalid.')
        if not options['apply']:
            self.stdout.write(json.dumps({'environment': options['environment'], 'stage': options['stage'],
                'status': 'dry_run', 'provider_calls': 0, 'payment_requests': 0, 'database_writes': 0}, sort_keys=True))
            return
        try:
            report = run_jobs(environment=options['environment'], stage=options['stage'], limit=options['limit'],
                max_calls=options['max_calls'], max_seconds=options['max_seconds'])
        except Exception:
            raise CommandError('Billing job is disabled, unconfigured or unavailable; no automatic retry.') from None
        self.stdout.write(json.dumps(report, sort_keys=True))
        if report['status'] not in {'ok', 'lock_busy'}:
            raise CommandError('Billing job requires operational review; preserve existing payment keys.')
