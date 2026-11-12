"""Portable bootstrap contracts; no local-review guard bypasses."""
from concurrent.futures import ThreadPoolExecutor
import hashlib
import io
import json
from pathlib import Path
from tempfile import TemporaryDirectory
from threading import Event, Lock
import time
import uuid
from unittest.mock import patch

from django.core.management import call_command
from django.core.management.base import CommandError
from django.db import close_old_connections, connection, connections
from django.test import SimpleTestCase, TestCase, TransactionTestCase, skipUnlessDBFeature
from django.utils import timezone
from rest_framework.test import APIClient

from apps.accounts.models import KidProfile, User
from apps.progress.services import build_profile_level
from .management.commands import install_published_matching_release as release
from .management.commands.install_matching_studio import DEFINITIONS as STUDIO, _desired_level
from .management.commands.install_matching_collection import DEFINITIONS as COLLECTION
from .matching_collection import example_scene_matching_result
from .matching_studio import example_coat_studio_result, example_harvest_chain_result
from .models import Game, GameAttempt, GameLevel, KidGameProgress
from .services import evaluate_level, public_level_config


def install(**options):
    output = io.StringIO()
    call_command('install_published_matching_release', stdout=output, **options)
    return output.getvalue()


def catalogue_snapshot():
    return (list(Game.objects.order_by('slug').values()),
            list(GameLevel.objects.order_by('game_id', 'level_number').values()))


class PublishedMatchingBundleTests(SimpleTestCase):
    def test_immutable_bundle_matches_all_reviewed_builders_and_bundled_covers(self):
        self.assertEqual(hashlib.sha256(release.RELEASE_FILE.read_bytes()).hexdigest(), release.RELEASE_SHA256)
        bundle = release.load_release(release.RELEASE_FILE)
        expected = {row['slug']: row for row in (*STUDIO, *COLLECTION)}
        mobile = Path(__file__).resolve().parents[4] / 'Frontend/mobile'
        for game in bundle:
            source = expected[game['slug']]
            self.assertTrue((mobile / game['cover_asset_key']).is_file())
            for key in ('title', 'subtitle', 'description', 'cover_asset_key'):
                self.assertEqual(game[key], source[key])
            for level in game['levels']:
                self.assertEqual({key: level[key] for key in release.LEVEL_FIELDS},
                                 _desired_level(source, level['level_number']))


