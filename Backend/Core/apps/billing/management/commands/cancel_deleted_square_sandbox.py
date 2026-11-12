from django.core.management.base import BaseCommand, CommandError
from django.db.models import Q
from django.utils import timezone

from apps.billing.cancellation import cancellation_configuration, process_cancellation
from apps.billing.configuration import SquareConfigurationError, SquareDisabled
from apps.billing.models import SquareCancellationOutbox


class Command(BaseCommand):
    help = 'Dry-run by default. --apply verifies/schedules Sandbox renewal cancellation for deleted-account outbox only.'

    def add_arguments(self, parser):
        parser.add_argument('--apply', action='store_true')
        parser.add_argument('--limit', type=int, default=10)

    def handle(self, *args, **options):
        if not 1 <= options['limit'] <= 20:
            raise CommandError('--limit must be between1 and20.')
        if not options['apply']:
            self.stdout.write('Dry run only. No provider reads or cancellation requests.')
            return
        try:
            config = cancellation_configuration()
            now = timezone.now()
            jobs = SquareCancellationOutbox.objects.filter(merchant_id=config.merchant_id).exclude(state='verified').filter(
                Q(lease_until__isnull=True) | Q(lease_until__lte=now)).filter(
                Q(next_attempt_at__isnull=True) | Q(next_attempt_at__lte=now)).order_by('created_at')
            identifiers = list(jobs.values_list('pk', flat=True)[:options['limit']])
            results = [process_cancellation(outbox_id=identifier) for identifier in identifiers]
            self.stdout.write(f'Attempted {len(results)} deleted-account cancellation jobs; {results.count("verified")} canonically verified. No refunds requested.')
        except (SquareDisabled, SquareConfigurationError):
            raise CommandError('Square Sandbox cancellation is disabled or not explicitly configured.') from None
