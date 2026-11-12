from django.core.management.base import BaseCommand, CommandError
from apps.billing.configuration import SquareConfigurationError, SquareDisabled
from apps.billing.terms import reconcile_term, term_configuration
from apps.billing.models import SquareBillingTerm


class Command(BaseCommand):
    help = 'Read-only canonical Sandbox term reconciliation. Dry-run by default; never creates a charge.'

    def add_arguments(self, parser):
        parser.add_argument('--apply', action='store_true')
        parser.add_argument('--term')
        parser.add_argument('--payment')
        parser.add_argument('--limit', type=int, default=10)

    def handle(self, *args, **options):
        if not 1 <= options['limit'] <= 20:
            raise CommandError('--limit must be between1 and20.')
        if options['payment'] and not options['term']:
            raise CommandError('--payment requires --term.')
        if not options['apply']:
            self.stdout.write('Dry run only. No provider reads, charges or grant writes.')
            return
        try:
            config = term_configuration(readonly=True)
            ids = ([options['term']] if options['term'] else list(SquareBillingTerm.objects.filter(
                agreement__merchant_id=config.provider.merchant_id).order_by('payment_updated_at', 'created_at').values_list('pk', flat=True)[:options['limit']]))
            count = 0
            for identifier in ids:
                try:
                    reconcile_term(term_id=identifier, payment_id=options['payment'])
                    count += 1
                except Exception:
                    self.stderr.write('One exact term remains pending canonical review.')
            self.stdout.write(f'Reconciled {count} bounded terms. No financial mutations.')
        except (SquareDisabled, SquareConfigurationError, ValueError):
            raise CommandError('Term reconciliation is disabled or not configured.') from None
