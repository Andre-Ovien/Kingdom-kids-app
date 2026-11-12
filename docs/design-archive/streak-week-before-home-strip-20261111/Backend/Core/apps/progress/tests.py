import uuid
from contextlib import nullcontext
from datetime import date, datetime, timedelta, timezone as fixed_timezone
from unittest.mock import patch

from django.db import IntegrityError, transaction
from django.test import SimpleTestCase
from django.urls import reverse
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APITestCase
from rest_framework_simplejwt.tokens import RefreshToken

from apps.accounts.models import KidProfile, KidProfilePreferences, User
from apps.games.models import Game, GameAttempt, GameLevel, KidGameProgress
from apps.stories.models import Story

from .models import KidActivityEvent, StreakDailyVisit
from .progression import LEVEL_TITLES
from .services import _level_payload, build_profile_level, build_reward_receipt


PASSWORD = 'A-strong-password-123!'


class OverallLevelTests(SimpleTestCase):
    def test_every_level_has_its_own_rank_and_keeps_300_xp_spacing(self):
        self.assertEqual(len(LEVEL_TITLES), 15)
        self.assertEqual(len(set(LEVEL_TITLES)), 15)
        for number, title in enumerate(LEVEL_TITLES, start=1):
            with self.subTest(number=number):
                level = _level_payload((number - 1) * 300)
                self.assertEqual(level['number'], number)
                self.assertEqual(level['title'], title)
                self.assertEqual(level['max_level'], 15)
                self.assertEqual(level['is_max_level'], number == 15)
                self.assertEqual(
                    level['next_level_xp'],
                    4200 if number == 15 else number * 300,
                )
        self.assertEqual(LEVEL_TITLES[-1], 'Kingdom Champion')

    def test_final_level_keeps_lifetime_xp_without_a_level_sixteen_milestone(self):
        self.assertEqual(_level_payload(4199)['number'], 14)
        earned = build_reward_receipt(_level_payload(4199), xp_awarded=20)
        self.assertEqual(earned['level_milestone']['level']['number'], 15)
        self.assertEqual(earned['level_milestone']['level']['xp'], 4219)
        for xp in (4200, 4499, 4500, 100_000):
            with self.subTest(xp=xp):
                level = _level_payload(xp)
                self.assertEqual(level['number'], 15)
                self.assertEqual(level['xp'], xp)
                self.assertEqual(level['next_level_xp'], 4200)
                self.assertTrue(level['is_max_level'])
                self.assertIsNone(
                    build_reward_receipt(level, xp_awarded=50)['level_milestone']
                )


