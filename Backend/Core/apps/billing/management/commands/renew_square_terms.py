from django.core.management.base import BaseCommand, CommandError
from apps.billing.configuration import SquareConfigurationError, SquareDisabled
from apps.billing.terms import process_due_terms


class Command(BaseCommand):
    help = 'Dry-run by default. Explicit --apply can charge authorized current Sandbox app terms; never automatic Square Subscriptions.'

    def add_arguments(self, parser):
        parser.add_argument('--apply', action='store_true')
        parser.add_argument('--limit', type=int, default=10)

    def handle(self, *args, **options):
        if not options['apply']:
            self.stdout.write('Dry run only. No card/payment/provider operations.')
            return
        try:
            results = process_due_terms(limit=options['limit'])
            self.stdout.write(f'Attempted {len(results)} bounded current-term operations; {results.count("paid")} paid. No expired-cycle catch-up charges.')
        except (SquareDisabled, SquareConfigurationError, ValueError):
            raise CommandError('Term billing is disabled or not explicitly configured.') from None
