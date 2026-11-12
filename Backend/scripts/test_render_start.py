"""No DB, cache, Django, network or secret-manager actions: isolated startup checks."""
import base64
from contextlib import contextmanager
import importlib.util
import json
import os
from pathlib import Path
import re
import sys
import shutil
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location('render_start', Path(__file__).with_name('render_start.py'))
startup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(startup)


def environment():
    return {'DJANGO_DEBUG':'false','DJANGO_EMAIL_DELIVERY_ENABLED':'false',
        'RENDER_EXTERNAL_HOSTNAME':'kingdom-kids-test.onrender.com',
        'RENDER_DJANGO_SECRET_SEED':base64.b64encode(bytes(range(32))).decode(),
        'RENDER_JWT_SIGNING_SEED':base64.b64encode(bytes(range(32,64))).decode(),
        'DJANGO_CACHE_URL':'redis://red-syntheticprivate:6379','DJANGO_CACHE_ALLOW_INSECURE':'true',
        'PORT':'10000'}


def sandbox_environment():
    values = environment()
    origin = 'https://' + startup.SANDBOX_QUALIFICATION_HOST
    values.update(RENDER_SANDBOX_CHECKOUT_QUALIFICATION_ENABLED='true',
        RENDER_EXTERNAL_HOSTNAME=startup.SANDBOX_QUALIFICATION_HOST,
        PARENT_CHECKOUT_ORIGIN=origin, SQUARE_ENVIRONMENT='sandbox',
        PAID_CONTENT_ENTITLEMENT_ENVIRONMENT='sandbox',
        DJANGO_TRUST_X_FORWARDED_PROTO='true', DJANGO_API_NUM_PROXIES='1',
        SQUARE_SANDBOX_TEST_PARENT_IDS='41, 42', SQUARE_API_VERSION='2026-09-16',
        SQUARE_SANDBOX_APPLICATION_ID='sandbox-synthetic-application',
        SQUARE_SANDBOX_ACCESS_TOKEN='synthetic-not-a-provider-token',
        SQUARE_SANDBOX_MERCHANT_ID='synthetic-merchant',
        SQUARE_SANDBOX_LOCATION_ID='synthetic-location',
        SQUARE_SANDBOX_WEBHOOK_SIGNATURE_KEY='synthetic-not-a-webhook-secret',
        SQUARE_SANDBOX_WEBHOOK_NOTIFICATION_URL=origin + '/api/billing/square/webhook/')
    values.update({flag:'true' for flag in startup.SANDBOX_QUALIFICATION_FLAGS})
    return values


def production_environment():
    """Synthetic plausible configuration only; not an approved/provisioned host."""
    values = environment()
    host = 'kingdom-kids-release-fixture.onrender.com'
    origin = 'https://' + host
    release = json.loads(startup.PRIVATE_MEDIA_MAP.read_text())
    values.update(RENDER_PRODUCTION_CHECKOUT_QUALIFICATION_ENABLED='true',
        RENDER_PRODUCTION_OPERATIONS_QUALIFIED='true', RENDER_EXTERNAL_HOSTNAME=host,
        RENDER_PRODUCTION_APPROVED_ORIGIN=origin, PARENT_CHECKOUT_ORIGIN=origin,
        SQUARE_ENVIRONMENT='production', PAID_CONTENT_ENTITLEMENT_ENVIRONMENT='production',
        DJANGO_TRUST_X_FORWARDED_PROTO='true', DJANGO_API_NUM_PROXIES='1',
        SQUARE_API_VERSION='2026-09-16', SQUARE_PRODUCTION_APPLICATION_ID='sq0idp-production-fixture-app',
        SQUARE_PRODUCTION_ACCESS_TOKEN='synthetic-production-provider-token',
        SQUARE_PRODUCTION_MERCHANT_ID='production-merchant-fixture',
        SQUARE_PRODUCTION_LOCATION_ID='production-location-fixture',
        SQUARE_PRODUCTION_WEBHOOK_SIGNATURE_KEY='synthetic-production-webhook-secret',
        SQUARE_PRODUCTION_WEBHOOK_NOTIFICATION_URL=origin + '/api/billing/square/webhook/',
        DJANGO_EMAIL_BACKEND='Core.resend_backend.EmailBackend',
        DJANGO_DEFAULT_FROM_EMAIL='Kingdom Kids <support@notify.kingdom.test>',
        RESEND_VERIFIED_DOMAIN='notify.kingdom.test', RESEND_API_KEY='re_synthetic-not-a-real-secret',
        CLOUDINARY_CLOUD_NAME=release['cloud_name'], CLOUDINARY_API_KEY='1234567890',
        CLOUDINARY_API_SECRET='synthetic-private-secret-not-a-real-account',
        CLOUDINARY_PRIVATE_MEDIA_MAP_SHA256=startup.PRIVATE_MEDIA_MAP_SHA256,
        CLOUDINARY_PRIVATE_URL_TTL_SECONDS='300', DJANGO_CONTENT_MEDIA_HOSTS='api.cloudinary.com')
    values.update({flag: 'true' for flag in startup.PRODUCTION_QUALIFICATION_FLAGS})
    return values


def custom_production_environment():
    values = production_environment()
    host, origin = startup.SANDBOX_QUALIFICATION_HOST, startup.PRODUCTION_CUSTOM_ORIGIN
    values.update(RENDER_EXTERNAL_HOSTNAME=host, RENDER_PRODUCTION_APPROVED_ORIGIN=origin,
        RENDER_PRODUCTION_CUSTOM_DOMAIN_VERIFIED='true', PARENT_CHECKOUT_ORIGIN=origin,
        DJANGO_ALLOWED_HOSTS=host + ',' + startup.PRODUCTION_CUSTOM_HOST,
        SQUARE_PRODUCTION_WEBHOOK_NOTIFICATION_URL=origin + '/api/billing/square/webhook/')
    return values


def controlled_production_environment():
    """Synthetic one-period production profile on the existing Free hostname."""
    values = production_environment()
    origin = 'https://' + startup.SANDBOX_QUALIFICATION_HOST
    values.update({flag: 'false' for flag in startup.CONTROLLED_PRODUCTION_DISABLED_FLAGS})
    values.update({flag: 'true' for flag in startup.CONTROLLED_PRODUCTION_FLAGS})
    values.update(RENDER_CONTROLLED_PRODUCTION_CHECKOUT_ENABLED='true',
        RENDER_EXTERNAL_HOSTNAME=startup.SANDBOX_QUALIFICATION_HOST,
        RENDER_PRODUCTION_APPROVED_ORIGIN=origin, PARENT_CHECKOUT_ORIGIN=origin,
        DJANGO_ALLOWED_HOSTS=startup.SANDBOX_QUALIFICATION_HOST,
        SQUARE_PRODUCTION_CONTROLLED_PARENT_IDS='41, 42',
        SQUARE_PRODUCTION_WEBHOOK_NOTIFICATION_URL=origin + '/api/billing/square/webhook/')
    return values


def hosted_production_environment():
    values = controlled_production_environment()
    values.update({flag: 'false' for flag in startup.HOSTED_PRODUCTION_DISABLED_FLAGS})
    values.update({flag: 'true' for flag in startup.HOSTED_PRODUCTION_FLAGS})
    values.update(RENDER_HOSTED_PRODUCTION_CHECKOUT_ENABLED='true',
        SQUARE_PRODUCTION_CONTROLLED_PARENT_IDS='',
        SQUARE_PRODUCTION_HOSTED_MONTHLY_VARIATION_ID='MONTHLY-SYNTHETIC-VARIATION',
        SQUARE_PRODUCTION_HOSTED_YEARLY_VARIATION_ID='YEARLY-SYNTHETIC-VARIATION')
    return values