class PublishedMatchingInstallTests(TestCase):
    def test_default_dry_run_and_explicit_dry_run_make_no_writes(self):
        before = catalogue_snapshot()
        for options in ({}, {'dry_run': True, 'publish': True}):
            self.assertIn('dry-run, no data changed', install(**options))
            self.assertEqual(catalogue_snapshot(), before)

    def test_apply_stages_then_explicit_publish_reaches_fifteen_games_forty_five_levels(self):
        previous = Game.objects.filter(is_published=True).count()
        self.assertEqual(previous, 10)
        install(apply=True)
        self.assertEqual(Game.objects.filter(is_published=True).count(), previous)
        self.assertEqual(Game.objects.filter(slug__in=release.EXPECTED_MODES).count(), 5)
        install(apply=True, publish=True)
        self.assertEqual(Game.objects.filter(is_published=True).count(), 15)
        self.assertEqual(GameLevel.objects.filter(game__is_published=True).count(), 45)
        before = catalogue_snapshot()
        install(apply=True)
        install(apply=True, publish=True)
        self.assertEqual(catalogue_snapshot(), before)

    def test_corrupt_bundle_and_late_identity_conflict_leave_every_row_unchanged(self):
        before = catalogue_snapshot()
        with TemporaryDirectory() as directory:
            path = Path(directory) / 'tampered.json'
            data = json.loads(release.RELEASE_FILE.read_text())
            data['games'][-1]['levels'][-1]['config'] = {}
            path.write_text(json.dumps(data))
            with self.assertRaisesMessage(CommandError, 'checksum'):
                install(apply=True, publish=True, release_file=path)
        self.assertEqual(catalogue_snapshot(), before)
        Game.objects.create(slug='ruths-harvest', game_type='quiz', title='Different identity',
            subtitle='An existing game', description='Must be retained.', cover_asset_key='assets/images/test.png')
        before = catalogue_snapshot()
        with self.assertRaisesMessage(CommandError, 'different game type'):
            install(apply=True, publish=True)
        self.assertEqual(catalogue_snapshot(), before)
        self.assertFalse(Game.objects.filter(slug='creation-match-bloom').exists())

    def test_existing_ids_earned_progress_and_retired_content_survive_reapply_and_conflicts(self):
        install(apply=True, publish=True)
        parent = User.objects.create_user(email='release-history@example.test', password='Release-test-password-123!')
        profile = KidProfile.objects.create(parent=parent, display_name='Ada', avatar_key='lion')
        level = GameLevel.objects.select_related('game').get(game__slug='find-my-sheep', level_number=1)
        progress = KidGameProgress.objects.create(profile=profile, game=level.game,
            total_stars=3, highest_completed_level=1,
            level_progress={'1': {'completed': True, 'stars': 3, 'completion_xp': 50}})
        attempt = GameAttempt.objects.create(profile=profile, game=level.game, level=level,
            operation_id=uuid.uuid4(), completed=True, score=100, stars=3, feedback='Well done')
        earned = build_profile_level(profile)['xp']
        before = catalogue_snapshot()
        install(apply=True, publish=True)
        self.assertEqual(catalogue_snapshot(), before)
        self.assertEqual(build_profile_level(profile)['xp'], earned)
        progress.refresh_from_db(); attempt.refresh_from_db()
        self.assertEqual(progress.highest_completed_level, 1)
        self.assertEqual(attempt.level_id, level.pk)
        level.star_thresholds = [50, 70, 90]
        level.save()
        before = catalogue_snapshot()
        with self.assertRaisesMessage(CommandError, 'different existing rules'):
            install(apply=True, publish=True)
        self.assertEqual(catalogue_snapshot(), before)
        self.assertEqual(build_profile_level(profile)['xp'], earned)

    def test_runtime_write_failure_rolls_back_the_entire_release(self):
        before = catalogue_snapshot()
        original = GameLevel.objects.create
        count = 0

        def fail_after_first(*args, **kwargs):
            nonlocal count
            count += 1
            if count == 2:
                raise RuntimeError('injected write failure')
            return original(*args, **kwargs)

        with patch.object(GameLevel.objects, 'create', side_effect=fail_after_first):
            with self.assertRaisesMessage(RuntimeError, 'injected write failure'):
                install(apply=True, publish=True)
        self.assertEqual(catalogue_snapshot(), before)

    def test_all_fifteen_rounds_work_through_real_catalogue_and_scoring_api(self):
        install(apply=True, publish=True)
        parent = User.objects.create_user(email='release-api@example.test', password='Release-test-password-123!',
                                          email_verified_at=timezone.now())
        profile = KidProfile.objects.create(parent=parent, display_name='Ada', avatar_key='lion')
        client = APIClient(); client.force_authenticate(parent)
        response = client.get('/api/games/', {'profile_id': profile.pk})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(len(response.data), 15)
        for slug in release.EXPECTED_MODES:
            detail = client.get(f'/api/games/{slug}/', {'profile_id': profile.pk})
            self.assertEqual(detail.status_code, 200)
            self.assertEqual(len(detail.data['levels']), 3)
            for level in GameLevel.objects.select_related('game').filter(game__slug=slug):
                mode = level.config['mode']
                builder = (example_coat_studio_result if mode == 'coat_studio'
                           else example_harvest_chain_result if mode == 'harvest_chain'
                           else example_scene_matching_result)
                result = builder(level.config)
                expected = evaluate_level(level, result)
                self.assertTrue(expected.completed)
                public = public_level_config(level)
                self.assertEqual(public, level.config)
                public['mode'] = 'changed'
                self.assertNotEqual(public, level.config)
                receipt = client.post(f'/api/games/{slug}/submit/', {
                    'profile_id': str(profile.pk), 'level_number': level.level_number,
                    'operation_id': str(uuid.uuid4()), 'result': result}, format='json')
                self.assertEqual(receipt.status_code, 201)
                self.assertTrue(receipt.data['completed'])
                self.assertEqual(receipt.data['score'], expected.score)
        self.assertEqual(GameAttempt.objects.filter(profile=profile).count(), 15)


@skipUnlessDBFeature('has_select_for_update')
class PublishedMatchingPostgreSQLConcurrencyTests(TransactionTestCase):
    def test_duplicate_apply_waits_for_release_lock_and_creates_no_duplicate_rows(self):
        entered, release_first = Event(), Event()
        chosen = Lock()
        first = True
        original = release.check_existing

        def hold_once(*args):
            nonlocal first
            with chosen:
                hold = first
                first = False
            if hold:
                entered.set()
                if not release_first.wait(8):
                    raise RuntimeError('Timed out waiting for race probe')
            return original(*args)

        def worker():
            close_old_connections()
            try:
                return install(apply=True, publish=True)
            finally:
                connections.close_all()

        with patch.object(release, 'check_existing', side_effect=hold_once), ThreadPoolExecutor(max_workers=2) as pool:
            futures = [pool.submit(worker), pool.submit(worker)]
            try:
                self.assertTrue(entered.wait(8))
                deadline, blocked = time.monotonic() + 5, False
                while time.monotonic() < deadline:
                    with connection.cursor() as cursor:
                        cursor.execute("SELECT count(*) FROM pg_stat_activity WHERE datname=current_database() "
                                       "AND wait_event_type='Lock' AND wait_event='advisory'")
                        blocked = cursor.fetchone()[0] > 0
                    if blocked:
                        break
                    time.sleep(0.02)
                self.assertTrue(blocked, 'Duplicate importer did not actually wait on release lock')
            finally:
                release_first.set()
            for future in futures:
                self.assertIn('Installed reviewed five', future.result(timeout=10))
        self.assertEqual(Game.objects.filter(slug__in=release.EXPECTED_MODES).count(), 5)
        self.assertEqual(GameLevel.objects.filter(game__slug__in=release.EXPECTED_MODES).count(), 15)
