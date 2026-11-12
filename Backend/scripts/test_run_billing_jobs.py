"""No DB, provider, credentials or external service: wrapper boundary tests."""
import base64
from contextlib import redirect_stderr, redirect_stdout
import importlib.util
from io import StringIO
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location('billing_job_wrapper', Path(__file__).with_name('run_billing_jobs.py'))
wrapper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wrapper)


class BillingJobWrapperTests(unittest.TestCase):
    def test_default_dryrun_does_not_load_django_or_read_environment(self):
        out = StringIO()
        with patch.dict(sys.modules, {'django': None}), patch.object(
                wrapper, 'prepare_environment') as prepare, redirect_stdout(out):
            result = wrapper.main(['--environment', 'production', '--stage', 'renew'])
        self.assertEqual(result, 0)
        prepare.assert_not_called()
        self.assertEqual(json.loads(out.getvalue())['database_writes'], 0)

    def test_explicit_signing_values_are_preserved_without_printing(self):
        values = {'DJANGO_DEBUG': 'false', 'DJANGO_ALLOWED_HOSTS': 'api.example.test',
            'DJANGO_SECRET_KEY': 'private-existing-django', 'DJANGO_JWT_SIGNING_KEY': 'private-existing-jwt',
            'RENDER_DJANGO_SECRET_SEED': 'unused', 'RENDER_JWT_SIGNING_SEED': 'unused'}
        wrapper.prepare_environment(values)
        self.assertEqual(values['DJANGO_SECRET_KEY'], 'private-existing-django')
        self.assertNotIn('RENDER_DJANGO_SECRET_SEED', values)
        self.assertNotIn('RENDER_JWT_SIGNING_SEED', values)

    def test_shared_render_seed_derivation_matches_existing_web_identity(self):
        values = {'DJANGO_DEBUG': 'false', 'DJANGO_ALLOWED_HOSTS': 'api.example.test',
            'RENDER_DJANGO_SECRET_SEED': base64.b64encode(bytes(range(32))).decode(),
            'RENDER_JWT_SIGNING_SEED': base64.b64encode(bytes(range(32, 64))).decode()}
        with redirect_stdout(StringIO()) as out:
            wrapper.prepare_environment(values)
        self.assertEqual(len(values['DJANGO_SECRET_KEY']), 128)
        self.assertNotEqual(values['DJANGO_SECRET_KEY'], values['DJANGO_JWT_SIGNING_KEY'])
        self.assertEqual(out.getvalue(), '')
        self.assertNotIn('RENDER_DJANGO_SECRET_SEED', values)

    def test_signing_derivation_matches_the_actual_web_startup_function(self):
        web_spec = importlib.util.spec_from_file_location('reviewed_web_startup',
            Path(__file__).with_name('render_start.py'))
        web = importlib.util.module_from_spec(web_spec)
        web_spec.loader.exec_module(web)
        values = {'DJANGO_DEBUG': 'false', 'DJANGO_EMAIL_DELIVERY_ENABLED': 'false',
            'RENDER_EXTERNAL_HOSTNAME': 'kingdom-kids-test.onrender.com',
            'DJANGO_ALLOWED_HOSTS': 'kingdom-kids-test.onrender.com',
            'DJANGO_CACHE_URL': 'redis://red-syntheticprivate:6379', 'DJANGO_CACHE_ALLOW_INSECURE': 'true',
            'RENDER_DJANGO_SECRET_SEED': base64.b64encode(bytes(range(32))).decode(),
            'RENDER_JWT_SIGNING_SEED': base64.b64encode(bytes(range(32, 64))).decode()}
        web_values = dict(values)
        web.prepare_environment(web_values)
        wrapper.prepare_environment(values)
        self.assertEqual(values['DJANGO_SECRET_KEY'], web_values['DJANGO_SECRET_KEY'])
        self.assertEqual(values['DJANGO_JWT_SIGNING_KEY'], web_values['DJANGO_JWT_SIGNING_KEY'])

    def test_failed_apply_redacts_environment_exception_details(self):
        err = StringIO()
        with patch.object(wrapper, 'prepare_environment', side_effect=ValueError('private-secret-detail')), \
                redirect_stderr(err), patch.dict(sys.modules, {'django': None}):
            result = wrapper.main(['--environment', 'production', '--stage', 'renew', '--apply'])
        self.assertEqual(result, 1)
        self.assertEqual(json.loads(err.getvalue())['status'], 'failed')
        self.assertNotIn('private-secret-detail', err.getvalue())

    def test_apply_rejects_debug_missing_hosts_and_missing_signing_before_django(self):
        for values in ({}, {'DJANGO_DEBUG': 'true'}, {'DJANGO_DEBUG': 'false'},
                {'DJANGO_DEBUG': 'false', 'DJANGO_ALLOWED_HOSTS': 'api.example.test'}):
            with self.subTest(keys=tuple(values)), self.assertRaises(ValueError):
                wrapper.prepare_environment(values)


if __name__ == '__main__':
    unittest.main()