class KidActivityEventApiTests(APITestCase):
    def setUp(self):
        self.parent = User.objects.create_user(
            email='activity@example.com',
            password=PASSWORD,
            email_verified_at=timezone.now(),
        )
        self.profile = KidProfile.objects.create(
            parent=self.parent,
            display_name='Amara',
            avatar_key=KidProfile.AvatarKey.STAR,
        )
        self.story = Story.objects.filter(is_published=True).first()
        self.authenticate(self.parent)

    def authenticate(self, user):
        access_token = RefreshToken.for_user(user).access_token
        self.client.credentials(HTTP_AUTHORIZATION=f'Bearer {access_token}')

    def url(self, profile=None):
        return reverse(
            'progress:kid-activity-event-create',
            kwargs={'profile_id': profile or self.profile.pk},
        )

    def payload(self, **overrides):
        return {
            'operation_id': str(uuid.uuid4()),
            'event_type': KidActivityEvent.EventType.STORY_STARTED,
            'story_id': str(self.story.pk),
            **overrides,
        }

    def test_create_requires_a_verified_parent(self):
        self.client.credentials()
        anonymous = self.client.post(self.url(), self.payload(), format='json')
        self.assertEqual(anonymous.status_code, status.HTTP_401_UNAUTHORIZED)

        unverified = User.objects.create_user(
            email='activity-pending@example.com',
            password=PASSWORD,
        )
        unverified_profile = KidProfile.objects.create(
            parent=unverified,
            display_name='Pending Kid',
            avatar_key=KidProfile.AvatarKey.DOVE,
        )
        self.authenticate(unverified)
        rejected = self.client.post(
            self.url(unverified_profile.pk),
            self.payload(),
            format='json',
        )
        self.assertEqual(rejected.status_code, status.HTTP_401_UNAUTHORIZED)
        self.assertEqual(KidActivityEvent.objects.count(), 0)

    def test_missing_and_foreign_profiles_are_indistinguishable_404s(self):
        missing = self.client.post(
            self.url(uuid.uuid4()),
            self.payload(),
            format='json',
        )

        other_parent = User.objects.create_user(
            email='activity-other@example.com',
            password=PASSWORD,
            email_verified_at=timezone.now(),
        )
        foreign_profile = KidProfile.objects.create(
            parent=other_parent,
            display_name='Other Kid',
            avatar_key=KidProfile.AvatarKey.LION,
        )
        foreign = self.client.post(
            self.url(foreign_profile.pk),
            self.payload(),
            format='json',
        )

        self.assertEqual(missing.status_code, status.HTTP_404_NOT_FOUND)
        self.assertEqual(foreign.status_code, status.HTTP_404_NOT_FOUND)
        self.assertEqual(missing.data, foreign.data)
        self.assertEqual(KidActivityEvent.objects.count(), 0)

    def test_new_event_is_recorded_once_and_returns_the_exact_contract(self):
        operation_id = uuid.uuid4()
        response = self.client.post(
            self.url(),
            self.payload(
                operation_id=str(operation_id),
                event_type=KidActivityEvent.EventType.STORY_COMPLETED,
            ),
            format='json',
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(
            set(response.data),
            {
                'event_id',
                'operation_id',
                'profile_id',
                'event_type',
                'story_id',
                'recorded_at',
                'idempotent_replay',
                'xp_awarded',
                'level_milestone',
            },
        )
        event = KidActivityEvent.objects.get()
        self.assertEqual(response.data['event_id'], str(event.pk))
        self.assertEqual(response.data['operation_id'], str(operation_id))
        self.assertEqual(response.data['profile_id'], str(self.profile.pk))
        self.assertEqual(
            response.data['event_type'],
            KidActivityEvent.EventType.STORY_COMPLETED,
        )
        self.assertEqual(response.data['story_id'], str(self.story.pk))
        self.assertEqual(
            response.data['recorded_at'],
            event.created_at.isoformat().replace('+00:00', 'Z'),
        )
        self.assertFalse(response.data['idempotent_replay'])
        self.assertEqual(response.data['xp_awarded'], 50)
        self.assertIsNone(response.data['level_milestone'])

    def test_command_rejects_missing_invalid_and_unknown_fields(self):
        valid = self.payload()
        invalid_payloads = (
            ({key: value for key, value in valid.items() if key != 'operation_id'}, 'operation_id'),
            ({**valid, 'operation_id': 'not-a-uuid'}, 'operation_id'),
            ({**valid, 'event_type': 'story_paused'}, 'event_type'),
            ({**valid, 'story_id': 'not-a-uuid'}, 'story_id'),
            ({**valid, 'profile_id': str(self.profile.pk)}, 'profile_id'),
        )
        for payload, field in invalid_payloads:
            with self.subTest(field=field, payload=payload):
                response = self.client.post(self.url(), payload, format='json')
                self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
                self.assertIn(field, response.data)
        self.assertEqual(KidActivityEvent.objects.count(), 0)

    def test_new_event_requires_a_published_story(self):
        unpublished = Story.objects.create(
            slug='hidden-activity-story',
            title='Hidden Story',
            category='Test',
            summary='Not in the public catalogue.',
            body='Hidden.',
            is_published=False,
        )
        missing = self.client.post(
            self.url(),
            self.payload(story_id=str(uuid.uuid4())),
            format='json',
        )
        hidden = self.client.post(
            self.url(),
            self.payload(story_id=str(unpublished.pk)),
            format='json',
        )

        self.assertEqual(missing.status_code, status.HTTP_404_NOT_FOUND)
        self.assertEqual(hidden.status_code, status.HTTP_404_NOT_FOUND)
        self.assertEqual(missing.data, hidden.data)
        self.assertEqual(KidActivityEvent.objects.count(), 0)

    def test_exact_replay_is_stable_even_if_the_story_is_later_unpublished(self):
        payload = self.payload(event_type=KidActivityEvent.EventType.STORY_COMPLETED)
        created = self.client.post(self.url(), payload, format='json')
        Story.objects.filter(pk=self.story.pk).update(is_published=False)

        replayed = self.client.post(self.url(), payload, format='json')

        self.assertEqual(created.status_code, status.HTTP_201_CREATED)
        self.assertEqual(replayed.status_code, status.HTTP_200_OK)
        self.assertEqual(KidActivityEvent.objects.count(), 1)
        self.assertEqual(
            {key: value for key, value in replayed.data.items() if key != 'idempotent_replay'},
            {key: value for key, value in created.data.items() if key != 'idempotent_replay'},
        )
        self.assertTrue(replayed.data['idempotent_replay'])

    def test_reusing_an_operation_for_different_content_returns_conflict(self):
        second_story = Story.objects.filter(is_published=True).exclude(pk=self.story.pk).first()
        operation_id = str(uuid.uuid4())
        created = self.client.post(
            self.url(),
            self.payload(operation_id=operation_id),
            format='json',
        )
        changed_type = self.client.post(
            self.url(),
            self.payload(
                operation_id=operation_id,
                event_type=KidActivityEvent.EventType.STORY_COMPLETED,
            ),
            format='json',
        )
        changed_story = self.client.post(
            self.url(),
            self.payload(
                operation_id=operation_id,
                story_id=str(second_story.pk),
            ),
            format='json',
        )

        self.assertEqual(created.status_code, status.HTTP_201_CREATED)
        self.assertEqual(changed_type.status_code, status.HTTP_409_CONFLICT)
        self.assertEqual(changed_story.status_code, status.HTTP_409_CONFLICT)
        self.assertEqual(KidActivityEvent.objects.count(), 1)

    def test_operation_ids_are_isolated_per_owned_profile(self):
        sibling = KidProfile.objects.create(
            parent=self.parent,
            display_name='Sibling',
            avatar_key=KidProfile.AvatarKey.CROWN,
        )
        operation_id = str(uuid.uuid4())
        first = self.client.post(
            self.url(),
            self.payload(operation_id=operation_id),
            format='json',
        )
        second = self.client.post(
            self.url(sibling.pk),
            self.payload(operation_id=operation_id),
            format='json',
        )

        self.assertEqual(first.status_code, status.HTTP_201_CREATED)
        self.assertEqual(second.status_code, status.HTTP_201_CREATED)
        self.assertEqual(KidActivityEvent.objects.count(), 2)

    def test_integrity_race_replays_the_winning_event(self):
        payload = self.payload()
        original_create = KidActivityEvent.objects.create

        def concurrent_winner(**kwargs):
            original_create(**kwargs)
            raise IntegrityError('simulated unique-constraint race')

        with (
            patch('apps.progress.views.transaction.atomic', return_value=nullcontext()),
            patch.object(
                KidActivityEvent.objects,
                'create',
                side_effect=concurrent_winner,
            ),
        ):
            response = self.client.post(self.url(), payload, format='json')

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertTrue(response.data['idempotent_replay'])
        self.assertEqual(KidActivityEvent.objects.count(), 1)

    def test_event_ledger_has_no_get_endpoint(self):
        response = self.client.get(self.url())
        self.assertEqual(response.status_code, status.HTTP_405_METHOD_NOT_ALLOWED)


class StreakPresentationClaimApiTests(APITestCase):
    def setUp(self):
        self.parent = User.objects.create_user(
            email='streak@example.com',
            password=PASSWORD,
            email_verified_at=timezone.now(),
        )
        self.profile = KidProfile.objects.create(
            parent=self.parent,
            display_name='Amara',
            avatar_key=KidProfile.AvatarKey.DOVE,
        )
        self.authenticate(self.parent)

    def authenticate(self, user):
        access_token = RefreshToken.for_user(user).access_token
        self.client.credentials(HTTP_AUTHORIZATION=f'Bearer {access_token}')

    def url(self, profile=None):
        return reverse(
            'progress:streak-presentation-claim',
            kwargs={'profile_id': profile or self.profile.pk},
        )

    def claim(self, *, offset=0, profile=None, payload=None):
        return self.client.post(
            self.url(profile),
            payload
            if payload is not None
            else {'timezone_offset_minutes': offset},
            format='json',
        )

    def create_attempt(self, *, created_at, profile=None):
        game = Game.objects.order_by('sort_order').first()
        level = game.levels.order_by('level_number').first()
        attempt = GameAttempt.objects.create(
            operation_id=uuid.uuid4(),
            profile=profile or self.profile,
            game=game,
            level=level,
            submitted_result={'test': True},
            completed=True,
            score=100,
            stars=3,
            feedback='Test result',
            evaluation={},
        )
        GameAttempt.objects.filter(pk=attempt.pk).update(created_at=created_at)
        return attempt

    def create_story_event(
        self,
        *,
        created_at,
        event_type=KidActivityEvent.EventType.STORY_COMPLETED,
        profile=None,
    ):
        event = KidActivityEvent.objects.create(
            profile=profile or self.profile,
            story=Story.objects.filter(is_published=True).first(),
            operation_id=uuid.uuid4(),
            event_type=event_type,
        )
        KidActivityEvent.objects.filter(pk=event.pk).update(
            created_at=created_at
        )
        return event

    def test_claim_requires_a_verified_parent_and_owned_profile(self):
        self.client.credentials()
        anonymous = self.claim()
        self.assertEqual(anonymous.status_code, status.HTTP_401_UNAUTHORIZED)

        other_parent = User.objects.create_user(
            email='streak-other@example.com',
            password=PASSWORD,
            email_verified_at=timezone.now(),
        )
        foreign_profile = KidProfile.objects.create(
            parent=other_parent,
            display_name='Other Kid',
            avatar_key=KidProfile.AvatarKey.LION,
        )
        self.authenticate(self.parent)
        missing = self.claim(profile=uuid.uuid4())
        foreign = self.claim(profile=foreign_profile.pk)

        self.assertEqual(missing.status_code, status.HTTP_404_NOT_FOUND)
        self.assertEqual(foreign.status_code, status.HTTP_404_NOT_FOUND)
        self.assertEqual(missing.data, foreign.data)
        self.assertEqual(StreakDailyVisit.objects.count(), 0)

    def test_claim_rejects_invalid_offsets_missing_and_unknown_fields(self):
        for payload in (
            {},
            {'timezone_offset_minutes': -841},
            {'timezone_offset_minutes': 841},
            {
                'timezone_offset_minutes': 0,
                'device_date': '2026-07-25',
            },
        ):
            response = self.claim(payload=payload)
            self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

        self.assertEqual(StreakDailyVisit.objects.count(), 0)

    @patch('apps.progress.services.timezone.now')
    def test_time_of_day_never_blocks_an_app_open_from_continuing_the_streak(
        self,
        mocked_now,
    ):
        mocked_now.return_value = datetime(
            2026,
            7,
            25,
            16,
            59,
            tzinfo=fixed_timezone.utc,
        )
        self.create_attempt(
            created_at=datetime(
                2026,
                7,
                24,
                12,
                tzinfo=fixed_timezone.utc,
            )
        )

        response = self.claim()

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertTrue(response.data['show'])
        self.assertEqual(
            response.data['presentation']['state'],
            StreakDailyVisit.State.CONTINUED,
        )
        self.assertEqual(response.data['presentation']['current_days'], 2)
        self.assertEqual(StreakDailyVisit.objects.count(), 1)

    @patch('apps.progress.services.timezone.now')
    def test_first_app_open_claims_once_with_the_exact_contract(
        self,
        mocked_now,
    ):
        mocked_now.return_value = datetime(
            2026,
            7,
            25,
            10,
            tzinfo=fixed_timezone.utc,
        )
        first = self.claim()
        second = self.claim()

        self.assertEqual(first.status_code, status.HTTP_200_OK)
        self.assertTrue(first.data['show'])
        presentation = first.data['presentation']
        self.assertEqual(
            presentation['profile'],
            {
                'id': str(self.profile.pk),
                'parent_id': str(self.parent.pk),
                'display_name': 'Amara',
                'avatar_key': KidProfile.AvatarKey.DOVE,
            },
        )
        self.assertEqual(presentation['state'], 'first_streak')
        self.assertEqual(presentation['current_days'], 1)
        self.assertEqual(presentation['longest_days'], 1)
        self.assertEqual(presentation['local_date'], '2026-07-25')
        self.assertEqual(len(presentation['recent_days']), 7)
        self.assertEqual(
            presentation['recent_days'][-1],
            {'date': '2026-07-25', 'active': True},
        )
        self.assertEqual(
            second.data,
            {
                'show': False,
                'profile_id': str(self.profile.pk),
                'xp_awarded': 20,
                'level_milestone': None,
            },
        )
        self.assertEqual(first.data['xp_awarded'], 20)
        self.assertEqual(build_profile_level(self.profile)['xp'], 20)
        claim = StreakDailyVisit.objects.get()
        self.assertEqual(
            claim.state,
            StreakDailyVisit.State.FIRST_STREAK,
        )
        self.assertEqual(claim.timezone_offset_minutes, 0)

    @patch('apps.progress.services.timezone.now')
    def test_consecutive_activity_returns_a_continued_streak(
        self,
        mocked_now,
    ):
        mocked_now.return_value = datetime(
            2026,
            7,
            25,
            10,
            tzinfo=fixed_timezone.utc,
        )
        for day in (23, 24, 25):
            self.create_attempt(
                created_at=datetime(
                    2026,
                    7,
                    day,
                    9,
                    tzinfo=fixed_timezone.utc,
                )
            )

        response = self.claim()

        presentation = response.data['presentation']
        self.assertEqual(presentation['state'], 'continued')
        self.assertEqual(presentation['current_days'], 3)
        self.assertEqual(presentation['longest_days'], 3)

    @patch('apps.progress.services.timezone.now')
    def test_learning_activity_and_app_open_share_one_streak_day(
        self,
        mocked_now,
    ):
        mocked_now.return_value = datetime(
            2026,
            7,
            25,
            18,
            tzinfo=fixed_timezone.utc,
        )
        moment = datetime(
            2026,
            7,
            25,
            12,
            tzinfo=fixed_timezone.utc,
        )
        self.create_story_event(created_at=moment)
        opened = self.claim()

        self.assertTrue(opened.data['show'])
        self.assertEqual(
            opened.data['presentation']['state'],
            StreakDailyVisit.State.FIRST_STREAK,
        )
        self.assertEqual(opened.data['presentation']['current_days'], 1)
        self.assertEqual(opened.data['presentation']['longest_days'], 1)

    @patch('apps.progress.services.timezone.now')
    def test_server_uses_the_supplied_offset_for_the_daily_visit_date(
        self,
        mocked_now,
    ):
        mocked_now.return_value = datetime(
            2026,
            7,
            25,
            23,
            30,
            tzinfo=fixed_timezone.utc,
        )
        utc_plus_one = self.claim(offset=60)

        self.assertTrue(utc_plus_one.data['show'])
        presentation = utc_plus_one.data['presentation']
        self.assertEqual(presentation['state'], 'first_streak')
        self.assertEqual(presentation['local_date'], '2026-07-26')
        self.assertEqual(
            StreakDailyVisit.objects.get().timezone_offset_minutes,
            60,
        )

    @patch('apps.progress.services.timezone.now')
    def test_switching_offsets_cannot_forge_multiple_streak_days(
        self,
        mocked_now,
    ):
        mocked_now.return_value = datetime(
            2026,
            7,
            25,
            12,
            tzinfo=fixed_timezone.utc,
        )

        first = self.claim(offset=-840)
        switched = self.claim(offset=840)

        self.assertEqual(first.status_code, status.HTTP_200_OK)
        self.assertEqual(switched.status_code, status.HTTP_409_CONFLICT)
        self.assertEqual(
            switched.data['code'],
            'streak_timezone_change_too_soon',
        )
        self.assertEqual(StreakDailyVisit.objects.count(), 1)
        preferences = KidProfilePreferences.objects.get(profile=self.profile)
        self.assertEqual(preferences.streak_timezone_offset_minutes, -840)

    def test_database_prevents_duplicate_profile_date_visits(self):
        values = {
            'profile': self.profile,
            'local_date': date(2026, 7, 25),
            'state': StreakDailyVisit.State.FIRST_STREAK,
            'timezone_offset_minutes': 0,
        }
        StreakDailyVisit.objects.create(**values)

        with self.assertRaises(IntegrityError), transaction.atomic():
            StreakDailyVisit.objects.create(
                **{
                    **values,
                    'state': StreakDailyVisit.State.CONTINUED,
                }
            )


class KidProfileSummaryApiTests(APITestCase):
    def setUp(self):
        self.parent = User.objects.create_user(
            email='progress@example.com',
            password=PASSWORD,
            email_verified_at=timezone.now(),
        )
        self.profile = KidProfile.objects.create(
            parent=self.parent,
            display_name='Amara',
            avatar_key=KidProfile.AvatarKey.STAR,
        )
        self.authenticate(self.parent)

    def authenticate(self, user):
        access_token = RefreshToken.for_user(user).access_token
        self.client.credentials(HTTP_AUTHORIZATION=f'Bearer {access_token}')

    def url(self, profile=None):
        return reverse(
            'progress:kid-profile-summary',
            kwargs={'profile_id': profile or self.profile.pk},
        )

    def create_attempt(
        self,
        *,
        profile=None,
        game=None,
        level_number=1,
        created_at=None,
        completed=False,
        stars=0,
    ):
        profile = profile or self.profile
        game = game or Game.objects.filter(is_published=True).order_by('sort_order').first()
        level = game.levels.get(level_number=level_number)
        attempt = GameAttempt.objects.create(
            operation_id=uuid.uuid4(),
            profile=profile,
            game=game,
            level=level,
            submitted_result={'test': True},
            completed=completed,
            score=100 if completed else 20,
            stars=stars,
            feedback='Test result',
            evaluation={},
        )
        if created_at is not None:
            GameAttempt.objects.filter(pk=attempt.pk).update(created_at=created_at)
            attempt.created_at = created_at
        return attempt

    def create_story_event(
        self,
        *,
        story=None,
        profile=None,
        event_type=KidActivityEvent.EventType.STORY_COMPLETED,
        created_at=None,
    ):
        event = KidActivityEvent.objects.create(
            profile=profile or self.profile,
            story=story or Story.objects.filter(is_published=True).first(),
            operation_id=uuid.uuid4(),
            event_type=event_type,
        )
        if created_at is not None:
            KidActivityEvent.objects.filter(pk=event.pk).update(
                created_at=created_at
            )
            event.created_at = created_at
        return event

    def set_progress(self, game, entries, *, profile=None):
        """entries maps level number to (completed, best stars)."""

        profile = profile or self.profile
        level_progress = {
            str(level_number): {
                'best_score': 100 if completed else 40,
                'best_stars': stars,
                'completed': completed,
                'attempts': 1,
            }
            for level_number, (completed, stars) in entries.items()
        }
        highest = 0
        while level_progress.get(str(highest + 1), {}).get('completed'):
            highest += 1
        return KidGameProgress.objects.create(
            profile=profile,
            game=game,
            highest_completed_level=highest,
            total_stars=sum(item['best_stars'] for item in level_progress.values()),
            level_progress=level_progress,
            last_played_at=timezone.now(),
        )

    def test_summary_requires_a_verified_parent(self):
        self.client.credentials()
        anonymous = self.client.get(self.url())
        self.assertEqual(anonymous.status_code, status.HTTP_401_UNAUTHORIZED)

        unverified = User.objects.create_user(
            email='pending@example.com',
            password=PASSWORD,
        )
        unverified_profile = KidProfile.objects.create(
            parent=unverified,
            display_name='Pending Kid',
            avatar_key=KidProfile.AvatarKey.DOVE,
        )
        self.authenticate(unverified)
        rejected = self.client.get(self.url(unverified_profile.pk))
        self.assertEqual(rejected.status_code, status.HTTP_401_UNAUTHORIZED)

    def test_missing_and_foreign_profiles_are_indistinguishable_404s(self):
        missing = self.client.get(self.url(uuid.uuid4()))
        self.assertEqual(missing.status_code, status.HTTP_404_NOT_FOUND)

        other_parent = User.objects.create_user(
            email='other@example.com',
            password=PASSWORD,
            email_verified_at=timezone.now(),
        )
        foreign_profile = KidProfile.objects.create(
            parent=other_parent,
            display_name='Other Kid',
            avatar_key=KidProfile.AvatarKey.LION,
        )
        foreign = self.client.get(self.url(foreign_profile.pk))
        self.assertEqual(foreign.status_code, status.HTTP_404_NOT_FOUND)
        self.assertEqual(missing.data, foreign.data)

    def test_timezone_offset_must_be_an_integer_in_the_full_utc_offset_range(self):
        for invalid in ('Africa/Lagos', '841', '-841'):
            response = self.client.get(
                self.url(),
                {'timezone_offset_minutes': invalid},
            )
            self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
            self.assertIn('timezone_offset_minutes', response.data)

        for valid in ('-840', '0', '840'):
            response = self.client.get(
                self.url(),
                {'timezone_offset_minutes': valid},
            )
            self.assertEqual(response.status_code, status.HTTP_200_OK)

    def test_zero_activity_summary_is_complete_and_honest(self):
        response = self.client.get(self.url())

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(
            response.data['profile'],
            {
                'id': str(self.profile.pk),
                'display_name': 'Amara',
                'avatar_key': KidProfile.AvatarKey.STAR,
            },
        )
        self.assertEqual(
            response.data['level'],
            {
                'number': 1,
                'title': 'Little Explorer',
                'xp': 0,
                'next_level_xp': 300,
                'max_level': 15,
                'is_max_level': False,
            },
        )
        self.assertEqual(
            response.data['stats'],
            {
                'completed_game_levels': 0,
                'total_game_levels': GameLevel.objects.filter(game__is_published=True).count(),
                'game_stars': 0,
                'max_game_stars': GameLevel.objects.filter(game__is_published=True).count() * 3,
                'games_started': 0,
                'games_completed': 0,
                'total_stories': Story.objects.filter(is_published=True).count(),
                'stories_started': 0,
                'stories_completed': 0,
                'earned_badges': 0,
            },
        )
        self.assertEqual(len(response.data['badges']), 5)
        self.assertTrue(all(not badge['earned'] for badge in response.data['badges']))
        self.assertTrue(all(badge['progress'] == 0 for badge in response.data['badges']))
        self.assertEqual(
            response.data['activity_streak'],
            {'current_days': 0, 'longest_days': 0},
        )
        self.assertEqual(len(response.data['weekly_activity']), 5)
        self.assertTrue(
            all(
                week['attempts'] == 0
                and week['story_completions'] == 0
                and week['activities'] == 0
                for week in response.data['weekly_activity']
            )
        )
        self.assertIsNone(response.data['last_activity_at'])

    def test_summary_aggregates_only_the_requested_profile(self):
        first_game, second_game = list(Game.objects.filter(is_published=True).order_by('sort_order')[:2])
        self.set_progress(
            first_game,
            {1: (True, 3), 2: (True, 3), 3: (True, 3)},
        )
        self.set_progress(second_game, {1: (False, 1)})
        self.create_attempt(game=first_game, completed=True, stars=3)
        self.create_attempt(game=second_game, completed=False, stars=1)

        sibling = KidProfile.objects.create(
            parent=self.parent,
            display_name='Sibling',
            avatar_key=KidProfile.AvatarKey.CROWN,
        )
        third_game = Game.objects.filter(is_published=True).order_by('sort_order')[2]
        self.set_progress(
            third_game,
            {1: (True, 3), 2: (True, 3), 3: (True, 3)},
            profile=sibling,
        )
        self.create_attempt(
            profile=sibling,
            game=third_game,
            completed=True,
            stars=3,
        )

        response = self.client.get(self.url())

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data['stats']['completed_game_levels'], 3)
        self.assertEqual(response.data['stats']['game_stars'], 10)
        self.assertEqual(response.data['stats']['games_started'], 2)
        self.assertEqual(response.data['stats']['games_completed'], 1)
        self.assertEqual(response.data['level']['xp'], 500)
        self.assertEqual(response.data['level']['number'], 2)
        self.assertEqual(response.data['level']['next_level_xp'], 600)
        self.assertEqual(response.data['stats']['earned_badges'], 3)

    def test_story_stats_are_distinct_published_and_profile_scoped(self):
        first_story, second_story = list(
            Story.objects.filter(is_published=True).order_by('sort_order')[:2]
        )
        self.create_story_event(
            story=first_story,
            event_type=KidActivityEvent.EventType.STORY_STARTED,
        )
        self.create_story_event(story=first_story)
        self.create_story_event(story=first_story)
        # A completion alone also means the child started this story.
        self.create_story_event(story=second_story)

        unpublished = Story.objects.create(
            slug='retired-progress-story',
            title='Retired Story',
            category='Test',
            summary='No longer in the catalogue.',
            body='Retired.',
            is_published=False,
        )
        self.create_story_event(story=unpublished)

        sibling = KidProfile.objects.create(
            parent=self.parent,
            display_name='Sibling Reader',
            avatar_key=KidProfile.AvatarKey.RAINBOW,
        )
        third_story = Story.objects.filter(is_published=True).exclude(
            pk__in=(first_story.pk, second_story.pk)
        ).first()
        self.create_story_event(story=third_story, profile=sibling)

        response = self.client.get(self.url())

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(
            response.data['stats']['total_stories'],
            Story.objects.filter(is_published=True).count(),
        )
        self.assertEqual(response.data['stats']['stories_started'], 2)
        self.assertEqual(response.data['stats']['stories_completed'], 2)
        # Lifetime reading XP includes retired stories, while catalogue stats
        # and the existing quest-specific badges retain their own scope.
        self.assertEqual(response.data['level']['xp'], 300)
        self.assertEqual(
            response.data['xp_breakdown'],
            {'quests': 0, 'stories': 300, 'streaks': 0},
        )
        self.assertEqual(response.data['stats']['earned_badges'], 0)
        self.assertTrue(
            all(not badge['earned'] for badge in response.data['badges'])
        )

    @patch('apps.progress.services.timezone.now')
    def test_mixed_game_and_story_completions_drive_activity(self, mocked_now):
        mocked_now.return_value = datetime(
            2026,
            7,
            15,
            12,
            tzinfo=fixed_timezone.utc,
        )
        story = Story.objects.filter(is_published=True).first()
        self.create_attempt(
            created_at=datetime(
                2026,
                7,
                13,
                10,
                tzinfo=fixed_timezone.utc,
            )
        )
        self.create_story_event(
            story=story,
            created_at=datetime(
                2026,
                7,
                14,
                10,
                tzinfo=fixed_timezone.utc,
            ),
        )
        self.create_attempt(
            created_at=datetime(
                2026,
                7,
                15,
                8,
                tzinfo=fixed_timezone.utc,
            )
        )
        # Starts appear in story stats, but do not affect activity or recency.
        self.create_story_event(
            story=story,
            event_type=KidActivityEvent.EventType.STORY_STARTED,
            created_at=datetime(
                2026,
                7,
                15,
                11,
                tzinfo=fixed_timezone.utc,
            ),
        )

        response = self.client.get(self.url())

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(
            response.data['activity_streak'],
            {'current_days': 3, 'longest_days': 3},
        )
        current_week = response.data['weekly_activity'][-1]
        self.assertEqual(current_week['attempts'], 2)
        self.assertEqual(current_week['story_completions'], 1)
        self.assertEqual(current_week['activities'], 3)
        self.assertEqual(response.data['last_activity_at'], '2026-07-15T08:00:00Z')
        self.assertEqual(response.data['stats']['stories_started'], 1)
        self.assertEqual(response.data['stats']['stories_completed'], 1)

    @patch('apps.progress.services.timezone.now')
    def test_streak_and_week_buckets_use_local_calendar_boundaries(self, mocked_now):
        mocked_now.return_value = datetime(
            2026,
            7,
            15,
            12,
            tzinfo=fixed_timezone.utc,
        )
        # With UTC+02:00, these are local Sunday 23:30 and Monday 00:30.
        moments = (
            datetime(2026, 7, 10, 10, tzinfo=fixed_timezone.utc),
            datetime(2026, 7, 12, 21, 30, tzinfo=fixed_timezone.utc),
            datetime(2026, 7, 12, 22, 30, tzinfo=fixed_timezone.utc),
            datetime(2026, 7, 13, 22, 30, tzinfo=fixed_timezone.utc),
            datetime(2026, 7, 14, 22, 30, tzinfo=fixed_timezone.utc),
            # A duplicate local Wednesday counts as an attempt, not a streak day.
            datetime(2026, 7, 15, 8, tzinfo=fixed_timezone.utc),
        )
        for moment in moments:
            self.create_attempt(created_at=moment)

        response = self.client.get(
            self.url(),
            {'timezone_offset_minutes': 120},
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(
            response.data['activity_streak'],
            {'current_days': 4, 'longest_days': 4},
        )
        self.assertEqual(response.data['weekly_activity'][-2]['week_start'], '2026-07-06')
        self.assertEqual(response.data['weekly_activity'][-2]['label'], 'Jul 6')
        self.assertEqual(response.data['weekly_activity'][-2]['attempts'], 2)
        self.assertEqual(
            response.data['weekly_activity'][-2]['story_completions'],
            0,
        )
        self.assertEqual(response.data['weekly_activity'][-2]['activities'], 2)
        self.assertEqual(response.data['weekly_activity'][-1]['week_start'], '2026-07-13')
        self.assertEqual(response.data['weekly_activity'][-1]['label'], 'Jul 13')
        self.assertEqual(response.data['weekly_activity'][-1]['attempts'], 4)
        self.assertEqual(
            response.data['weekly_activity'][-1]['story_completions'],
            0,
        )
        self.assertEqual(response.data['weekly_activity'][-1]['activities'], 4)
        self.assertEqual(
            response.data['last_activity_at'],
            '2026-07-15T08:00:00Z',
        )

    def test_all_five_badge_thresholds_and_level_titles_are_deterministic(self):
        first_game, second_game, third_game = list(
            Game.objects.filter(is_published=True).order_by('sort_order')[:3]
        )
        self.set_progress(
            first_game,
            {1: (True, 3), 2: (True, 3), 3: (True, 3)},
        )
        self.set_progress(second_game, {1: (True, 2), 2: (True, 2)})
        for game, level_number, stars in (
            (first_game, 1, 3),
            (first_game, 2, 3),
            (first_game, 3, 3),
            (second_game, 1, 2),
            (second_game, 2, 2),
            (third_game, 1, 0),
        ):
            self.create_attempt(
                game=game,
                level_number=level_number,
                completed=stars > 0,
                stars=stars,
            )

        response = self.client.get(self.url())

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(
            response.data['stats'],
            {
                'completed_game_levels': 5,
                'total_game_levels': GameLevel.objects.filter(game__is_published=True).count(),
                'game_stars': 13,
                'max_game_stars': GameLevel.objects.filter(game__is_published=True).count() * 3,
                'games_started': 3,
                'games_completed': 1,
                'total_stories': Story.objects.filter(is_published=True).count(),
                'stories_started': 0,
                'stories_completed': 0,
                'earned_badges': 5,
            },
        )
        self.assertEqual(response.data['level']['xp'], 760)
        self.assertEqual(response.data['level']['number'], 3)
        self.assertEqual(response.data['level']['title'], 'Kind Helper')
        self.assertEqual(response.data['level']['next_level_xp'], 900)
        self.assertEqual(
            [badge['key'] for badge in response.data['badges']],
            [
                'first-play',
                'star-seeker',
                'level-legend',
                'game-explorer',
                'quest-champion',
            ],
        )
        self.assertTrue(all(badge['earned'] for badge in response.data['badges']))
        self.assertTrue(
            all(
                badge['progress'] == badge['target']
                for badge in response.data['badges']
            )
        )


class LearningExperienceApiTests(APITestCase):
    """Exercise real XP awards and stable milestones across learning sources."""

    def setUp(self):
        self.parent = User.objects.create_user(
            email='learning-xp@example.com',
            password=PASSWORD,
            email_verified_at=timezone.now(),
        )
        self.profile = KidProfile.objects.create(
            parent=self.parent,
            display_name='Kai Reader',
            avatar_key=KidProfile.AvatarKey.STAR,
        )
        token = RefreshToken.for_user(self.parent).access_token
        self.client.credentials(HTTP_AUTHORIZATION=f'Bearer {token}')
        self.stories = list(Story.objects.filter(is_published=True)[:7])

    def event(self, story=None, *, event_type='story_completed', operation_id=None):
        return self.client.post(
            reverse(
                'progress:kid-activity-event-create',
                kwargs={'profile_id': self.profile.pk},
            ),
            {
                'operation_id': str(operation_id or uuid.uuid4()),
                'event_type': event_type,
                'story_id': str((story or self.stories[0]).pk),
            },
            format='json',
        )

    def claim(self, *, offset=0):
        return self.client.post(
            reverse(
                'progress:streak-presentation-claim',
                kwargs={'profile_id': self.profile.pk},
            ),
            {'timezone_offset_minutes': offset},
            format='json',
        )

    def summary(self):
        response = self.client.get(
            reverse(
                'progress:kid-profile-summary',
                kwargs={'profile_id': self.profile.pk},
            ),
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data['level'], build_profile_level(self.profile))
        return response.data

    def test_reading_alone_earns_a_level_and_replays_its_original_snapshot(self):
        for story in self.stories[:5]:
            result = self.event(story)
            self.assertEqual(result.status_code, 201)
            self.assertEqual(result.data['xp_awarded'], 50)
            self.assertIsNone(result.data['level_milestone'])
        operation = uuid.uuid4()
        earned = self.event(self.stories[5], operation_id=operation)
        milestone = earned.data['level_milestone']
        self.assertEqual(milestone['previous_level'], 1)
        self.assertEqual(milestone['level']['number'], 2)
        self.assertEqual(milestone['level']['xp'], 300)
        event = KidActivityEvent.objects.get(operation_id=operation)
        self.assertEqual(event.reward_receipt['level_milestone'], milestone)
        # Additional XP must not rewrite a retried operation's celebration.
        self.event(self.stories[6])
        replay = self.event(self.stories[5], operation_id=operation)
        self.assertEqual(replay.status_code, 200)
        self.assertTrue(replay.data['idempotent_replay'])
        self.assertEqual(replay.data['level_milestone'], milestone)
        self.assertEqual(replay.data['xp_awarded'], 50)
        self.assertEqual(self.summary()['level']['xp'], 350)

    def test_story_starts_and_repeated_reads_cannot_multiply_xp(self):
        started = self.event(event_type='story_started')
        self.assertEqual(started.data['xp_awarded'], 0)
        self.assertIsNone(started.data['level_milestone'])
        self.assertEqual(self.summary()['level']['xp'], 0)
        first = self.event()
        repeated = self.event()
        self.assertEqual(first.data['xp_awarded'], 50)
        self.assertEqual(repeated.status_code, 201)
        self.assertEqual(repeated.data['xp_awarded'], 0)
        self.assertIsNone(repeated.data['level_milestone'])
        self.assertEqual(self.summary()['level']['xp'], 50)

    def test_retiring_a_story_keeps_earned_xp_and_its_retry_receipt(self):
        operation = uuid.uuid4()
        earned = self.event(operation_id=operation)
        Story.objects.filter(pk=self.stories[0].pk).update(is_published=False)
        replay = self.event(operation_id=operation)
        self.assertEqual(replay.status_code, 200)
        self.assertEqual(replay.data['xp_awarded'], earned.data['xp_awarded'])
        summary = self.summary()
        self.assertEqual(summary['stats']['stories_completed'], 0)
        self.assertEqual(summary['xp_breakdown']['stories'], 50)
        self.assertEqual(summary['level']['xp'], 50)

    def test_historical_completions_count_without_fabricating_milestones(self):
        historical = []
        for story in self.stories[:3]:
            historical.append(KidActivityEvent.objects.create(
                profile=self.profile,
                story=story,
                operation_id=uuid.uuid4(),
                event_type=KidActivityEvent.EventType.STORY_COMPLETED,
            ))
        self.assertEqual(self.summary()['level']['xp'], 300)
        for event in historical:
            replay = self.event(event.story, operation_id=event.operation_id)
            self.assertEqual(replay.data['xp_awarded'], 0)
            self.assertIsNone(replay.data['level_milestone'])
            event.refresh_from_db()
            self.assertEqual(event.reward_receipt, {})
        repeat = self.event(historical[0].story)
        self.assertEqual(repeat.data['xp_awarded'], 0)
        self.assertIsNone(repeat.data['level_milestone'])
        self.assertEqual(self.summary()['level']['xp'], 300)

    def test_old_and_new_story_awards_keep_their_earned_amount_once_each(self):
        old_receipt = {'xp_awarded': 100, 'level_milestone': None}
        for receipt in ({}, {}, {'xp_awarded': 0}):
            KidActivityEvent.objects.create(
                profile=self.profile,
                story=self.stories[0],
                operation_id=uuid.uuid4(),
                event_type=KidActivityEvent.EventType.STORY_COMPLETED,
                reward_receipt=receipt,
            )
        old = KidActivityEvent.objects.create(
            profile=self.profile,
            story=self.stories[1],
            operation_id=uuid.uuid4(),
            event_type=KidActivityEvent.EventType.STORY_COMPLETED,
            reward_receipt=old_receipt,
        )
        new = self.event(self.stories[2])
        self.assertEqual(new.data['xp_awarded'], 50)
        self.assertEqual(self.event(self.stories[2]).data['xp_awarded'], 0)
        old_replay = self.event(self.stories[1], operation_id=old.operation_id)
        self.assertEqual(old_replay.data['xp_awarded'], 100)
        self.assertEqual(self.summary()['xp_breakdown']['stories'], 250)
        old.refresh_from_db()
        self.assertEqual(old.reward_receipt, old_receipt)

    def test_historical_story_milestones_use_current_ranks_and_suppress_level_sixteen(self):
        for index, (previous, number, xp) in enumerate(((1, 2, 300), (15, 16, 4500))):
            receipt = {
                'xp_awarded': 100,
                'level_milestone': {
                    'previous_level': previous,
                    'level': {
                        'number': number,
                        'title': 'Little Explorer' if number == 2 else 'Kingdom Champion',
                        'xp': xp,
                        'next_level_xp': number * 300,
                    },
                },
            }
            event = KidActivityEvent.objects.create(
                profile=self.profile,
                story=self.stories[index],
                operation_id=uuid.uuid4(),
                event_type=KidActivityEvent.EventType.STORY_COMPLETED,
                reward_receipt=receipt,
            )
            replay = self.event(event.story, operation_id=event.operation_id)
            self.assertEqual(replay.data['xp_awarded'], 100)
            if number == 2:
                self.assertEqual(replay.data['level_milestone']['level'], _level_payload(300))
            else:
                self.assertIsNone(replay.data['level_milestone'])
            event.refresh_from_db()
            self.assertEqual(event.reward_receipt, receipt)

    @patch('apps.progress.services.timezone.now')
    def test_streak_alone_earns_a_level_once_and_keeps_xp_after_a_break(self, now):
        today = date(2026, 7, 25)
        now.return_value = datetime(2026, 7, 25, 12, tzinfo=fixed_timezone.utc)
        for days_ago in range(1, 15):
            StreakDailyVisit.objects.create(
                profile=self.profile,
                local_date=today - timedelta(days=days_ago),
                state=StreakDailyVisit.State.CONTINUED,
                timezone_offset_minutes=0,
            )
        self.assertEqual(self.summary()['level']['xp'], 280)
        earned = self.claim()
        self.assertTrue(earned.data['show'])
        self.assertEqual(earned.data['xp_awarded'], 20)
        self.assertEqual(earned.data['presentation']['current_days'], 15)
        self.assertEqual(earned.data['level_milestone']['previous_level'], 1)
        self.assertEqual(earned.data['level_milestone']['level']['xp'], 300)
        retry = self.claim()
        self.assertFalse(retry.data['show'])
        self.assertNotIn('presentation', retry.data)
        self.assertEqual(retry.data['level_milestone'], earned.data['level_milestone'])
        self.assertEqual(retry.data['xp_awarded'], 20)
        self.assertEqual(self.summary()['xp_breakdown']['streaks'], 300)
        now.return_value = datetime(2026, 7, 28, 12, tzinfo=fixed_timezone.utc)
        restarted = self.claim()
        self.assertEqual(restarted.data['presentation']['current_days'], 1)
        self.assertEqual(self.summary()['level']['xp'], 320)

    @patch('apps.progress.services.timezone.now')
    def test_historical_visit_receipt_is_empty_and_rewards_are_profile_scoped(self, now):
        now.return_value = datetime(2026, 7, 25, 12, tzinfo=fixed_timezone.utc)
        StreakDailyVisit.objects.create(
            profile=self.profile,
            local_date=date(2026, 7, 25),
            state=StreakDailyVisit.State.FIRST_STREAK,
            timezone_offset_minutes=0,
        )
        sibling = KidProfile.objects.create(
            parent=self.parent,
            display_name='Sibling',
            avatar_key=KidProfile.AvatarKey.DOVE,
        )
        KidActivityEvent.objects.create(
            profile=sibling,
            story=self.stories[0],
            operation_id=uuid.uuid4(),
            event_type=KidActivityEvent.EventType.STORY_COMPLETED,
        )
        retry = self.claim()
        self.assertFalse(retry.data['show'])
        self.assertEqual(retry.data['xp_awarded'], 0)
        self.assertIsNone(retry.data['level_milestone'])
        self.assertEqual(self.summary()['xp_breakdown'], {
            'quests': 0, 'stories': 0, 'streaks': 20,
        })

    @patch('apps.progress.services.timezone.now')
    def test_mixed_learning_totals_and_story_milestone_share_one_level(self, now):
        now.return_value = datetime(2026, 7, 25, 12, tzinfo=fixed_timezone.utc)
        game = Game.objects.filter(is_published=True).first()
        KidGameProgress.objects.create(
            profile=self.profile,
            game=game,
            highest_completed_level=1,
            total_stars=3,
            level_progress={'1': {'completed': True, 'best_stars': 3}},
        )
        self.event(self.stories[0])
        self.claim()
        summary = self.summary()
        self.assertEqual(summary['xp_breakdown'], {
            'quests': 160, 'stories': 50, 'streaks': 20,
        })
        self.assertEqual(summary['level']['xp'], 230)
        self.assertIsNone(self.event(self.stories[1]).data['level_milestone'])
        earned = self.event(self.stories[2])
        self.assertEqual(earned.data['level_milestone']['previous_level'], 1)
        self.assertEqual(earned.data['level_milestone']['level']['xp'], 330)
        self.assertEqual(earned.data['level_milestone']['level'], self.summary()['level'])

    @patch('apps.progress.services.timezone.now')
    def test_daily_timezone_retries_cannot_forge_extra_xp(self, now):
        now.return_value = datetime(2026, 7, 25, 23, 30, tzinfo=fixed_timezone.utc)
        first = self.claim(offset=60)
        self.assertEqual(first.data['presentation']['local_date'], '2026-07-26')
        self.assertEqual(self.claim(offset=60).data['xp_awarded'], 20)
        self.assertEqual(self.claim(offset=-840).status_code, 409)
        self.assertEqual(StreakDailyVisit.objects.filter(profile=self.profile).count(), 1)
        self.assertEqual(self.summary()['level']['xp'], 20)

    def test_client_cannot_supply_xp_or_private_reward_receipts(self):
        event_url = reverse(
            'progress:kid-activity-event-create',
            kwargs={'profile_id': self.profile.pk},
        )
        claim_url = reverse(
            'progress:streak-presentation-claim',
            kwargs={'profile_id': self.profile.pk},
        )
        for field, value in (
            ('xp_awarded', 10000),
            ('level_milestone', {'previous_level': 1, 'level': {'number': 50}}),
            ('reward_receipt', {'xp_awarded': 10000}),
        ):
            event = self.client.post(event_url, {
                'operation_id': str(uuid.uuid4()),
                'event_type': 'story_completed',
                'story_id': str(self.stories[0].pk),
                field: value,
            }, format='json')
            claim = self.client.post(claim_url, {
                'timezone_offset_minutes': 0,
                field: value,
            }, format='json')
            self.assertEqual(event.status_code, 400)
            self.assertEqual(claim.status_code, 400)
        self.assertEqual(self.summary()['level']['xp'], 0)