class RenderStartupTests(unittest.TestCase):
    def lookup_fixture(self, **changes):
        data = dict(pk=41, is_active=True, email_verified_at=object(), is_staff=False,
                    is_superuser=False, kid_profiles=SimpleNamespace(count=Mock(return_value=3)))
        data.update(changes)
        parent = SimpleNamespace(**data)
        class Query(list):
            def only(self, *fields): return self
            def order_by(self, *fields): return self
        manager = Mock()
        manager.normalize_email.side_effect = lambda email: email.lower()
        manager.filter.return_value = Query([parent])
        return parent, SimpleNamespace(objects=manager), Query

    @staticmethod
    def lookup_email_validator(email):
        if not re.fullmatch(r'[^\s<>@,;]+@[^\s<>@,;]+\.[^\s<>@,;]+', email):
            raise ValueError('synthetic-private-validator-detail')

    def test_parent_lookup_absent_performs_no_import_query_output_or_configuration_change(self):
        values = sandbox_environment(); before = dict(values)
        _, model, _ = self.lookup_fixture(); emit = Mock()
        with patch.dict(sys.modules, {'django': None}):
            startup.lookup_sandbox_test_parent(values, user_model=model, emit=emit)
        self.assertEqual(values, before)
        self.assertEqual(model.objects.method_calls, [])
        emit.assert_not_called()

    def test_parent_lookup_returns_only_numeric_receipt_and_never_enrolls_or_mutates(self):
        values = sandbox_environment(); before_ids = values['SQUARE_SANDBOX_TEST_PARENT_IDS']
        values['KK_SANDBOX_TEST_PARENT_LOOKUP_EMAIL'] = 'Synthetic.Parent@Example.Test'
        parent, model, _ = self.lookup_fixture(); emit = Mock()
        startup.lookup_sandbox_test_parent(values, user_model=model,
            validate=self.lookup_email_validator, emit=emit)
        model.objects.filter.assert_called_once_with(email='synthetic.parent@example.test',
            is_active=True, email_verified_at__isnull=False, is_staff=False, is_superuser=False)
        parent.kid_profiles.count.assert_called_once_with()
        receipt = json.loads(emit.call_args.args[0])
        self.assertEqual(receipt, {'sandbox_test_parent_lookup':'eligible_parent','parent_id':41,'profile_count':3})
        self.assertNotIn('Synthetic.Parent', emit.call_args.args[0])
        self.assertNotIn('KK_SANDBOX_TEST_PARENT_LOOKUP_EMAIL', values)
        self.assertEqual(values['SQUARE_SANDBOX_TEST_PARENT_IDS'], before_ids)
        self.assertEqual([call[0] for call in model.objects.method_calls], ['normalize_email', 'filter'])

    def test_parent_lookup_rejects_invalid_email_unqualified_or_wrong_host_before_query(self):
        variants = [('KK_SANDBOX_TEST_PARENT_LOOKUP_EMAIL', value) for value in (
            '', None, 'not-an-email', 'one@example.test,two@example.test',
            'one@example.test;two@example.test', 'Name <one@example.test>',
            ' one@example.test', 'one@example.test\n', 'x'*255)]
        variants += [('RENDER_SANDBOX_CHECKOUT_QUALIFICATION_ENABLED','false'),
            ('RENDER_EXTERNAL_HOSTNAME','other.onrender.com'), ('SQUARE_ENVIRONMENT','production')]
        for name, value in variants:
            values=sandbox_environment(); values['KK_SANDBOX_TEST_PARENT_LOOKUP_EMAIL']='private-parent@example.test'
            values[name]=value
            _, model, _ = self.lookup_fixture(); emit=Mock()
            with self.subTest(name=name, value=value), self.assertRaises(startup.StartupRejected) as caught:
                startup.lookup_sandbox_test_parent(values, user_model=model,
                    validate=self.lookup_email_validator, emit=emit)
            model.objects.filter.assert_not_called(); emit.assert_not_called()
            self.assertNotIn('KK_SANDBOX_TEST_PARENT_LOOKUP_EMAIL',values)
            self.assertNotIn('private-parent',str(caught.exception))
            self.assertNotIn('synthetic-private',str(caught.exception))

    def test_parent_lookup_rejects_inactive_unverified_staff_superuser_zero_or_multiple_matches(self):
        for changes in ({'is_active':False},{'email_verified_at':None},{'is_staff':True},
                        {'is_superuser':True},{'pk':True},{'pk':0}):
            values=sandbox_environment(); values['KK_SANDBOX_TEST_PARENT_LOOKUP_EMAIL']='private-parent@example.test'
            parent, model, _=self.lookup_fixture(**changes); emit=Mock()
            with self.subTest(changes=changes), self.assertRaises(startup.StartupRejected):
                startup.lookup_sandbox_test_parent(values,user_model=model,
                    validate=self.lookup_email_validator,emit=emit)
            parent.kid_profiles.count.assert_not_called(); emit.assert_not_called()
        for size in (0,2):
            values=sandbox_environment(); values['KK_SANDBOX_TEST_PARENT_LOOKUP_EMAIL']='private-parent@example.test'
            parent, model, Query=self.lookup_fixture(); model.objects.filter.return_value=Query([parent]*size)
            with self.subTest(size=size), self.assertRaises(startup.StartupRejected):
                startup.lookup_sandbox_test_parent(values,user_model=model,
                    validate=self.lookup_email_validator,emit=Mock())
            parent.kid_profiles.count.assert_not_called()

    def test_parent_lookup_database_or_profile_error_is_sanitized_and_never_emits_receipt(self):
        for stage in ('query','profile'):
            values=sandbox_environment(); values['KK_SANDBOX_TEST_PARENT_LOOKUP_EMAIL']='private-parent@example.test'
            parent, model, _=self.lookup_fixture(); emit=Mock()
            if stage=='query': model.objects.filter.side_effect=RuntimeError('private-parent synthetic-password private-token')
            else: parent.kid_profiles.count.side_effect=RuntimeError('private-parent synthetic-password private-token')
            with self.assertRaises(startup.StartupRejected) as caught:
                startup.lookup_sandbox_test_parent(values,user_model=model,
                    validate=self.lookup_email_validator,emit=emit)
            emit.assert_not_called()
            self.assertNotIn('private-parent',str(caught.exception))
            self.assertNotIn('synthetic-password',str(caught.exception))
            self.assertNotIn('private-token',str(caught.exception))
            self.assertNotIn('KK_SANDBOX_TEST_PARENT_LOOKUP_EMAIL',values)

    def test_exact_explicit_sandbox_qualification_preserves_existing_startup_validation(self):
        values = sandbox_environment()
        with patch.object(startup.os, 'open', side_effect=AssertionError('Unexpected file/credential read')):
            self.assertEqual(startup.prepare_environment(values), '10000')
        self.assertEqual(values['DJANGO_ALLOWED_HOSTS'], startup.SANDBOX_QUALIFICATION_HOST)
        self.assertEqual(values['SQUARE_SANDBOX_TEST_PARENT_IDS'], '41, 42')
        self.assertNotIn('RENDER_DJANGO_SECRET_SEED', values)
        self.assertNotIn('RENDER_JWT_SIGNING_SEED', values)

    def test_without_explicit_opt_in_all_previous_financial_guards_remain(self):
        for opt_in in (None, 'false', '', 'TRUE', 'yes', '1'):
            values = sandbox_environment()
            if opt_in is None:
                values.pop('RENDER_SANDBOX_CHECKOUT_QUALIFICATION_ENABLED')
            else:
                values['RENDER_SANDBOX_CHECKOUT_QUALIFICATION_ENABLED'] = opt_in
            with self.subTest(opt_in=opt_in), self.assertRaises(startup.StartupRejected):
                startup.prepare_environment(values)

    def test_sandbox_qualification_rejects_wrong_host_origin_production_or_missing_enrollment(self):
        variants = [
            ('RENDER_EXTERNAL_HOSTNAME', 'kingdom-kids-production.onrender.com'),
            ('RENDER_EXTERNAL_HOSTNAME', startup.SANDBOX_QUALIFICATION_HOST + '.attacker.test'),
            ('PARENT_CHECKOUT_ORIGIN', 'http://' + startup.SANDBOX_QUALIFICATION_HOST),
            ('PARENT_CHECKOUT_ORIGIN', 'https://' + startup.SANDBOX_QUALIFICATION_HOST + '/'),
            ('PARENT_CHECKOUT_ORIGIN', 'https://' + startup.SANDBOX_QUALIFICATION_HOST + '?test=1'),
            ('PARENT_CHECKOUT_ORIGIN', 'https://user:password@' + startup.SANDBOX_QUALIFICATION_HOST),
            ('SQUARE_ENVIRONMENT', 'production'),
            ('PAID_CONTENT_ENTITLEMENT_ENVIRONMENT', 'production'),
            ('SQUARE_SANDBOX_TEST_PARENT_IDS', ''), ('SQUARE_SANDBOX_TEST_PARENT_IDS', '*'),
            ('SQUARE_SANDBOX_TEST_PARENT_IDS', '41,'), ('SQUARE_SANDBOX_TEST_PARENT_IDS', '41,01'),
            ('SQUARE_SANDBOX_TEST_PARENT_IDS', '0'), ('SQUARE_SANDBOX_TEST_PARENT_IDS', '-1'),
            ('SQUARE_SANDBOX_TEST_PARENT_IDS', '9223372036854775808'),
            ('SQUARE_SANDBOX_TEST_PARENT_IDS', ','.join(str(value) for value in range(1, 102))),
            ('SQUARE_SANDBOX_TEST_PARENT_IDS', None),
            ('SQUARE_SANDBOX_APPLICATION_ID', 'sq0idp-production-application'),
            ('SQUARE_SANDBOX_WEBHOOK_NOTIFICATION_URL', 'https://different.example/api/billing/square/webhook/'),
            ('SQUARE_SANDBOX_WEBHOOK_NOTIFICATION_URL', 'https://' + startup.SANDBOX_QUALIFICATION_HOST + '/api/billing/square/webhook'),
            ('DJANGO_TRUST_X_FORWARDED_PROTO', 'false'), ('DJANGO_API_NUM_PROXIES', '0'),
            ('SQUARE_API_VERSION', '2026-01-22'),
        ]
        for flag in startup.SANDBOX_QUALIFICATION_FLAGS:
            variants.extend(((flag, 'false'), (flag, 'TRUE')))
        for flag in startup.DISABLED_FLAGS:
            if flag not in startup.SANDBOX_QUALIFICATION_FLAGS:
                variants.append((flag, 'true'))
        for name in ('SQUARE_SANDBOX_APPLICATION_ID', 'SQUARE_SANDBOX_ACCESS_TOKEN',
                     'SQUARE_SANDBOX_MERCHANT_ID', 'SQUARE_SANDBOX_LOCATION_ID',
                     'SQUARE_SANDBOX_WEBHOOK_SIGNATURE_KEY'):
            variants.extend(((name, ''), (name, None), (name, 'synthetic private value')))
        for name, value in variants:
            values = sandbox_environment(); values[name] = value
            with self.subTest(name=name, value=value), self.assertRaises(startup.StartupRejected) as caught:
                startup.prepare_environment(values)
            self.assertNotIn('synthetic private value', str(caught.exception))
            self.assertNotIn('synthetic-not-a-provider-token', str(caught.exception))

    def test_qualification_does_not_relax_debug_email_signing_host_cache_or_port_guards(self):
        for name, value in [('DJANGO_DEBUG', 'true'), ('DJANGO_EMAIL_DELIVERY_ENABLED', ''),
                            ('DJANGO_EMAIL_DELIVERY_ENABLED', 'true'),
                            ('RENDER_DJANGO_SECRET_SEED', 'synthetic-invalid-seed'),
                            ('DJANGO_ALLOWED_HOSTS', '*'),
                            ('DJANGO_CACHE_URL', 'redis://attacker.example:6379'),
                            ('DJANGO_CACHE_ALLOW_INSECURE', 'false'), ('PORT', '80')]:
            values = sandbox_environment(); values[name] = value
            with self.subTest(name=name), self.assertRaises(startup.StartupRejected):
                startup.prepare_environment(values)

    def test_explicit_resend_https_email_is_allowed_without_relaxing_other_guards(self):
        values = environment()
        values.update(DJANGO_EMAIL_DELIVERY_ENABLED='true', DJANGO_EMAIL_BACKEND='Core.resend_backend.EmailBackend',
                      DJANGO_DEFAULT_FROM_EMAIL='Kingdom Kids <support@notify.kingdom.test>',
                      RESEND_VERIFIED_DOMAIN='notify.kingdom.test', RESEND_API_KEY='re_synthetic-not-a-real-secret')
        self.assertEqual(startup.prepare_environment(values), '10000')
        for name, value in [('RESEND_API_KEY', ''), ('RESEND_VERIFIED_DOMAIN', 'other.test'),
                            ('DJANGO_EMAIL_BACKEND', 'django.core.mail.backends.smtp.EmailBackend'),
                            ('SQUARE_SANDBOX_ENABLED', 'true')]:
            invalid = dict(values); invalid[name] = value
            with self.subTest(name=name), self.assertRaises(startup.StartupRejected):
                startup.prepare_environment(invalid)

    def private_environment(self):
        values = environment()
        release = json.loads(startup.PRIVATE_MEDIA_MAP.read_text())
        values.update(CLOUDINARY_PRIVATE_DELIVERY_ENABLED='true',
            CLOUDINARY_CLOUD_NAME=release['cloud_name'], CLOUDINARY_API_KEY='1234567890',
            CLOUDINARY_API_SECRET='synthetic-private-secret-not-a-real-account',
            CLOUDINARY_PRIVATE_MEDIA_MAP_SHA256=startup.PRIVATE_MEDIA_MAP_SHA256,
            CLOUDINARY_PRIVATE_URL_TTL_SECONDS='300', DJANGO_CONTENT_MEDIA_HOSTS='api.cloudinary.com')
        return values

    def test_approved_private_media_is_permitted_without_relaxing_financial_guards(self):
        values = self.private_environment()
        self.assertEqual(startup.prepare_environment(values), '10000')
        for flag in startup.DISABLED_FLAGS:
            with self.subTest(flag=flag):
                invalid = self.private_environment(); invalid[flag] = 'true'
                with self.assertRaises(startup.StartupRejected):
                    startup.prepare_environment(invalid)

    def test_private_media_missing_wrong_or_unsafe_configuration_fails_without_values(self):
        variants = [('CLOUDINARY_CLOUD_NAME', ''), ('CLOUDINARY_CLOUD_NAME', 'wrong-account'),
            ('CLOUDINARY_API_KEY', ''), ('CLOUDINARY_API_KEY', 'not-digits'),
            ('CLOUDINARY_API_SECRET', ''), ('CLOUDINARY_API_SECRET', 'synthetic private secret'),
            ('CLOUDINARY_PRIVATE_MEDIA_MAP_SHA256', '0'*64),
            ('DJANGO_CONTENT_MEDIA_HOSTS', ''), ('DJANGO_CONTENT_MEDIA_HOSTS', 'api.cloudinary.com.attacker.example'),
            ('CLOUDINARY_PRIVATE_URL_TTL_SECONDS', '901'), ('CLOUDINARY_PRIVATE_URL_TTL_SECONDS', '29'),
            ('CLOUDINARY_PRIVATE_DELIVERY_ENABLED', 'misspelled')]
        for name, value in variants:
            with self.subTest(name=name):
                invalid = self.private_environment(); invalid[name] = value
                with self.assertRaises(startup.StartupRejected) as caught:
                    startup.prepare_environment(invalid)
                self.assertNotIn('synthetic private secret', str(caught.exception))
                self.assertNotIn('wrong-account', str(caught.exception))

    def test_private_media_off_never_reads_map_or_credentials(self):
        with patch.object(startup.os, 'open', side_effect=AssertionError('Unexpected file read')):
            self.assertEqual(startup.prepare_environment(environment()), '10000')

    def test_modified_missing_or_symlinked_map_is_rejected(self):
        values = self.private_environment()
        with TemporaryDirectory() as directory:
            missing = Path(directory)/'missing.json'
            corrupt = Path(directory)/'corrupt.json'; corrupt.write_text('{}')
            linked = Path(directory)/'linked.json'; linked.symlink_to(startup.PRIVATE_MEDIA_MAP)
            for path in (missing, corrupt, linked):
                with self.subTest(path=path.name), patch.object(startup, 'PRIVATE_MEDIA_MAP', path):
                    with self.assertRaises(startup.StartupRejected):
                        startup.prepare_environment(dict(values))

    def test_control_socket_is_in_owned_private_writable_tmp_directory(self):
        path = Path(startup.control_socket_path())
        self.addCleanup(shutil.rmtree, path.parent)
        self.assertEqual(path.parent.parent, Path('/tmp'))
        self.assertEqual(path.name, 'control.sock')
        self.assertEqual(path.parent.stat().st_mode & 0o777, 0o700)
        self.assertTrue(os.access(path.parent, os.W_OK))

    def test_independent_platform_seeds_expand_stably_without_leaking_into_server_environment(self):
        a,b=environment(),environment()
        self.assertEqual(startup.prepare_environment(a),'10000');startup.prepare_environment(b)
        for name in ('DJANGO_SECRET_KEY','DJANGO_JWT_SIGNING_KEY'):
            self.assertEqual(len(a[name]),128);self.assertEqual(a[name],b[name])
        self.assertNotEqual(a['DJANGO_SECRET_KEY'],a['DJANGO_JWT_SIGNING_KEY'])
        self.assertNotIn('RENDER_DJANGO_SECRET_SEED',a);self.assertNotIn('RENDER_JWT_SIGNING_SEED',a)
        self.assertEqual(a['DJANGO_ALLOWED_HOSTS'],a['RENDER_EXTERNAL_HOSTNAME'])

    def test_explicit_existing_keys_remain_unchanged_for_original_settings_validation(self):
        values=environment();values.update(DJANGO_SECRET_KEY='a'*60,DJANGO_JWT_SIGNING_KEY='b'*60)
        startup.prepare_environment(values)
        self.assertEqual(values['DJANGO_SECRET_KEY'],'a'*60);self.assertEqual(values['DJANGO_JWT_SIGNING_KEY'],'b'*60)

    def test_short_invalid_seed_and_unsafe_environment_inputs_are_refused_without_values_in_error(self):
        variants=[('RENDER_DJANGO_SECRET_SEED','private-invalid-value'),('RENDER_JWT_SIGNING_SEED',base64.b64encode(b'not32').decode()),
            ('DJANGO_DEBUG','true'),('DJANGO_EMAIL_DELIVERY_ENABLED','true'),
            ('DJANGO_ALLOWED_HOSTS','*'),('RENDER_EXTERNAL_HOSTNAME','attacker.example'),
            ('DJANGO_CACHE_URL','redis://red-private.attacker.example:6379'),('DJANGO_CACHE_ALLOW_INSECURE','false'),
            ('PORT','80'),('PORT','10000 --bad')]
        variants.extend((name,'true') for name in startup.DISABLED_FLAGS)
        for name,value in variants:
            with self.subTest(name=name):
                values=environment();values[name]=value
                with self.assertRaises(startup.StartupRejected) as caught:startup.prepare_environment(values)
                self.assertNotIn('private-invalid-value',str(caught.exception))
                self.assertNotIn('attacker.example',str(caught.exception))

    def test_migration_lock_retries_then_unlocks_and_closes_even_on_migration_failure(self):
        cursor=Mock();cursor.fetchone.side_effect=[(False,),(True,)]
        connection=Mock();connection.__enter__=Mock(return_value=connection);connection.__exit__=Mock(return_value=False)
        connection.cursor.return_value.__enter__=Mock(return_value=cursor)
        connection.cursor.return_value.__exit__=Mock(return_value=False)
        connect=Mock(return_value=connection);sleep=Mock()
        with self.assertRaisesRegex(RuntimeError,'synthetic migration'):
            with startup.migration_lock({},connect=connect,clock=lambda:0,sleep=sleep):
                raise RuntimeError('synthetic migration')
        self.assertEqual(sleep.call_count,1)
        self.assertIn('pg_advisory_unlock',cursor.execute.call_args.args[0])
        connection.__exit__.assert_called_once()

    def test_migration_lock_contention_has_bounded_wait_and_never_runs_body(self):
        cursor=Mock();cursor.fetchone.return_value=(False,)
        connection=Mock();connection.__enter__=Mock(return_value=connection);connection.__exit__=Mock(return_value=False)
        connection.cursor.return_value.__enter__=Mock(return_value=cursor)
        connection.cursor.return_value.__exit__=Mock(return_value=False)
        clock=Mock(side_effect=[0,121])
        with self.assertRaises(startup.StartupRejected):
            with startup.migration_lock({},connect=Mock(return_value=connection),clock=clock,sleep=Mock()):
                self.fail('Must not migrate without ownership')
        connection.__exit__.assert_called_once()

    def run_start(self,fail_migration=False,private_media=False,fail_bootstrap=None,private_family=False,sandbox_checkout=False,parent_lookup=False,production_checkout=False,controlled_checkout=False,hosted_checkout=False):
        events=[]
        _, lookup_model, _ = self.lookup_fixture()
        lookup_query = lookup_model.objects.filter.return_value
        lookup_model.objects.filter.side_effect = lambda **kwargs: (events.append('parent_lookup_query'), lookup_query)[1]
        original_lookup = startup.lookup_sandbox_test_parent
        def lookup(values):
            return original_lookup(values, user_model=lookup_model, validate=self.lookup_email_validator,
                emit=lambda text, **kwargs: events.append('parent_lookup_receipt'))
        def command(name,**kwargs):
            events.append(name)
            if fail_migration and name=='migrate':raise RuntimeError('synthetic failure')
            if name==fail_bootstrap:raise RuntimeError('synthetic bootstrap failure')
            if name=='install_private_test_family':
                self.assertEqual(kwargs, {'apply':True})
            if name=='install_published_matching_release':
                self.assertEqual(kwargs, {'apply':True, 'publish':True})
        @contextmanager
        def lock(*args,**kwargs):
            events.append('lock');yield;events.append('unlock')
        database=SimpleNamespace(vendor='postgresql',get_connection_params=lambda:{})
        class Connections(dict):
            def close_all(self):events.append('close_connections')
        modules={'django':SimpleNamespace(setup=lambda:events.append('setup')),
            'django.core.management':SimpleNamespace(call_command=command),
            'django.db':SimpleNamespace(connections=Connections(default=database))}
        old_path=list(sys.path)
        try:
            values=self.private_environment() if private_media else environment()
            if sandbox_checkout:
                values.update(sandbox_environment())
            if production_checkout:
                values.update(production_environment())
            if controlled_checkout:
                values.update(controlled_production_environment())
            if hosted_checkout:
                values.update(hosted_production_environment())
            if parent_lookup:
                values['KK_SANDBOX_TEST_PARENT_LOOKUP_EMAIL']='private-parent@example.test'
            if private_family:
                values.update(RENDER_EXTERNAL_HOSTNAME='kingdom-kids-checkout-staging.onrender.com',
                    KK_TEST_FAMILY_IMPORT_ZLIB_B64='synthetic-private-payload',
                    KK_TEST_FAMILY_IMPORT_SHA256='synthetic-digest', KK_TEST_FAMILY_IMPORT_EMAIL='synthetic@example.test')
            with patch.dict(os.environ,values,clear=True),patch.dict(sys.modules,modules),patch.object(startup.os,'chdir'),\
                    patch.object(startup,'migration_lock',lock),\
                    patch.object(startup,'lookup_sandbox_test_parent',side_effect=lookup),\
                    patch.object(startup,'control_socket_path',return_value='/tmp/fixture-private/control.sock'),\
                    patch.object(startup.os,'execvp',side_effect=lambda *args:self.record_exec(events,args,private_family,parent_lookup)):
                if fail_migration or fail_bootstrap:
                    with self.assertRaises(RuntimeError):startup.start()
                else:startup.start()
        finally:sys.path[:]=old_path
        return events

    def record_exec(self, events, args, private_family, parent_lookup=False):
        if private_family:
            for key in ('KK_TEST_FAMILY_IMPORT_ZLIB_B64', 'KK_TEST_FAMILY_IMPORT_SHA256', 'KK_TEST_FAMILY_IMPORT_EMAIL'):
                self.assertNotIn(key, os.environ)
        if parent_lookup:
            self.assertNotIn('KK_SANDBOX_TEST_PARENT_LOOKUP_EMAIL',os.environ)
        events.append(args)

    def test_explicit_family_import_runs_after_release_under_lock_and_secret_env_is_not_inherited(self):
        events = self.run_start(private_media=True, private_family=True)
        self.assertEqual(events[:9], ['setup', 'check', 'lock', 'migrate',
            'install_published_matching_release', 'install_private_media_release',
            'install_private_test_family', 'unlock', 'close_connections'])
        self.assertEqual(events[9][0], 'gunicorn')
        self.run_start(private_family=True, fail_bootstrap='install_private_test_family')

    def test_production_check_and_serialized_migrate_precede_port_bound_server_exec(self):
        events=self.run_start()
        self.assertEqual(events[:7],['setup','check','lock','migrate','install_published_matching_release','unlock','close_connections'])
        executable,args=events[7]
        self.assertEqual(executable,'gunicorn');self.assertIn('0.0.0.0:10000',args)
        self.assertEqual(args[args.index('--workers')+1],'1')
        self.assertEqual(args[args.index('--control-socket')+1], '/tmp/fixture-private/control.sock')
        self.assertEqual(args[args.index('--control-socket-mode')+1], '384')

    def test_authorized_sandbox_still_runs_original_django_checks_and_serialized_bootstrap(self):
        events = self.run_start(sandbox_checkout=True)
        self.assertEqual(events[:7], ['setup', 'check', 'lock', 'migrate',
            'install_published_matching_release', 'unlock', 'close_connections'])
        self.assertEqual(events[7][0], 'gunicorn')

    def test_optional_parent_lookup_follows_checks_and_bootstrap_then_strips_email_before_gunicorn(self):
        events=self.run_start(sandbox_checkout=True,parent_lookup=True)
        self.assertEqual(events[:9],['setup','check','lock','migrate','install_published_matching_release',
            'unlock','parent_lookup_query','parent_lookup_receipt','close_connections'])
        self.assertEqual(events[9][0],'gunicorn')

    def test_failed_migration_never_starts_server(self):
        self.assertEqual(self.run_start(True),['setup','check','lock','migrate'])

    def test_private_media_bootstrap_follows_matching_inside_migration_lock(self):
        events=self.run_start(private_media=True)
        self.assertEqual(events[:8],['setup','check','lock','migrate','install_published_matching_release',
            'install_private_media_release','unlock','close_connections'])

    def test_failed_content_bootstrap_never_starts_server(self):
        for name in ('install_published_matching_release','install_private_media_release'):
            with self.subTest(name=name):
                events=self.run_start(private_media=True,fail_bootstrap=name)
                self.assertFalse(any(isinstance(event,tuple) for event in events))


