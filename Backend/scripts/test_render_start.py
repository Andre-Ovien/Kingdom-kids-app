"""No DB, cache, Django, network or secret-manager actions: isolated startup checks."""
import base64
from contextlib import contextmanager
import importlib.util
import json
import os
from pathlib import Path
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


class RenderStartupTests(unittest.TestCase):
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

    def run_start(self,fail_migration=False,private_media=False,fail_bootstrap=None,private_family=False):
        events=[]
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
            if private_family:
                values.update(RENDER_EXTERNAL_HOSTNAME='kingdom-kids-checkout-staging.onrender.com',
                    KK_TEST_FAMILY_IMPORT_ZLIB_B64='synthetic-private-payload',
                    KK_TEST_FAMILY_IMPORT_SHA256='synthetic-digest', KK_TEST_FAMILY_IMPORT_EMAIL='synthetic@example.test')
            with patch.dict(os.environ,values,clear=True),patch.dict(sys.modules,modules),patch.object(startup.os,'chdir'),\
                    patch.object(startup,'migration_lock',lock),\
                    patch.object(startup,'control_socket_path',return_value='/tmp/fixture-private/control.sock'),\
                    patch.object(startup.os,'execvp',side_effect=lambda *args:self.record_exec(events,args,private_family)):
                if fail_migration or fail_bootstrap:
                    with self.assertRaises(RuntimeError):startup.start()
                else:startup.start()
        finally:sys.path[:]=old_path
        return events

    def record_exec(self, events, args, private_family):
        if private_family:
            for key in ('KK_TEST_FAMILY_IMPORT_ZLIB_B64', 'KK_TEST_FAMILY_IMPORT_SHA256', 'KK_TEST_FAMILY_IMPORT_EMAIL'):
                self.assertNotIn(key, os.environ)
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


if __name__=='__main__':unittest.main()
