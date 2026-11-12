"""Real row-lock/receipt regression tests; SQLite cannot prove these races."""
from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta
from threading import Barrier, Event, Lock
import time
import uuid
from unittest.mock import patch

from django.core.cache import cache
from django.db import close_old_connections, connection, connections
from django.test import TransactionTestCase, skipUnlessDBFeature
from django.utils import timezone
from rest_framework.test import APIClient

from apps.accounts.models import KidProfile, User
from apps.games.models import Game, GameAttempt, GameLevel, KidGameProgress
from .models import KidActivityEvent, StreakDailyVisit
from .progression import XP_PER_COMPLETED_LEVEL, XP_PER_COMPLETED_STORY, XP_PER_STAR, XP_PER_STREAK_DAY
from .services import build_profile_level, build_profile_xp_breakdown
from apps.stories.models import Story


@skipUnlessDBFeature('has_select_for_update')
class PostgreSQLLearningWriteConcurrencyTests(TransactionTestCase):
    def setUp(self):
        cache.clear()
        self.addCleanup(cache.clear)
        self.parent = User.objects.create_user(
            email='learning-races@example.test', password='Strong-test-password-123!',
            email_verified_at=timezone.now(),
        )
        self.profile = KidProfile.objects.create(parent=self.parent, display_name='Ada', avatar_key='kai')
        self.game = Game.objects.create(slug='race-quiz', title='Race Quiz', game_type='quiz',
            subtitle='A concurrency test quest', description='Choose the story answer.',
            cover_asset_key='assets/images/esther.jpeg')
        self.level = self.make_level(self.game, 1)
        self.story = Story.objects.create(slug='race-story', title='Race Story', category='Faith', summary='A story.', body='A real story body.')
        self.result = {'answers': [{'question_id': 'q1', 'option_id': 'yes'}]}

    def make_level(self, game, number):
        return GameLevel.objects.create(
            game=game, level_number=number, title=f'Level {number}', instructions='Choose one answer.', max_score=100,
            star_thresholds=[60, 80, 100],
            config={'questions': [{'id': 'q1', 'prompt': 'Who helped?',
                     'options': [{'id': 'yes', 'text': 'Esther'}, {'id': 'no', 'text': 'No one'}],
                     'correct_option_id': 'yes'}], 'pass_score': 60},
        )

    def request(self, kind, operation=None):
        if kind == 'game':
            return (f'/api/games/{self.game.slug}/submit/', {
                'profile_id': str(self.profile.pk), 'level_number': 1,
                'operation_id': str(operation or uuid.uuid4()), 'result': self.result,
            })
        if kind == 'story':
            return (f'/api/progress/kid-profiles/{self.profile.pk}/activity-events/', {
                'story_id': str(self.story.pk), 'event_type': 'story_completed',
                'operation_id': str(operation or uuid.uuid4()),
            })
        return (f'/api/progress/kid-profiles/{self.profile.pk}/streak-presentations/claim/', {
            'timezone_offset_minutes': 0,
        })

    def race(self, calls):
        # Both requests start independently. The first pauses after acquiring
        # the profile lock. pg_stat_activity must show the other truly waiting
        # on SELECT FOR UPDATE before the first is released.
        start = Barrier(2)
        entered = Event()
        release = Event()
        chosen = Lock()
        pids = []
        original = build_profile_level

        def hold_first(profile):
            with chosen:
                first = not entered.is_set()
                if first:
                    entered.set()
            if first and not release.wait(8):
                raise AssertionError('Profile lock probe timed out')
            return original(profile)

        def send(call):
            close_old_connections()
            try:
                user = User.objects.get(pk=self.parent.pk)
                with chosen:
                    pids.append(connection.connection.info.backend_pid)
                client = APIClient()
                client.force_authenticate(user)
                start.wait(8)
                response = client.post(call[0], call[1], format='json')
                return response.status_code, dict(response.data)
            finally:
                connections['default'].close()

        with patch('apps.games.views.build_profile_level', hold_first), \
             patch('apps.progress.views.build_profile_level', hold_first), \
             patch('apps.progress.services.build_profile_level', hold_first), \
             ThreadPoolExecutor(max_workers=2) as executor:
            futures = [executor.submit(send, call) for call in calls]
            try:
                self.assertTrue(entered.wait(8), 'Neither request reached the protected write')
                blocked = False
                deadline = time.monotonic() + 4
                while time.monotonic() < deadline:
                    with connection.cursor() as cursor:
                        cursor.execute(
                            'SELECT wait_event_type, query FROM pg_stat_activity WHERE pid = ANY(%s)',
                            [pids],
                        )
                        blocked = any(wait == 'Lock' and 'FOR UPDATE' in sql.upper()
                                      for wait, sql in cursor.fetchall())
                    if blocked:
                        break
                    time.sleep(0.01)
                self.assertTrue(blocked, 'A concurrent write did not wait on the shared profile row lock')
            finally:
                release.set()
            return [future.result(timeout=20) for future in futures]

    def test_same_game_operation_replays_one_attempt_and_one_progress_award(self):
        operation = uuid.uuid4()
        responses = self.race([self.request('game', operation), self.request('game', operation)])
        self.assertEqual(sorted(code for code, _ in responses), [200, 201])
        payloads = [data for _, data in responses]
        self.assertEqual(len({str(data['attempt_id']) for data in payloads}), 1)
        self.assertEqual(sorted(data['idempotent_replay'] for data in payloads), [False, True])
        self.assertEqual(GameAttempt.objects.filter(profile=self.profile).count(), 1)
        self.assertEqual(KidGameProgress.objects.filter(profile=self.profile).count(), 1)
        progress = KidGameProgress.objects.get(profile=self.profile)
        self.assertEqual(progress.level_progress['1']['attempts'], 1)
        self.assertEqual(progress.total_stars, 3)
        self.assertEqual(build_profile_level(self.profile)['xp'], XP_PER_COMPLETED_LEVEL + 3 * XP_PER_STAR)

    def test_distinct_game_operations_do_not_duplicate_completion_xp_or_lose_attempts(self):
        responses = self.race([self.request('game'), self.request('game')])
        self.assertEqual([code for code, _ in responses], [201, 201])
        self.assertEqual(GameAttempt.objects.filter(profile=self.profile).count(), 2)
        progress = KidGameProgress.objects.get(profile=self.profile)
        self.assertEqual(progress.level_progress['1']['attempts'], 2)
        self.assertEqual(progress.level_progress['1']['completion_xp'], XP_PER_COMPLETED_LEVEL)
        self.assertEqual(progress.total_stars, 3)
        self.assertEqual(build_profile_level(self.profile)['xp'], XP_PER_COMPLETED_LEVEL + 3 * XP_PER_STAR)

    def test_same_story_operation_has_one_immutable_event_and_one_award(self):
        operation = uuid.uuid4()
        responses = self.race([self.request('story', operation), self.request('story', operation)])
        self.assertEqual(sorted(code for code, _ in responses), [200, 201])
        self.assertEqual(len({data['event_id'] for _, data in responses}), 1)
        self.assertEqual(KidActivityEvent.objects.filter(profile=self.profile).count(), 1)
        self.assertEqual(build_profile_level(self.profile)['xp'], XP_PER_COMPLETED_STORY)

    def test_same_day_streak_claim_has_one_visit_and_one_award(self):
        responses = self.race([self.request('streak'), self.request('streak')])
        self.assertEqual([code for code, _ in responses], [200, 200])
        self.assertEqual(sorted(data['show'] for _, data in responses), [False, True])
        self.assertEqual(StreakDailyVisit.objects.filter(profile=self.profile).count(), 1)
        self.assertEqual(build_profile_level(self.profile)['xp'], XP_PER_STREAK_DAY)

    def seed_near_level_boundary(self):
        history = Game.objects.create(slug='retired-race-history', title='Past Quest', game_type='quiz', is_published=False,
            subtitle='A historical test quest', description='Saved historical progress.',
            cover_asset_key='assets/images/esther.jpeg')
        self.make_level(history, 1)
        self.make_level(history, 2)
        KidGameProgress.objects.create(profile=self.profile, game=history, highest_completed_level=2, total_stars=6,
            level_progress={str(i): {'completed': True, 'best_stars': 3, 'completion_xp': XP_PER_COMPLETED_LEVEL} for i in (1, 2)})
        old_story = Story.objects.create(slug='old-race-story', title='Past Story', category='Faith', summary='A story.', body='A past body.')
        KidActivityEvent.objects.create(profile=self.profile, story=old_story, event_type='story_completed', operation_id=uuid.uuid4(), reward_receipt={'xp_awarded': XP_PER_COMPLETED_STORY})
        StreakDailyVisit.objects.create(profile=self.profile, local_date=timezone.now().date() - timedelta(days=1), state='first_streak', timezone_offset_minutes=0, reward_receipt={'xp_awarded': XP_PER_STREAK_DAY})
        self.assertEqual(build_profile_level(self.profile)['xp'], 290)

    def assert_mixed(self, first, second):
        self.seed_near_level_boundary()
        responses = self.race([self.request(first), self.request(second)])
        self.assertTrue(all(code in (200, 201) for code, _ in responses))
        self.assertEqual(sum(data.get('level_milestone') is not None for _, data in responses), 1)
        rewards = {'game': XP_PER_COMPLETED_LEVEL + 3 * XP_PER_STAR,
                   'story': XP_PER_COMPLETED_STORY, 'streak': XP_PER_STREAK_DAY}
        self.assertEqual(build_profile_level(self.profile)['xp'], 290 + rewards[first] + rewards[second])

    def test_game_and_story_writes_share_one_level_transition(self):
        self.assert_mixed('game', 'story')

    def test_game_and_streak_writes_share_one_level_transition(self):
        self.assert_mixed('game', 'streak')

    def test_story_and_streak_writes_share_one_level_transition(self):
        self.assert_mixed('story', 'streak')

    def test_streamed_receipt_read_closes_its_database_cursor(self):
        KidActivityEvent.objects.bulk_create([
            KidActivityEvent(profile=self.profile, story=self.story, operation_id=uuid.uuid4(), event_type='story_completed', reward_receipt={'xp_awarded': 50 if i == 0 else 0})
            for i in range(1500)
        ])
        with connection.cursor() as cursor:
            cursor.execute('SELECT COUNT(*) FROM pg_cursors')
            before = cursor.fetchone()[0]
        self.assertEqual(build_profile_xp_breakdown(self.profile)['stories'], 50)
        with connection.cursor() as cursor:
            cursor.execute('SELECT COUNT(*) FROM pg_cursors')
            self.assertEqual(cursor.fetchone()[0], before)
