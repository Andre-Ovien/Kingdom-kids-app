import json
import os
import secrets
import subprocess
import sys
from pathlib import Path
from tempfile import TemporaryDirectory

from django.test import SimpleTestCase


class ProductionMediaSettingsTests(SimpleTestCase):
    def load_settings(self, **overrides):
        environment = {
            'PATH': os.environ.get('PATH', ''),
            'DJANGO_DEBUG': 'false',
            'DJANGO_SECRET_KEY': secrets.token_urlsafe(64),
            'DJANGO_JWT_SIGNING_KEY': secrets.token_urlsafe(64),
            'EMAIL_VERIFICATION_PEPPER': secrets.token_urlsafe(64),
            'PASSWORD_RESET_PEPPER': secrets.token_urlsafe(64),
            'ACCOUNT_DELETION_PEPPER': secrets.token_urlsafe(64),
            'DJANGO_ALLOWED_HOSTS': 'api.kingdom.test',
            'DJANGO_DATABASE_URL': 'postgresql://check:unused@localhost/check',
            'DJANGO_CACHE_URL': 'rediss://localhost:6379/0',
            'DJANGO_EMAIL_BACKEND': 'django.core.mail.backends.smtp.EmailBackend',
            'DJANGO_EMAIL_HOST': 'smtp.kingdom.test',
            'DJANGO_DEFAULT_FROM_EMAIL': 'Kingdom Kids <no-reply@kingdom.test>',
            'DJANGO_CONTENT_MEDIA_HOSTS': 'cdn.kingdom.test',
        }
        environment.update(overrides)
        source = Path(__file__).resolve().parents[2] / 'Core' / 'settings.py'
        return subprocess.run(
            [
                sys.executable,
                '-c',
                'import json, runpy, sys; '
                'values = runpy.run_path(sys.argv[1]); '
                'print(json.dumps({"media_root": str(values["MEDIA_ROOT"]), '
                '"media_url": values["MEDIA_URL"]}))',
                str(source),
            ],
            env=environment,
            text=True,
            capture_output=True,
            timeout=10,
        )

    def test_owned_https_media_base_and_durable_root_are_configurable(self):
        with TemporaryDirectory() as media_root:
            result = self.load_settings(
                DJANGO_MEDIA_ROOT=media_root,
                DJANGO_MEDIA_URL='https://cdn.kingdom.test/audio',
            )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {
            'media_root': str(Path(media_root).resolve()),
            'media_url': 'https://cdn.kingdom.test/audio/',
        })

    def test_production_rejects_untrusted_or_ambiguous_media_bases(self):
        for media_url in (
            'http://cdn.kingdom.test/audio/',
            'https://unowned.example/audio/',
            'https://user:password@cdn.kingdom.test/audio/',
            'https://cdn.kingdom.test:8443/audio/',
            'https://cdn.kingdom.test/audio/?signature=ambiguous',
            'https://cdn.kingdom.test/audio/#ambiguous',
            '//cdn.kingdom.test/audio/',
        ):
            with self.subTest(media_url=media_url):
                result = self.load_settings(DJANGO_MEDIA_URL=media_url)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('owned HTTPS host', result.stderr)

    def test_blank_media_settings_do_not_expose_the_working_directory(self):
        for name in ('DJANGO_MEDIA_ROOT', 'DJANGO_MEDIA_URL'):
            with self.subTest(name=name):
                result = self.load_settings(**{name: ''})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f'{name} cannot be blank.', result.stderr)
