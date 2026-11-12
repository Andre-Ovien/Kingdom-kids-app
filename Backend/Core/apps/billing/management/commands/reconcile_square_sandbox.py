"""Explicit operator-driven canonical reads. Dry run never opens transport."""
from django.core.management.base import BaseCommand, CommandError
from django.utils import timezone
from django.db.models import Q

from apps.billing.configuration import SquareConfigurationError, SquareDisabled, checkout_configuration
from apps.billing.models import SquareCheckoutIntent, SquareWebhookReceipt
from apps.billing.reconciliation import process_receipt, reconcile_intent
from apps.billing.terms import term_configuration
from django.conf import settings


class Command(BaseCommand):
    help = 'Inspect pending Square Sandbox reconciliation. --apply performs bounded canonical reads; never financial mutations.'

    def add_arguments(self, parser):
        parser.add_argument('--apply', action='store_true')
        parser.add_argument('--intent', type=str)
        parser.add_argument('--invoice', type=str)
        parser.add_argument('--sweep-intents', action='store_true')
        parser.add_argument('--limit', type=int, default=10)

    def handle(self, *args, **options):
        if not 1 <= options['limit'] <= 20:
            raise CommandError('--limit must be between1 and20.')
        if options['invoice'] and not options['intent']:
            raise CommandError('--invoice requires --intent.')
        if not options['apply']:
            self.stdout.write('Dry run only; no transport, provider request or observation writes. Full hosted Sandbox subscription E2E is unsupported.')
            return
        try:
            term_mode = getattr(settings, 'SQUARE_SANDBOX_TERM_RECONCILIATION_ENABLED', False)
            if term_mode and (options['intent'] or options['sweep_intents']):
                raise CommandError('Use reconcile_square_terms for exact payment terms; legacy subscription sweeps are unavailable in term mode.')
            config = term_configuration(readonly=True) if term_mode else checkout_configuration(reconciliation=True)
            if options['intent']:
                intent = SquareCheckoutIntent.objects.select_related('parent').get(
                    pk=options['intent'], merchant_id=config.provider.merchant_id)
                reconcile_intent(parent=intent.parent, intent_id=intent.pk, invoice_id=options['invoice'])
                self.stdout.write('Canonical observation completed. Unknown invoice coverage grants no access.')
                return
            receipts = SquareWebhookReceipt.objects.filter(merchant_id=config.provider.merchant_id).filter(
                Q(processing_state__in=('pending', 'retry')) | (Q(processing_state='processing') &
                    (Q(lease_until__isnull=True) | Q(lease_until__lte=timezone.now())))).filter(
                    Q(next_attempt_at__isnull=True) | Q(next_attempt_at__lte=timezone.now())).order_by('pk')
            identifiers = list(receipts.values_list('pk', flat=True)[:options['limit']])
            outcomes = [process_receipt(receipt_id=identifier) for identifier in identifiers]
            if options['sweep_intents']:
                intents = SquareCheckoutIntent.objects.filter(merchant_id=config.provider.merchant_id,
                    is_open=True, parent__is_active=True, parent__email_verified_at__isnull=False).filter(
                        Q(lease_until__isnull=True) | Q(lease_until__lte=timezone.now())).exclude(
                            customer_id='', order_template_id='').select_related('parent').order_by('updated_at')
                for intent in intents[:max(0, options['limit'] - len(outcomes))]:
                    try:
                        reconcile_intent(parent=intent.parent, intent_id=intent.pk)
                    except Exception:
                        # Fixed text only; the leased service already records
                        # its retry/review outcome. Continue other bounded work.
                        self.stderr.write('One intent remains pending canonical review.')
            self.stdout.write(f'Processed {len(outcomes)} bounded receipt attempts; canonical Sandbox observations only, no charges or card storage.')
        except (SquareConfigurationError, SquareDisabled, SquareCheckoutIntent.DoesNotExist, ValueError):
            raise CommandError('Square Sandbox reconciliation is unavailable or not explicitly configured.') from None