class HostedProductionRenderStartupTests(unittest.TestCase):
    def test_provider_owned_renewals_on_free_existing_host_require_no_jobs_or_allowlist(self):
        values = hosted_production_environment()
        with patch.dict(sys.modules, {'django': None, 'psycopg': None, 'http.client': None}):
            self.assertEqual(startup.prepare_environment(values), '10000')
        self.assertEqual(values['SQUARE_PRODUCTION_CONTROLLED_PARENT_IDS'], '')
        for flag in startup.HOSTED_PRODUCTION_DISABLED_FLAGS:
            self.assertEqual(values[flag], 'false')
        self.assertEqual(values['PAID_CONTENT_ENFORCEMENT_ENABLED'], 'true')
        self.assertEqual(values['DJANGO_ALLOWED_HOSTS'], startup.SANDBOX_QUALIFICATION_HOST)
        self.assertNotIn('RENDER_DJANGO_SECRET_SEED', values)

    def test_every_required_hosted_or_security_flag_is_independent(self):
        for flag in startup.HOSTED_PRODUCTION_FLAGS + ('RENDER_HOSTED_PRODUCTION_CHECKOUT_ENABLED',):
            for value in (None, 'false', 'TRUE', ''):
                values = hosted_production_environment()
                if value is None: values.pop(flag)
                else: values[flag] = value
                with self.subTest(flag=flag, value=value), self.assertRaises(startup.StartupRejected):
                    startup.prepare_environment(values)

    def test_old_profiles_jobs_enrollment_and_sandbox_cannot_mix(self):
        for name in startup.HOSTED_PRODUCTION_DISABLED_FLAGS + startup.SANDBOX_ONLY_FLAGS + ('RENDER_SANDBOX_CHECKOUT_QUALIFICATION_ENABLED',):
            values = hosted_production_environment(); values[name] = 'true'
            with self.subTest(name=name), self.assertRaises(startup.StartupRejected): startup.prepare_environment(values)
        for name in startup.SANDBOX_CONFIGURATION_SLOTS + startup.SANDBOX_IMPORT_SLOTS + ('SQUARE_PRODUCTION_CONTROLLED_PARENT_IDS',):
            values = hosted_production_environment(); values[name] = 'private-forbidden-value'
            with self.subTest(name=name), self.assertRaises(startup.StartupRejected) as caught: startup.prepare_environment(values)
            self.assertNotIn('private-forbidden-value', str(caught.exception))
        for fixture in (environment, sandbox_environment, controlled_production_environment, production_environment):
            for name in ('RENDER_HOSTED_PRODUCTION_CHECKOUT_ENABLED', 'SQUARE_PRODUCTION_HOSTED_SUBSCRIPTIONS_ENABLED', 'SQUARE_HOSTED_RELEASE_QUALIFIED'):
                values = fixture(); values[name] = 'true'
                with self.subTest(fixture=fixture.__name__, name=name), self.assertRaises(startup.StartupRejected): startup.prepare_environment(values)

    def test_two_distinct_reviewed_plan_variation_shapes_are_required(self):
        for name in ('SQUARE_PRODUCTION_HOSTED_MONTHLY_VARIATION_ID', 'SQUARE_PRODUCTION_HOSTED_YEARLY_VARIATION_ID'):
            for value in ('', None, 'a'*193, 'private invalid value', 'sandbox-variation', '\u00e9'):
                values = hosted_production_environment(); values[name] = value
                with self.subTest(name=name, value=value), self.assertRaises(startup.StartupRejected) as caught: startup.prepare_environment(values)
                self.assertNotIn('private invalid value', str(caught.exception))
        values = hosted_production_environment()
        values['SQUARE_PRODUCTION_HOSTED_YEARLY_VARIATION_ID'] = values['SQUARE_PRODUCTION_HOSTED_MONTHLY_VARIATION_ID']
        with self.assertRaises(startup.StartupRejected): startup.prepare_environment(values)

    def test_hosted_still_requires_exact_origin_signed_production_and_original_security(self):
        for name, value in (('RENDER_EXTERNAL_HOSTNAME', 'other.onrender.com'), ('DJANGO_ALLOWED_HOSTS', '*'),
                ('PARENT_CHECKOUT_ORIGIN', 'https://api.kingdom-kids.app'), ('PARENT_CHECKOUT_ORIGIN', 'http://' + startup.SANDBOX_QUALIFICATION_HOST),
                ('SQUARE_PRODUCTION_WEBHOOK_SIGNATURE_KEY', ''), ('SQUARE_PRODUCTION_WEBHOOK_NOTIFICATION_URL', ''),
                ('SQUARE_PRODUCTION_WEBHOOK_NOTIFICATION_URL', 'https://attacker.test/api/billing/square/webhook/'),
                ('SQUARE_ENVIRONMENT', 'sandbox'), ('PAID_CONTENT_ENTITLEMENT_ENVIRONMENT', 'sandbox'),
                ('DJANGO_DEBUG', 'true'), ('RESEND_API_KEY', ''), ('RENDER_DJANGO_SECRET_SEED', 'invalid-seed'),
                ('DJANGO_CACHE_URL', 'redis://attacker.test:6379'), ('DJANGO_CACHE_ALLOW_INSECURE', 'false'),
                ('PORT', '80'), ('CLOUDINARY_PRIVATE_MEDIA_MAP_SHA256', '0'*64)):
            values = hosted_production_environment(); values[name] = value
            with self.subTest(name=name), self.assertRaises(startup.StartupRejected): startup.prepare_environment(values)
        for value in ('0', '6', '15', '1.0', '', None):
            values = hosted_production_environment(); values['SQUARE_HTTP_TIMEOUT_SECONDS'] = value
            with self.subTest(timeout=value), self.assertRaises(startup.StartupRejected): startup.prepare_environment(values)

    def test_hosted_start_retains_deploycheck_locked_migrations_bootstrap_and_no_job_dispatch(self):
        helper = RenderStartupTests(); events = helper.run_start(hosted_checkout=True)
        self.assertEqual(events[:8], ['setup', 'check', 'lock', 'migrate', 'install_published_matching_release',
            'install_private_media_release', 'unlock', 'close_connections'])
        self.assertEqual(events[8][0], 'gunicorn')
        self.assertEqual(helper.run_start(hosted_checkout=True, fail_migration=True), ['setup', 'check', 'lock', 'migrate'])


