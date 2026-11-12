import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

import render_preflight


class RenderSourcePreflightTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.backend = Path(self.directory.name)
        for relative in ('Dockerfile', '.dockerignore', 'Core/Core/settings.py'):
            target = self.backend / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(render_preflight.BACKEND / relative, target)

    def test_current_packaging_and_disabled_source_flags_pass(self):
        self.assertTrue(all(render_preflight.check_source(self.backend).values()))

    def test_broad_health_redirect_exemption_is_rejected(self):
        path = self.backend / 'Core/Core/settings.py'
        path.write_text(path.read_text().replace(
            "[r'^health/live/$', r'^health/ready/$']", "[r'^health/']",
        ))
        self.assertFalse(render_preflight.check_source(self.backend)['exact_health_redirect_exemptions'])

    def test_accidental_media_or_whole_context_copy_is_rejected(self):
        path = self.backend / 'Dockerfile'
        original = path.read_text()
        for copy in ('COPY . ./\n', 'COPY media ./media\n'):
            with self.subTest(copy=copy):
                path.write_text(original + copy)
                self.assertFalse(render_preflight.check_source(self.backend)['exact_docker_copy_allowlist'])

    def test_accidental_financial_activation_default_is_rejected(self):
        path = self.backend / 'Core/Core/settings.py'
        path.write_text(path.read_text().replace(
            "env_flag('SQUARE_SANDBOX_TERM_BILLING_ENABLED', False)",
            "env_flag('SQUARE_SANDBOX_TERM_BILLING_ENABLED', True)",
        ))
        self.assertFalse(render_preflight.check_source(self.backend)[
            'default_off_square_sandbox_term_billing_enabled'
        ])
        path.write_text(path.read_text() +
                        "\nSQUARE_FUTURE_ENABLED = env_flag('SQUARE_FUTURE_ENABLED', True)\n")
        self.assertFalse(render_preflight.check_source(self.backend)[
            'default_off_square_future_enabled'
        ])

    def test_backup_exclusion_removal_or_reinclude_is_rejected(self):
        path = self.backend / '.dockerignore'
        original = path.read_text()
        for modified in (original.replace('Core/.cache\n', ''),
                         original.replace('**/*.sqlite3*\n', ''),
                         original + '\n!Core/.cache/retained.sqlite3\n'):
            with self.subTest(ignore_rules=modified):
                path.write_text(modified)
                self.assertFalse(render_preflight.check_source(self.backend)[
                    'local_database_backup_exclusions'])

    def test_image_scan_detects_nested_backup_when_primary_database_is_absent(self):
        (self.backend / 'requirements.txt').write_text('')
        self.assertTrue(render_preflight.check_image(self.backend)['no_local_database_or_media'])
        backup = self.backend / 'Core/.cache/retained-backup/old.sqlite3'
        backup.parent.mkdir(parents=True)
        backup.write_bytes(b'synthetic backup, never real account data')
        self.assertFalse((self.backend / 'Core/db.sqlite3').exists())
        self.assertFalse(render_preflight.check_image(self.backend)['no_local_database_or_media'])

    def test_cli_never_initializes_django_from_supplied_environment(self):
        result = subprocess.run(
            [sys.executable, str(render_preflight.BACKEND / 'scripts/render_preflight.py')],
            env={'PATH': os.environ.get('PATH', ''), 'DJANGO_DEBUG': 'invalid-do-not-load',
                 'DJANGO_DATABASE_URL': 'not-a-database-url'},
            capture_output=True, text=True, timeout=5,
        )
        self.assertEqual(result.returncode, 0)
        data = json.loads(result.stdout)
        self.assertTrue(data['passed'])
        self.assertFalse(data['secrets_loaded'])
        self.assertFalse(data['network_accessed'])
        self.assertFalse(data['database_or_cache_checked'])
        self.assertEqual(result.stderr, '')


if __name__ == '__main__':
    unittest.main()
