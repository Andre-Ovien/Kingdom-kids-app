"""Real row-lock regressions; SQLite intentionally cannot prove these guarantees."""

from threading import Barrier, Event, Thread

from django.core.cache import cache
from django.db import DatabaseError, close_old_connections, connection, transaction
from django.test import TransactionTestCase, skipUnlessDBFeature
from django.urls import reverse
from django.utils import timezone
from rest_framework.test import APIClient
from rest_framework_simplejwt.token_blacklist.models import OutstandingToken
from rest_framework_simplejwt.tokens import RefreshToken

from .models import User


class RefreshLockOrderingTests(TransactionTestCase):
    password = 'Strong-refresh-password-2026!'

    def setUp(self):
        cache.clear()
        self.parent = User.objects.create_user(
            email='refresh-lock-parent@example.com',
            password=self.password,
            email_verified_at=timezone.now(),
        )
        self.refresh = RefreshToken.for_user(self.parent)

    @skipUnlessDBFeature('has_select_for_update_nowait')
    def test_refresh_waiting_for_parent_does_not_hold_its_token_lock(self):
        """Deletion locks parent then token; refresh must use the same order.

        Hold the parent as deletion/reset do, then pause refresh immediately
        before its first parent SELECT. The old token must still be lockable by
        the parent-lock owner. Otherwise deleting it can form a lock cycle with
        refresh rotation's new token/user foreign-key check.
        """
        reached_parent_select = Event()
        continue_parent_select = Event()
        outcome = {}

        def refresh_in_another_connection():
            close_old_connections()

            def intercept_parent_read(execute, sql, params, many, context):
                if (
                    sql.lstrip().upper().startswith('SELECT')
                    and 'FROM "accounts_user"' in sql
                    and not reached_parent_select.is_set()
                ):
                    reached_parent_select.set()
                    if not continue_parent_select.wait(10):
                        raise AssertionError('Timed out waiting to resume refresh.')
                return execute(sql, params, many, context)

            try:
                with connection.execute_wrapper(intercept_parent_read):
                    outcome['response'] = APIClient().post(
                        reverse('accounts:token-refresh'),
                        {'refresh': str(self.refresh)},
                        format='json',
                    )
            except BaseException as exc:
                outcome['error'] = exc
            finally:
                connection.close()

        worker = Thread(target=refresh_in_another_connection, daemon=True)
        token_available = False
        reached_parent = False
        try:
            with transaction.atomic():
                User.objects.select_for_update().get(pk=self.parent.pk)
                worker.start()
                reached_parent = reached_parent_select.wait(10)
                if reached_parent:
                    try:
                        with transaction.atomic():
                            OutstandingToken.objects.select_for_update(
                                nowait=True,
                            ).get(jti=self.refresh['jti'])
                        token_available = True
                    except DatabaseError:
                        token_available = False
                continue_parent_select.set()
        finally:
            continue_parent_select.set()
            if worker.ident is not None:
                worker.join(15)

        self.assertFalse(worker.is_alive(), 'Refresh worker did not finish.')
        self.assertNotIn('error', outcome, outcome.get('error'))
        self.assertTrue(reached_parent, 'Refresh did not reach its parent lookup.')
        self.assertEqual(outcome['response'].status_code, 200)
        self.assertTrue(
            token_available,
            'Refresh locked its token before its parent, opposing account deletion.',
        )

    @skipUnlessDBFeature('has_select_for_update')
    def test_simultaneous_refreshes_rotate_a_token_only_once(self):
        start = Barrier(2, timeout=10)
        outcomes = {}

        def rotate(index):
            close_old_connections()
            try:
                start.wait()
                outcomes[index] = APIClient().post(
                    reverse('accounts:token-refresh'),
                    {'refresh': str(self.refresh)},
                    format='json',
                ).status_code
            except BaseException as exc:
                outcomes[index] = exc
            finally:
                connection.close()

        workers = [Thread(target=rotate, args=(index,), daemon=True) for index in range(2)]
        for worker in workers:
            worker.start()
        for worker in workers:
            worker.join(15)
        self.assertFalse(any(worker.is_alive() for worker in workers))
        self.assertCountEqual(outcomes.values(), (200, 401))
        # Original plus one successor, never two independently usable successors.
        self.assertEqual(OutstandingToken.objects.filter(user=self.parent).count(), 2)

    @skipUnlessDBFeature('has_select_for_update')
    def test_account_deletion_wins_over_refresh_waiting_for_its_parent(self):
        reached_parent_select = Event()
        outcome = {}

        def rotate():
            close_old_connections()

            def observe_parent_read(execute, sql, params, many, context):
                if sql.lstrip().upper().startswith('SELECT') and 'FROM "accounts_user"' in sql:
                    reached_parent_select.set()
                return execute(sql, params, many, context)

            try:
                with connection.execute_wrapper(observe_parent_read):
                    outcome['response'] = APIClient().post(
                        reverse('accounts:token-refresh'),
                        {'refresh': str(self.refresh)},
                        format='json',
                    )
            except BaseException as exc:
                outcome['error'] = exc
            finally:
                connection.close()

        worker = Thread(target=rotate, daemon=True)
        deletion = APIClient()
        deletion.force_authenticate(user=self.parent)
        try:
            with transaction.atomic():
                User.objects.select_for_update().get(pk=self.parent.pk)
                worker.start()
                self.assertTrue(reached_parent_select.wait(10))
                deleted = deletion.delete(
                    reverse('accounts:me'),
                    {'password': self.password},
                    format='json',
                )
                self.assertEqual(deleted.status_code, 204)
        finally:
            if worker.ident is not None:
                worker.join(15)
        self.assertFalse(worker.is_alive(), 'Refresh worker did not finish.')
        self.assertNotIn('error', outcome, outcome.get('error'))
        self.assertEqual(outcome['response'].status_code, 401)
        self.assertFalse(User.objects.filter(pk=self.parent.pk).exists())
        self.assertFalse(OutstandingToken.objects.exists())
