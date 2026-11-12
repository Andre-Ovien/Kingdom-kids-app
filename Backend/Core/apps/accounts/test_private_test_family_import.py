"""Synthetic, isolated import coverage; no private family data or provider calls."""

import base64
from copy import deepcopy
from datetime import timedelta
import hashlib
from io import StringIO
import json
import os
from unittest.mock import patch
from uuid import UUID, uuid4
import zlib

from django.contrib.auth.hashers import check_password, make_password
from django.core.management import call_command
from django.core.management.base import CommandError
from django.test import TestCase
from django.utils import timezone
from django.utils.dateparse import parse_datetime

from apps.games.models import Game, GameAttempt, GameLevel, KidGameProgress
from apps.progress.models import KidActivityEvent, StreakDailyVisit
from apps.stories.models import Story

from .models import (
    KidProfile,
    KidProfilePreferences,
    PrivateFamilyImportReceipt,
    User,
)


SERVICE = 'kingdom-kids-checkout-staging.onrender.com'
PAYLOAD_ENV = 'KK_TEST_FAMILY_IMPORT_ZLIB_B64'
DIGEST_ENV = 'KK_TEST_FAMILY_IMPORT_SHA256'
EMAIL_ENV = 'KK_TEST_FAMILY_IMPORT_EMAIL'


def canonical_bytes(value):
    return json.dumps(
        value, sort_keys=True, separators=(',', ':'), ensure_ascii=False,
    ).encode('utf-8')


def transport_bytes(raw):
    return {
        PAYLOAD_ENV: base64.b64encode(zlib.compress(raw)).decode('ascii'),
        DIGEST_ENV: hashlib.sha256(raw).hexdigest(),
    }


