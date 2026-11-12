"""No DB, cache, Django, network or secret-manager actions: isolated startup checks."""
import base64
from contextlib import contextmanager
import importlib.util
import os
from pathlib import Path
import sys
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

    def run_start(self,fail_migration=False):
        events=[]
        def command(name,**kwargs):
            events.append(name)
            if fail_migration and name=='migrate':raise RuntimeError('synthetic failure')
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
            with patch.dict(os.environ,environment(),clear=True),patch.dict(sys.modules,modules),patch.object(startup.os,'chdir'),\
                    patch.object(startup,'migration_lock',lock),patch.object(startup.os,'execvp',side_effect=lambda *args:events.append(args)):
                if fail_migration:
                    with self.assertRaises(RuntimeError):startup.start()
                else:startup.start()
        finally:sys.path[:]=old_path
        return events

    def test_production_check_and_serialized_migrate_precede_port_bound_server_exec(self):
        events=self.run_start()
        self.assertEqual(events[:6],['setup','check','lock','migrate','unlock','close_connections'])
        executable,args=events[6]
        self.assertEqual(executable,'gunicorn');self.assertIn('0.0.0.0:10000',args)
        self.assertEqual(args[args.index('--workers')+1],'1')

    def test_failed_migration_never_starts_server(self):
        self.assertEqual(self.run_start(True),['setup','check','lock','migrate'])


if __name__=='__main__':unittest.main()
