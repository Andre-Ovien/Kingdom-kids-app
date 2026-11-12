"""Internal, read-only scheduler health; no provider calls or public endpoint."""
import json

from django.conf import settings
from django.core.management.base import BaseCommand, CommandError
from django.utils import timezone

from apps.billing.configuration import provider_identifier
from apps.billing.job_models import SquareBillingJobState
from apps.billing.jobs import backlog, merchant_digest


class Command(BaseCommand):
    requires_system_checks = []
    help = 'Read-only numeric billing-job heartbeat/backlog; never opens provider transport.'

    def add_arguments(self, parser):
        parser.add_argument('--environment', choices=('sandbox', 'production'), required=True)
        parser.add_argument('--stage', choices=('reconcile', 'renew'), required=True)
        parser.add_argument('--max-age-seconds', type=int, default=900)

    def handle(self, *args, **options):
        if not 60 <= options['max_age_seconds'] <= 86400:
            raise CommandError('Health age must be between60 and86400seconds.')
        environment, stage = options['environment'], options['stage']
        try:
            merchant = provider_identifier(getattr(settings, f'SQUARE_{environment.upper()}_MERCHANT_ID', ''), 192)
            now = timezone.now()
            flag = f'SQUARE_{environment.upper()}_{"RECONCILIATION" if stage == "reconcile" else "RENEWAL"}_JOBS_ENABLED'
            enabled = getattr(settings, flag, False) is True
            lanes = ('receipts', 'terms') if stage == 'reconcile' else ('renewals',)
            rows = {state.lane: state for state in SquareBillingJobState.objects.filter(
                environment=environment, merchant_sha256=merchant_digest(merchant), lane__in=lanes)}
            report = {'environment': environment, 'stage': stage, 'enabled': enabled, 'lanes': [], 'status': 'ok',
                'backlog': backlog(environment, merchant, now)}
            for lane in lanes:
                state = rows.get(lane)
                def age(value):
                    return max(0, int((now - value).total_seconds())) if value else None
                completed_age = age(state.last_completed_at) if state else None
                heartbeat_age = age(state.heartbeat_at) if state else None
                active_after_success = (state and state.outcome == 'running' and state.last_finished_outcome == 'ok'
                    and heartbeat_age is not None and heartbeat_age <= options['max_age_seconds'])
                healthy = (enabled and completed_age is not None and completed_age <= options['max_age_seconds']
                    and (state.outcome == 'ok' or active_after_success))
                report['lanes'].append({'lane': lane, 'healthy': healthy,
                    'heartbeat_age_seconds': heartbeat_age,
                    'completed_age_seconds': completed_age,
                    'full_scan_age_seconds': age(state.last_full_scan_at) if state else None,
                    'counts': {key: value for key in ('attempted', 'completed', 'review', 'retry')
                        if state and type(value := state.counts.get(key)) is int and value >= 0}})
                if not healthy:
                    report['status'] = 'attention'
        except Exception:
            raise CommandError('Billing job health is unavailable; no provider operation was attempted.') from None
        self.stdout.write(json.dumps(report, sort_keys=True))
        if report['status'] != 'ok':
            raise CommandError('Billing scheduler heartbeat requires review.')