class PrivateTestFamilyImportTests(TestCase):
    """Exercise the public command against the Django test database only."""

    @classmethod
    def setUpTestData(cls):
        cls.story = Story.objects.create(
            id=uuid4(), slug='synthetic-import-story',
            title='Synthetic story', category='Synthetic', summary='A fixture.',
            body='A synthetic story body with a Unicode dove: 🕊.',
        )
        cls.other_story = Story.objects.create(
            id=uuid4(), slug='synthetic-import-other-story',
            title='Unrelated synthetic story', category='Synthetic',
            summary='Another fixture.', body='A different synthetic story.',
        )
        cls.game = Game.objects.create(
            id=uuid4(), slug='synthetic-import-quiz', title='Synthetic quiz',
            subtitle='Synthetic questions', description='An isolated fixture.',
            game_type=Game.Type.QUIZ, cover_asset_key='synthetic/quiz.png',
        )
        cls.level = GameLevel.objects.create(
            id=uuid4(), game=cls.game, level_number=1,
            title='Synthetic first level', instructions='Choose the dove.',
            config={
                'questions': [{
                    'id': 'synthetic-question', 'prompt': 'Which is the dove?',
                    'options': [
                        {'id': 'dove', 'text': 'Dove'},
                        {'id': 'lion', 'text': 'Lion'},
                    ],
                    'correct_option_id': 'dove',
                }],
                'pass_score': 60,
            },
            max_score=100, star_thresholds=[60, 80, 95],
        )
        cls.other_game = Game.objects.create(
            id=uuid4(), slug='synthetic-import-other-quiz',
            title='Unrelated synthetic quiz', subtitle='Different questions',
            description='Another isolated fixture.', game_type=Game.Type.QUIZ,
            cover_asset_key='synthetic/other.png',
        )
        cls.other_level = GameLevel.objects.create(
            id=uuid4(), game=cls.other_game, level_number=1,
            title='Other first level', instructions='Choose the dove.',
            config=deepcopy(cls.level.config), max_score=100,
            star_thresholds=[60, 80, 95],
        )

    def setUp(self):
        self.now = timezone.now().replace(microsecond=0)
        self.old = self.now - timedelta(days=30)
        self.expected_email = 'synthetic-family-import@example.test'
        self.plaintext_password = 'Synthetic-family-password-2026!'
        self.encoded_password = make_password(
            self.plaintext_password, salt='synthetic-import-only',
        )
        self.payload = self.make_payload()

    def make_payload(self):
        historic = self.old.isoformat()
        updated = (self.old + timedelta(days=1)).isoformat()
        profile_ids = [str(uuid4()) for _ in range(3)]
        rule = {
            'game_type': self.game.game_type, 'config': self.level.config,
            'max_score': self.level.max_score,
            'star_thresholds': self.level.star_thresholds,
        }
        return {
            'version': 1, 'import_id': str(uuid4()),
            'target_service': SERVICE,
            'created_at': (self.now - timedelta(minutes=1)).isoformat(),
            'expires_at': (self.now + timedelta(minutes=30)).isoformat(),
            'parent': {
                'email': self.expected_email, 'password': self.encoded_password,
                'is_active': True, 'email_verified_at': historic,
                'date_joined': (self.old - timedelta(days=1)).isoformat(),
                'last_login': updated, 'first_name': 'Synthetic',
                'last_name': 'Parent',
            },
            'profiles': [
                {
                    'id': profile_id, 'display_name': f'Synthetic child {index}',
                    'avatar_key': avatar, 'creation_operation_id': str(uuid4()),
                    'created_at': historic, 'updated_at': updated,
                }
                for index, (profile_id, avatar) in enumerate(
                    zip(profile_ids, ('dove', 'lion', 'star')), start=1,
                )
            ],
            'preferences': [
                {
                    'profile_id': profile_id, 'story_text_scale': scale,
                    'narration_enabled': index != 1,
                    'streak_timezone_offset_minutes': 60,
                    'updated_at': updated,
                }
                for index, (profile_id, scale) in enumerate(zip(
                    profile_ids, ('comfortable', 'large', 'extra_large'),
                ))
            ],
            'games': [{
                'slug': self.game.slug,
                'levels': [{
                    'level_number': 1,
                    'rule_sha256': hashlib.sha256(canonical_bytes(rule)).hexdigest(),
                }],
            }],
            'stories': [{
                'slug': self.story.slug,
                'text_sha256': hashlib.sha256(self.story.body.encode('utf-8')).hexdigest(),
            }],
            'game_progress': [{
                'id': str(uuid4()), 'profile_id': profile_ids[0],
                'game_slug': self.game.slug, 'highest_completed_level': 1,
                'total_stars': 3,
                'level_progress': {
                    '1': {'best_score': 100, 'best_stars': 3,
                          'completed': True, 'attempts': 2, 'completion_xp': 50},
                },
                'last_played_at': historic, 'created_at': historic,
                'updated_at': updated,
            }],
            'game_attempts': [{
                'id': str(uuid4()), 'operation_id': str(uuid4()),
                'profile_id': profile_ids[0], 'game_slug': self.game.slug,
                'level_number': 1,
                'submitted_result': {'answers': [
                    {'question_id': 'synthetic-question', 'option_id': 'dove'},
                ]},
                'completed': True, 'score': 100, 'stars': 3,
                'feedback': 'Synthetic success.',
                'evaluation': {'correct_answers': 1, 'synthetic_history': True},
                'created_at': historic,
            }],
            'story_activity': [{
                'id': str(uuid4()), 'profile_id': profile_ids[1],
                'operation_id': str(uuid4()),
                'event_type': KidActivityEvent.EventType.STORY_COMPLETED,
                'story_slug': self.story.slug, 'created_at': historic,
                'reward_receipt': {'xp_awarded': 20, 'synthetic_history': True},
            }],
            'streak_visits': [{
                'id': str(uuid4()), 'profile_id': profile_ids[2],
                'local_date': self.old.date().isoformat(),
                'state': StreakDailyVisit.State.FIRST_STREAK,
                'timezone_offset_minutes': 60, 'created_at': historic,
                'reward_receipt': {'xp_awarded': 10, 'synthetic_history': True},
            }],
        }

    def snapshot(self):
        return {
            model._meta.label: list(model.objects.order_by('pk').values())
            for model in (
                User, KidProfile, KidProfilePreferences,
                KidGameProgress, GameAttempt, KidActivityEvent, StreakDailyVisit,
                PrivateFamilyImportReceipt, Story, Game, GameLevel,
            )
        }

    def invoke(self, payload=None, *, apply=False, environment=None,
               stdout=None, stderr=None, **options):
        data = self.payload if payload is None else payload
        env = {
            **transport_bytes(canonical_bytes(data)),
            EMAIL_ENV: self.expected_email,
            'RENDER_EXTERNAL_HOSTNAME': SERVICE,
            **(environment or {}),
        }
        with patch.dict(os.environ, {key: value for key, value in env.items()
                                     if value is not None}):
            for key, value in env.items():
                if value is None:
                    os.environ.pop(key, None)
            call_command(
                'install_private_test_family', apply=apply,
                stdout=stdout or StringIO(), stderr=stderr or StringIO(),
                **options,
            )

    def reject(self, payload=None, *, environment=None, **options):
        before = self.snapshot()
        output, errors = StringIO(), StringIO()
        with self.assertRaises(CommandError) as raised:
            self.invoke(
                payload, apply=True, environment=environment,
                stdout=output, stderr=errors, **options,
            )
        self.assertEqual(self.snapshot(), before)
        public_text = str(raised.exception) + output.getvalue() + errors.getvalue()
        self.assertNotIn(self.encoded_password, public_text)
        self.assertNotIn(self.expected_email, public_text)

    def test_default_dry_run_validates_without_writing_or_recording_receipt(self):
        before = self.snapshot()
        output = StringIO()
        self.invoke(stdout=output)
        self.assertEqual(self.snapshot(), before)
        self.assertNotIn(self.encoded_password, output.getvalue())
        self.assertNotIn(self.expected_email, output.getvalue())

    def test_apply_preserves_parent_children_preferences_and_all_history(self):
        catalogue_before = {
            model: list(model.objects.order_by('pk').values())
            for model in (Story, Game, GameLevel)
        }
        self.invoke(apply=True)

        parent = User.objects.get(email=self.expected_email)
        self.assertEqual(parent.password, self.encoded_password)
        self.assertTrue(check_password(self.plaintext_password, parent.password))
        self.assertTrue(parent.is_active)
        self.assertFalse(parent.is_staff)
        self.assertFalse(parent.is_superuser)
        for field in ('email_verified_at', 'date_joined', 'last_login'):
            self.assertEqual(getattr(parent, field), parse_datetime(self.payload['parent'][field]))
        self.assertEqual((parent.first_name, parent.last_name), ('Synthetic', 'Parent'))
        self.assertEqual(
            set(parent.kid_profiles.values_list('pk', flat=True)),
            {UUID(row['id']) for row in self.payload['profiles']},
        )
        for row in self.payload['profiles']:
            child = KidProfile.objects.get(pk=row['id'])
            self.assertEqual(child.parent_id, parent.pk)
            for field in ('display_name', 'avatar_key'):
                self.assertEqual(getattr(child, field), row[field])
            self.assertEqual(child.creation_operation_id, UUID(row['creation_operation_id']))
            for field in ('created_at', 'updated_at'):
                self.assertEqual(getattr(child, field), parse_datetime(row[field]))
        for row in self.payload['preferences']:
            preferences = KidProfilePreferences.objects.get(profile_id=row['profile_id'])
            for field in ('story_text_scale', 'narration_enabled',
                          'streak_timezone_offset_minutes'):
                self.assertEqual(getattr(preferences, field), row[field])
            self.assertEqual(preferences.updated_at, parse_datetime(row['updated_at']))

        # Destination catalogue UUIDs are generated independently. Only the
        # story/game slugs and (game, level number) exist in the payload.
        progress = KidGameProgress.objects.get(pk=self.payload['game_progress'][0]['id'])
        self.assertEqual(progress.game_id, self.game.pk)
        self.assertNotEqual(progress.game_id, self.other_game.pk)
        attempt = GameAttempt.objects.get(pk=self.payload['game_attempts'][0]['id'])
        self.assertEqual((attempt.game_id, attempt.level_id), (self.game.pk, self.level.pk))
        self.assertNotEqual(attempt.level_id, self.other_level.pk)
        activity = KidActivityEvent.objects.get(pk=self.payload['story_activity'][0]['id'])
        self.assertEqual(activity.story_id, self.story.pk)
        self.assertNotEqual(activity.story_id, self.other_story.pk)
        visit = StreakDailyVisit.objects.get(pk=self.payload['streak_visits'][0]['id'])
        for instance, section, fields in (
            (progress, 'game_progress', ('highest_completed_level', 'total_stars', 'level_progress')),
            (attempt, 'game_attempts', ('submitted_result', 'completed', 'score', 'stars', 'feedback', 'evaluation')),
            (activity, 'story_activity', ('event_type', 'reward_receipt')),
            (visit, 'streak_visits', ('state', 'timezone_offset_minutes', 'reward_receipt')),
        ):
            row = self.payload[section][0]
            self.assertEqual(instance.profile_id, UUID(row['profile_id']))
            for field in fields:
                self.assertEqual(getattr(instance, field), row[field])
            self.assertEqual(instance.created_at, parse_datetime(row['created_at']))
        self.assertEqual(progress.updated_at, parse_datetime(self.payload['game_progress'][0]['updated_at']))
        self.assertEqual(progress.last_played_at, self.old)
        self.assertEqual(attempt.operation_id, UUID(self.payload['game_attempts'][0]['operation_id']))
        self.assertEqual(activity.operation_id, UUID(self.payload['story_activity'][0]['operation_id']))
        self.assertEqual(visit.local_date, self.old.date())
        receipt = PrivateFamilyImportReceipt.objects.get(pk=self.payload['import_id'])
        self.assertEqual(receipt.parent_id, parent.pk)
        self.assertEqual(receipt.digest, hashlib.sha256(canonical_bytes(self.payload)).hexdigest())
        self.assertIsNotNone(receipt.completed_at)
        for model, rows in catalogue_before.items():
            self.assertEqual(list(model.objects.order_by('pk').values()), rows)

    def test_receipt_makes_reapply_noop_and_preserves_later_parent_changes(self):
        self.invoke(apply=True)
        parent = User.objects.get(email=self.expected_email)
        parent.first_name = 'Changed after import'
        parent.save(update_fields=('first_name',))
        KidProfilePreferences.objects.filter(
            profile_id=self.payload['profiles'][0]['id'],
        ).update(narration_enabled=False)
        before = self.snapshot()
        self.invoke(apply=True)
        self.assertEqual(self.snapshot(), before)

    def test_legacy_empty_json_defaults_are_preserved_with_history_timestamps(self):
        payload = deepcopy(self.payload)
        payload['game_progress'][0].update(
            highest_completed_level=0, total_stars=0, level_progress={},
        )
        payload['game_attempts'][0].update(
            submitted_result={}, evaluation={}, completed=False, score=0, stars=0,
        )
        payload['story_activity'][0]['reward_receipt'] = {}
        payload['streak_visits'][0]['reward_receipt'] = {}

        self.invoke(payload, apply=True)

        self.assertEqual(User.objects.filter(email=self.expected_email).count(), 1)
        self.assertEqual(KidProfile.objects.count(), 3)
        self.assertEqual(KidProfilePreferences.objects.count(), 3)
        self.assertEqual(PrivateFamilyImportReceipt.objects.count(), 1)
        for section, model, empty_fields in (
            ('game_progress', KidGameProgress, ('level_progress',)),
            ('game_attempts', GameAttempt, ('submitted_result', 'evaluation')),
            ('story_activity', KidActivityEvent, ('reward_receipt',)),
            ('streak_visits', StreakDailyVisit, ('reward_receipt',)),
        ):
            with self.subTest(section=section):
                self.assertEqual(model.objects.count(), 1)
                row = payload[section][0]
                instance = model.objects.get(pk=row['id'])
                self.assertEqual(instance.profile_id, UUID(row['profile_id']))
                for field in empty_fields:
                    self.assertEqual(getattr(instance, field), {})
                for field in ('created_at', 'updated_at', 'last_played_at'):
                    if field in row:
                        self.assertEqual(getattr(instance, field), parse_datetime(row[field]))

    def test_command_redacts_unexpected_exception_and_rolls_back_prior_inserts(self):
        from . import private_family_import

        insert = private_family_import._insert

        def fail_after_parent_and_child_history(model, values):
            if model is KidActivityEvent:
                raise RuntimeError(
                    f'Synthetic exception containing {self.expected_email} '
                    f'and {self.encoded_password}'
                )
            return insert(model, values)

        with patch(
            'apps.accounts.private_family_import._insert',
            side_effect=fail_after_parent_and_child_history,
        ):
            self.reject()

    def test_same_import_id_with_modified_content_and_valid_new_digest_is_rejected(self):
        self.invoke(apply=True)
        changed = deepcopy(self.payload)
        changed['profiles'][0]['display_name'] = 'Modified synthetic payload'
        self.reject(changed)

    def test_completed_receipt_remains_noop_after_payload_expiry(self):
        self.invoke(apply=True)
        before = self.snapshot()
        with patch('django.utils.timezone.now', return_value=self.now + timedelta(days=1)):
            self.invoke(apply=True)
        self.assertEqual(self.snapshot(), before)

    def test_completed_receipt_does_not_recreate_a_deleted_parent(self):
        self.invoke(apply=True)
        User.objects.get(email=self.expected_email).delete()
        before = self.snapshot()
        self.invoke(apply=True)
        self.assertEqual(self.snapshot(), before)
        self.assertIsNone(PrivateFamilyImportReceipt.objects.get(pk=self.payload['import_id']).parent_id)

    def test_unknown_catalogue_references_reject_the_entire_family(self):
        cases = (
            ('stories', 'slug', 'synthetic-missing-story'),
            ('games', 'slug', 'synthetic-missing-game'),
            ('game_progress', 'game_slug', 'synthetic-missing-game'),
            ('game_attempts', 'game_slug', 'synthetic-missing-game'),
            ('game_attempts', 'level_number', 99),
            ('story_activity', 'story_slug', 'synthetic-missing-story'),
        )
        for section, key, value in cases:
            with self.subTest(section=section, field=key):
                changed = deepcopy(self.payload)
                changed[section][0][key] = value
                self.reject(changed)

    def test_changed_catalogue_rules_or_story_text_reject_without_writes(self):
        for section, key in (('games', 'rule_sha256'), ('stories', 'text_sha256')):
            with self.subTest(section=section):
                changed = deepcopy(self.payload)
                reference = changed[section][0]
                if section == 'games':
                    reference = reference['levels'][0]
                reference[key] = '0' * 64
                self.reject(changed)

    def test_foreign_child_uuid_is_never_reparented(self):
        foreign = User.objects.create(
            email='synthetic-foreign-owner@example.test', password=self.encoded_password,
        )
        KidProfile.objects.create(
            id=self.payload['profiles'][1]['id'], parent=foreign,
            display_name='Foreign synthetic child', avatar_key='star',
        )
        self.reject()

    def test_foreign_history_uuids_are_never_overwritten(self):
        foreign = User.objects.create(
            email='synthetic-history-owner@example.test', password=self.encoded_password,
        )
        child = KidProfile.objects.create(
            parent=foreign, display_name='Foreign history child', avatar_key='dove',
        )
        existing = (
            ('game_progress', KidGameProgress, {'profile': child, 'game': self.game}),
            ('game_attempts', GameAttempt, {
                'profile': child, 'game': self.game, 'level': self.level,
                'operation_id': uuid4(), 'feedback': 'Foreign synthetic history.',
            }),
            ('story_activity', KidActivityEvent, {
                'profile': child, 'story': self.story, 'operation_id': uuid4(),
                'event_type': KidActivityEvent.EventType.STORY_STARTED,
            }),
            ('streak_visits', StreakDailyVisit, {
                'profile': child, 'local_date': self.old.date(),
                'state': StreakDailyVisit.State.FIRST_STREAK,
                'timezone_offset_minutes': 0,
            }),
        )
        for section, model, fields in existing:
            with self.subTest(section=section):
                row = model.objects.create(**fields)
                changed = deepcopy(self.payload)
                changed[section][0]['id'] = str(row.pk)
                self.reject(changed)

    def test_existing_email_without_matching_receipt_is_never_overwritten(self):
        User.objects.create(
            email=self.expected_email, password=make_password('Unrelated-synthetic-password!'),
            first_name='Existing synthetic owner',
        )
        self.reject()

    def test_unknown_profile_reference_rejects_all_history_and_preferences(self):
        for section in ('preferences', 'game_progress', 'game_attempts', 'story_activity', 'streak_visits'):
            with self.subTest(section=section):
                changed = deepcopy(self.payload)
                changed[section][0]['profile_id'] = str(uuid4())
                self.reject(changed)

    def test_missing_or_mismatched_private_environment_fails_closed(self):
        cases = (
            {PAYLOAD_ENV: None}, {DIGEST_ENV: None}, {EMAIL_ENV: None},
            {'RENDER_EXTERNAL_HOSTNAME': None},
            {'RENDER_EXTERNAL_HOSTNAME': 'synthetic-production.onrender.com'},
            {'RENDER_EXTERNAL_HOSTNAME': SERVICE + '.attacker.example'},
            {EMAIL_ENV: 'different-synthetic-family@example.test'},
            {DIGEST_ENV: '0' * 64}, {DIGEST_ENV: 'not-a-digest'},
        )
        for index, environment in enumerate(cases):
            with self.subTest(case=index):
                self.reject(environment=environment)

    def test_expired_future_and_overlong_import_windows_fail_closed(self):
        cases = (
            (self.now - timedelta(hours=2), self.now - timedelta(seconds=1)),
            (self.now + timedelta(hours=1), self.now + timedelta(hours=2)),
            (self.now - timedelta(minutes=1), self.now + timedelta(hours=3)),
            (self.now, self.now - timedelta(seconds=1)),
        )
        for created, expires in cases:
            with self.subTest(created=created, expires=expires):
                changed = deepcopy(self.payload)
                changed['created_at'], changed['expires_at'] = created.isoformat(), expires.isoformat()
                self.reject(changed)

    def test_wrong_payload_service_version_or_target_email_fails_closed(self):
        cases = (
            ('target_service', 'synthetic-production.onrender.com'),
            ('version', 2), ('version', True),
            ('created_at', 'not-a-timestamp'),
            ('expires_at', self.now.replace(tzinfo=None).isoformat()),
        )
        for key, value in cases:
            with self.subTest(field=key, value=value):
                changed = deepcopy(self.payload)
                changed[key] = value
                self.reject(changed)
        changed = deepcopy(self.payload)
        changed['parent']['email'] = 'unapproved-synthetic-family@example.test'
        self.reject(changed)

    def test_malformed_transport_and_json_fail_closed(self):
        cases = (
            {PAYLOAD_ENV: 'not valid base64!'},
            {PAYLOAD_ENV: base64.b64encode(b'not zlib').decode('ascii')},
            transport_bytes(b'{malformed json'),
            transport_bytes(b'[]'),
            transport_bytes(b'{"version":1,"version":1}'),
        )
        for index, environment in enumerate(cases):
            with self.subTest(case=index):
                self.reject(environment=environment)

    def test_transport_and_expanded_json_size_limits_fail_closed(self):
        # Highly compressible JSON tests the expanded limit independently of
        # the short encoded environment-variable limit.
        huge_json = b'{"padding":"' + b'x' * (2 * 1024 * 1024) + b'"}'
        cases = (
            {PAYLOAD_ENV: 'A' * 90001},
            transport_bytes(huge_json),
        )
        for index, environment in enumerate(cases):
            with self.subTest(case=index):
                self.reject(environment=environment)