class ControlledProductionRenderStartupTests(unittest.TestCase):
    def test_enrolled_production_on_exact_free_host_requires_no_paid_operations_or_jobs(self):
        values = controlled_production_environment()
        with patch.dict(sys.modules, {'django': None, 'psycopg': None, 'http.client': None}):
            self.assertEqual(startup.prepare_environment(values), '10000')
        self.assertEqual(values['DJANGO_ALLOWED_HOSTS'], startup.SANDBOX_QUALIFICATION_HOST)
        for flag in startup.CONTROLLED_PRODUCTION_DISABLED_FLAGS:
            self.assertEqual(values[flag], 'false')
        self.assertNotIn('RENDER_DJANGO_SECRET_SEED', values)
        self.assertNotIn('RENDER_JWT_SIGNING_SEED', values)
        # Public mobile handoff can be separately paused; it is no financial gate.
        values['PARENT_CHECKOUT_HANDOFF_ENABLED'] = 'false'
        self.assertEqual(startup.prepare_environment(values), '10000')

    def test_each_controlled_flag_is_required_and_malformed_opt_ins_fail_closed(self):
        for flag in startup.CONTROLLED_PRODUCTION_FLAGS + ('RENDER_CONTROLLED_PRODUCTION_CHECKOUT_ENABLED',):
            for value in (None, 'false', '', 'TRUE', '1'):
                values = controlled_production_environment()
                if value is None:
                    values.pop(flag)
                else:
                    values[flag] = value
                with self.subTest(flag=flag, value=value), self.assertRaises(startup.StartupRejected):
                    startup.prepare_environment(values)

    def test_public_release_jobs_renewals_sandbox_and_legacy_flags_cannot_be_combined(self):
        for flag in startup.CONTROLLED_PRODUCTION_DISABLED_FLAGS + startup.SANDBOX_ONLY_FLAGS + (
                'RENDER_SANDBOX_CHECKOUT_QUALIFICATION_ENABLED',):
            for value in ('true', 'TRUE', ''):
                values = controlled_production_environment(); values[flag] = value
                with self.subTest(flag=flag, value=value), self.assertRaises(startup.StartupRejected):
                    startup.prepare_environment(values)
        for fixture in (environment, sandbox_environment, production_environment):
            for name, value in (('SQUARE_PRODUCTION_CONTROLLED_CHECKOUT_ENABLED', 'true'),
                    ('SQUARE_PRODUCTION_CONTROLLED_PARENT_IDS', '41'),
                    ('RENDER_CONTROLLED_PRODUCTION_CHECKOUT_ENABLED', 'true')):
                values = fixture(); values[name] = value
                with self.subTest(fixture=fixture.__name__, name=name), self.assertRaises(startup.StartupRejected):
                    startup.prepare_environment(values)

    def test_enrollment_is_bounded_positive_numeric_and_never_printed(self):
        for value in ('', None, '*', '0', '-1', '01', '41,', '41;42', '41,0',
                '9223372036854775808', ','.join(str(item) for item in range(1, 102))):
            values = controlled_production_environment(); values['SQUARE_PRODUCTION_CONTROLLED_PARENT_IDS'] = value
            with self.subTest(value=value), self.assertRaises(startup.StartupRejected) as caught:
                startup.prepare_environment(values)
            self.assertNotIn('9223372036854775808', str(caught.exception))

    def test_origin_callback_environment_and_provider_slots_are_exact(self):
        origin = 'https://' + startup.SANDBOX_QUALIFICATION_HOST
        variants = [('RENDER_EXTERNAL_HOSTNAME', 'other.onrender.com'),
            ('RENDER_EXTERNAL_HOSTNAME', startup.SANDBOX_QUALIFICATION_HOST + '.attacker.test'),
            ('DJANGO_ALLOWED_HOSTS', '*'), ('DJANGO_ALLOWED_HOSTS', startup.SANDBOX_QUALIFICATION_HOST + ',api.kingdom-kids.app'),
            ('PARENT_CHECKOUT_ORIGIN', origin + '/'), ('PARENT_CHECKOUT_ORIGIN', origin + '?x=1'),
            ('PARENT_CHECKOUT_ORIGIN', origin.replace('https:', 'http:')),
            ('PARENT_CHECKOUT_ORIGIN', startup.PRODUCTION_CUSTOM_ORIGIN),
            ('RENDER_PRODUCTION_APPROVED_ORIGIN', startup.PRODUCTION_CUSTOM_ORIGIN),
            ('SQUARE_PRODUCTION_WEBHOOK_NOTIFICATION_URL', ''),
            ('SQUARE_PRODUCTION_WEBHOOK_NOTIFICATION_URL', origin + '/api/billing/square/webhook'),
            ('SQUARE_ENVIRONMENT', 'sandbox'), ('PAID_CONTENT_ENTITLEMENT_ENVIRONMENT', 'sandbox'),
            ('DJANGO_TRUST_X_FORWARDED_PROTO', 'false'), ('DJANGO_API_NUM_PROXIES', '0'),
            ('SQUARE_API_VERSION', '2025-01-01'), ('SQUARE_PRODUCTION_APPLICATION_ID', 'sandbox-synthetic-application')]
        for name in ('SQUARE_PRODUCTION_ACCESS_TOKEN', 'SQUARE_PRODUCTION_MERCHANT_ID',
                'SQUARE_PRODUCTION_LOCATION_ID', 'SQUARE_PRODUCTION_WEBHOOK_SIGNATURE_KEY'):
            variants.extend((name, value) for value in ('', None, 'sandbox-private-value', 'private invalid value'))
        for name in startup.SANDBOX_CONFIGURATION_SLOTS + startup.SANDBOX_IMPORT_SLOTS:
            variants.append((name, 'private-forbidden-value'))
        for name, value in variants:
            values = controlled_production_environment(); values[name] = value
            with self.subTest(name=name, value=value), self.assertRaises(startup.StartupRejected) as caught:
                startup.prepare_environment(values)
            self.assertNotIn('private-forbidden-value', str(caught.exception))
            self.assertNotIn('private invalid value', str(caught.exception))

    def test_original_local_security_guards_and_startup_sequence_are_preserved(self):
        for name, value in (('DJANGO_DEBUG', 'true'), ('RESEND_API_KEY', ''),
                ('DJANGO_EMAIL_BACKEND', 'django.core.mail.backends.console.EmailBackend'),
                ('RENDER_DJANGO_SECRET_SEED', 'private-invalid-seed'),
                ('DJANGO_CACHE_URL', 'redis://attacker.example:6379'),
                ('DJANGO_CACHE_ALLOW_INSECURE', 'false'), ('PORT', '80'),
                ('CLOUDINARY_PRIVATE_MEDIA_MAP_SHA256', '0'*64)):
            values = controlled_production_environment(); values[name] = value
            with self.subTest(name=name), self.assertRaises(startup.StartupRejected):
                startup.prepare_environment(values)
        helper = RenderStartupTests()
        events = helper.run_start(controlled_checkout=True)
        self.assertEqual(events[:8], ['setup', 'check', 'lock', 'migrate', 'install_published_matching_release',
            'install_private_media_release', 'unlock', 'close_connections'])
        self.assertEqual(events[8][0], 'gunicorn')
        self.assertEqual(helper.run_start(controlled_checkout=True, fail_migration=True),
            ['setup', 'check', 'lock', 'migrate'])


