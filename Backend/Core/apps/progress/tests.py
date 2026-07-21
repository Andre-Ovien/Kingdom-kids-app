import uuid
from contextlib import nullcontext
from datetime import datetime, timezone as fixed_timezone
from unittest.mock import patch

from django.db import IntegrityError
from django.urls import reverse
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APITestCase
from rest_framework_simplejwt.tokens import RefreshToken

from apps.accounts.models import KidProfile, User
from apps.games.models import Game, GameAttempt, KidGameProgress
from apps.stories.models import Story

from .models import KidActivityEvent


PASSWORD = 'A-strong-password-123!'


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
        game = game or Game.objects.order_by('sort_order').first()
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
            },
        )
        self.assertEqual(
            response.data['stats'],
            {
                'completed_game_levels': 0,
                'total_game_levels': 24,
                'game_stars': 0,
                'max_game_stars': 72,
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
        first_game, second_game = list(Game.objects.order_by('sort_order')[:2])
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
        third_game = Game.objects.order_by('sort_order')[2]
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
        # Story activity does not alter the existing game-only XP or badges.
        self.assertEqual(response.data['level']['xp'], 0)
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
            Game.objects.order_by('sort_order')[:3]
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
                'total_game_levels': 24,
                'game_stars': 13,
                'max_game_stars': 72,
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
        self.assertEqual(response.data['level']['title'], 'Brave Believer')
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
