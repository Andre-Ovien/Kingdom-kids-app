"""Verify Resend SMTP setup without submitting any message or recipient."""
from django.conf import settings
from django.core.mail import get_connection
from django.core.management.base import BaseCommand, CommandError


class Command(BaseCommand):
    help = 'Check Resend configuration; --connect also authenticates SMTP without sending email.'

    def add_arguments(self, parser):
        parser.add_argument(
            '--connect', action='store_true',
            help='Open an encrypted SMTP session and authenticate. No email is sent.',
        )

    def handle(self, *args, **options):
        if getattr(settings, 'USING_RESEND_HTTPS', False):
            from Core.resend_backend import validate_configuration
            try:
                validate_configuration()
            except Exception:
                raise CommandError('Resend HTTPS sending configuration is incomplete.') from None
            if options['connect']:
                raise CommandError('Resend HTTPS checks are local only; no email or provider request was sent.')
            self.stdout.write(self.style.SUCCESS(
                'Resend HTTPS configuration is valid. No network connection or email was sent. '
                'Verify the sender domain and actual delivery separately.'
            ))
            return
        if not settings.USING_RESEND_SMTP:
            raise CommandError(
                'Select the SMTP backend and smtp.resend.com before checking Resend.'
            )
        if not options['connect']:
            self.stdout.write(self.style.SUCCESS(
                'Resend SMTP configuration is valid. No network connection or email was sent. '
                'Sender-domain verification and actual delivery are separate checks.'
            ))
            return

        connection = None
        try:
            connection = get_connection(fail_silently=False)
            connection.open()
        except Exception:
            # A provider exception may contain an API key, account details or
            # SMTP dialogue. Deliberately omit its text and exception chain.
            raise CommandError(
                'Resend SMTP connection or authentication failed. Check the backend '
                'secret, encrypted port, and network access; no email was sent.'
            ) from None
        finally:
            if connection is not None:
                try:
                    connection.close()
                except Exception:
                    pass
        self.stdout.write(self.style.SUCCESS(
            'Resend SMTP TLS connection and authentication succeeded. No email was sent. '
            'This does not verify a sender domain or inbox delivery.'
        ))
