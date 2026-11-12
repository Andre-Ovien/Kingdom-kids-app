"""One-time env-only family import, never an HTTP route or a shipped fixture."""
import json
import os

from django.core.management.base import BaseCommand, CommandError
from django.views.decorators.debug import sensitive_variables
from apps.accounts.private_family_import import SERVICE, FamilyImportRejected, decode_payload, apply_payload


class Command(BaseCommand):
    help = 'Validate or apply one explicitly supplied private test-family import.'

    def add_arguments(self, parser):
        mode = parser.add_mutually_exclusive_group()
        mode.add_argument('--apply', action='store_true')
        mode.add_argument('--dry-run', action='store_true')

    @sensitive_variables()
    def handle(self, *args, **options):
        try:
            if os.environ.get('RENDER_EXTERNAL_HOSTNAME') != SERVICE:
                raise FamilyImportRejected('Family transfer is restricted to the expected staging service.')
            encoded = os.environ.get('KK_TEST_FAMILY_IMPORT_ZLIB_B64', '')
            digest = os.environ.get('KK_TEST_FAMILY_IMPORT_SHA256', '')
            email = os.environ.get('KK_TEST_FAMILY_IMPORT_EMAIL', '')
            payload = decode_payload(encoded, digest)
            result = apply_payload(payload, digest, email, dry_run=not options['apply'])
        except Exception:
            raise CommandError('Private family import rejected; no family data was changed.') from None
        self.stdout.write(json.dumps(result, sort_keys=True))