class ProductionRenderStartupTests(unittest.TestCase):
    def test_only_pinned_verified_custom_origin_can_reuse_platform_handle(self):
        values = custom_production_environment()
        expected_hosts = values['DJANGO_ALLOWED_HOSTS']
        self.assertEqual(startup.prepare_environment(values), '10000')
        self.assertEqual(values['DJANGO_ALLOWED_HOSTS'], expected_hosts)
        for name, value in (
            ('RENDER_PRODUCTION_CUSTOM_DOMAIN_VERIFIED', 'false'),
            ('RENDER_PRODUCTION_CUSTOM_DOMAIN_VERIFIED', '1'),
            ('RENDER_PRODUCTION_APPROVED_ORIGIN', 'https://other.kingdom-kids.app'),
            ('PARENT_CHECKOUT_ORIGIN', 'https://' + startup.SANDBOX_QUALIFICATION_HOST),
            ('SQUARE_PRODUCTION_WEBHOOK_NOTIFICATION_URL', 'https://' + startup.SANDBOX_QUALIFICATION_HOST + '/api/billing/square/webhook/'),
            ('DJANGO_ALLOWED_HOSTS', startup.SANDBOX_QUALIFICATION_HOST),
            ('DJANGO_ALLOWED_HOSTS', startup.PRODUCTION_CUSTOM_HOST),
            ('DJANGO_ALLOWED_HOSTS', expected_hosts + ',attacker.example'),
            ('DJANGO_ALLOWED_HOSTS', expected_hosts + ',' + startup.PRODUCTION_CUSTOM_HOST),
            ('DJANGO_ALLOWED_HOSTS', '*')):
            changed = custom_production_environment(); changed[name] = value
            with self.subTest(name=name, value=value), self.assertRaises(startup.StartupRejected):
                startup.prepare_environment(changed)
        draft = custom_production_environment(); draft['RENDER_PRODUCTION_CUSTOM_DOMAIN_VERIFIED'] = 'false'
        self.assertFalse(startup.production_preflight_report(draft)['local_configuration_valid'])
        report = startup.production_preflight_report(custom_production_environment())
        self.assertTrue(report['local_configuration_valid'])
        self.assertFalse(report['public_release_ready'])
        self.assertIn('custom_domain_dns_mapping_and_certificate_if_selected', report['runtime_qualification_required'])

    def test_exact_production_contract_passes_local_guards_without_external_imports(self):
        values = production_environment()
        with patch.dict(sys.modules, {'django': None, 'psycopg': None, 'http.client': None}):
            self.assertEqual(startup.prepare_environment(values), '10000')
        self.assertNotIn('RENDER_DJANGO_SECRET_SEED', values)

    def test_production_flags_require_separate_explicit_qualification(self):
        for opt_in in (None, 'false', '', 'TRUE', '1'):
            values = production_environment()
            if opt_in is None:
                values.pop('RENDER_PRODUCTION_CHECKOUT_QUALIFICATION_ENABLED')
            else:
                values['RENDER_PRODUCTION_CHECKOUT_QUALIFICATION_ENABLED'] = opt_in
            with self.subTest(opt_in=opt_in), self.assertRaises(startup.StartupRejected):
                startup.prepare_environment(values)
        for flag in startup.PRODUCTION_ONLY_FLAGS:
            values = environment(); values[flag] = 'true'
            with self.subTest(flag=flag), self.assertRaises(startup.StartupRejected):
                startup.prepare_environment(values)

    def test_every_required_release_flag_and_operations_gate_is_independent(self):
        flags = startup.PRODUCTION_QUALIFICATION_FLAGS + ('RENDER_PRODUCTION_OPERATIONS_QUALIFIED',)
        for flag in flags:
            for value in ('false', '', None):
                values = production_environment()
                if value is None:
                    values.pop(flag)
                else:
                    values[flag] = value
                with self.subTest(flag=flag, value=value), self.assertRaises(startup.StartupRejected):
                    startup.prepare_environment(values)

    def test_exact_origin_callback_and_render_proxy_are_required(self):
        variants = [('RENDER_PRODUCTION_APPROVED_ORIGIN', value) for value in (
            '', 'http://kingdom-kids-release-fixture.onrender.com',
            'https://kingdom-kids-release-fixture.onrender.com/',
            'https://kingdom-kids-release-fixture.onrender.com?query=1',
            'https://user:private@kingdom-kids-release-fixture.onrender.com',
            'https://other.onrender.com', 'https://kingdom-kids-release-fixture.onrender.com:444')]
        variants += [('PARENT_CHECKOUT_ORIGIN', 'https://other.onrender.com'),
            ('SQUARE_PRODUCTION_WEBHOOK_NOTIFICATION_URL', 'https://other.onrender.com/api/billing/square/webhook/'),
            ('SQUARE_PRODUCTION_WEBHOOK_NOTIFICATION_URL', 'https://kingdom-kids-release-fixture.onrender.com/api/billing/square/webhook'),
            ('SQUARE_ENVIRONMENT', 'sandbox'), ('PAID_CONTENT_ENTITLEMENT_ENVIRONMENT', 'sandbox'),
            ('DJANGO_TRUST_X_FORWARDED_PROTO', 'false'), ('DJANGO_API_NUM_PROXIES', '0'),
            ('SQUARE_API_VERSION', '2025-01-01')]
        for name, value in variants:
            values = production_environment(); values[name] = value
            with self.subTest(name=name, value=value), self.assertRaises(startup.StartupRejected):
                startup.prepare_environment(values)
        for host in (startup.SANDBOX_QUALIFICATION_HOST, 'example.onrender.com', 'your-production.onrender.com',
                'kingdom-kids-staging.onrender.com', '127.0.0.1', 'localhost', 'private.internal',
                '*.onrender.com', 'attacker.example', 'a'*64 + '.onrender.com'):
            values = production_environment(); origin = 'https://' + host
            values.update(RENDER_EXTERNAL_HOSTNAME=host, RENDER_PRODUCTION_APPROVED_ORIGIN=origin,
                PARENT_CHECKOUT_ORIGIN=origin,
                SQUARE_PRODUCTION_WEBHOOK_NOTIFICATION_URL=origin + '/api/billing/square/webhook/')
            with self.subTest(host=host), self.assertRaises(startup.StartupRejected):
                startup.prepare_environment(values)

    def test_sandbox_and_private_import_configuration_cannot_enter_production(self):
        for name in startup.SANDBOX_ONLY_FLAGS + ('RENDER_SANDBOX_CHECKOUT_QUALIFICATION_ENABLED',):
            values = production_environment(); values[name] = 'true'
            with self.subTest(name=name), self.assertRaises(startup.StartupRejected):
                startup.prepare_environment(values)
        for name in startup.SANDBOX_CONFIGURATION_SLOTS + startup.SANDBOX_IMPORT_SLOTS:
            values = production_environment(); values[name] = 'synthetic-private-sandbox-value'
            with self.subTest(name=name), self.assertRaises(startup.StartupRejected) as caught:
                startup.prepare_environment(values)
            self.assertNotIn('synthetic-private-sandbox-value', str(caught.exception))

    def test_missing_malformed_or_sandbox_labelled_provider_values_fail_redacted(self):
        names = ('SQUARE_PRODUCTION_ACCESS_TOKEN', 'SQUARE_PRODUCTION_MERCHANT_ID',
            'SQUARE_PRODUCTION_LOCATION_ID', 'SQUARE_PRODUCTION_WEBHOOK_SIGNATURE_KEY')
        for name in names:
            for value in ('', 'sandbox-private-value', 'private value', '\nprivate-value'):
                values = production_environment(); values[name] = value
                with self.subTest(name=name, value=value), self.assertRaises(startup.StartupRejected) as caught:
                    startup.prepare_environment(values)
                self.assertNotIn('private-value', str(caught.exception))
        for value in ('sandbox-synthetic-application', '', 'sq0idp-short'):
            values = production_environment(); values['SQUARE_PRODUCTION_APPLICATION_ID'] = value
            with self.subTest(value=value), self.assertRaises(startup.StartupRejected):
                startup.prepare_environment(values)

    def test_all_original_local_security_guards_still_reject_production(self):
        variants = [('DJANGO_DEBUG', 'true'), ('RESEND_API_KEY', ''),
            ('DJANGO_EMAIL_BACKEND', 'django.core.mail.backends.console.EmailBackend'),
            ('RENDER_DJANGO_SECRET_SEED', 'private-invalid-seed'), ('DJANGO_ALLOWED_HOSTS', '*'),
            ('DJANGO_CACHE_URL', 'redis://attacker.example:6379'), ('DJANGO_CACHE_ALLOW_INSECURE', 'false'),
            ('PORT', '80'), ('CLOUDINARY_PRIVATE_MEDIA_MAP_SHA256', '0'*64)]
        for name, value in variants:
            values = production_environment(); values[name] = value
            with self.subTest(name=name), self.assertRaises(startup.StartupRejected):
                startup.prepare_environment(values)

    def test_stored_production_credentials_do_not_change_current_sandbox_qualification(self):
        values = sandbox_environment(); source = production_environment()
        for name in ('SQUARE_PRODUCTION_ACCESS_TOKEN', 'SQUARE_PRODUCTION_MERCHANT_ID',
                'SQUARE_PRODUCTION_LOCATION_ID', 'SQUARE_PRODUCTION_APPLICATION_ID',
                'SQUARE_PRODUCTION_WEBHOOK_SIGNATURE_KEY', 'SQUARE_PRODUCTION_WEBHOOK_NOTIFICATION_URL'):
            values[name] = source[name]
        self.assertEqual(startup.prepare_environment(values), '10000')
        for flag in startup.PRODUCTION_ONLY_FLAGS:
            changed = sandbox_environment(); changed[flag] = 'true'
            with self.subTest(flag=flag), self.assertRaises(startup.StartupRejected):
                startup.prepare_environment(changed)

    def test_production_start_still_checks_migrates_and_bootstraps_before_web_only(self):
        helper = RenderStartupTests()
        events = helper.run_start(production_checkout=True)
        self.assertEqual(events[:8], ['setup', 'check', 'lock', 'migrate', 'install_published_matching_release',
            'install_private_media_release', 'unlock', 'close_connections'])
        self.assertEqual(events[8][0], 'gunicorn')
        self.assertFalse(any(isinstance(value, str) and 'billing_job' in value for value in events))
        failed = helper.run_start(production_checkout=True, fail_migration=True)
        self.assertEqual(failed, ['setup', 'check', 'lock', 'migrate'])

    def test_offline_report_is_redacted_nonmutating_and_never_public_release_ready(self):
        values = production_environment(); original = dict(values)
        with patch.dict(sys.modules, {'django': None, 'psycopg': None, 'http.client': None}):
            report = startup.production_preflight_report(values)
        self.assertEqual(values, original)
        self.assertTrue(report['local_configuration_valid'])
        self.assertFalse(report['public_release_ready'])
        self.assertFalse(report['activation_performed'])
        self.assertEqual(report['provider_operations'], 0)
        self.assertEqual(report['database_operations'], 0)
        self.assertEqual(report['environment_mutations'], 0)
        for name in ('SQUARE_PRODUCTION_ACCESS_TOKEN', 'SQUARE_PRODUCTION_MERCHANT_ID',
                'SQUARE_PRODUCTION_LOCATION_ID', 'SQUARE_PRODUCTION_WEBHOOK_SIGNATURE_KEY'):
            self.assertNotIn(values[name], json.dumps(report))
        values['RENDER_PRODUCTION_OPERATIONS_QUALIFIED'] = 'false'
        self.assertFalse(startup.production_preflight_report(values)['local_configuration_valid'])
        draft = environment()
        draft['SQUARE_PRODUCTION_ACCESS_TOKEN'] = original['SQUARE_PRODUCTION_ACCESS_TOKEN']
        self.assertEqual(startup.production_preflight_report(draft)['status'], 'disabled_draft')
        self.assertFalse(startup.production_preflight_report(draft)['public_release_ready'])


if __name__=='__main__':unittest.main()
