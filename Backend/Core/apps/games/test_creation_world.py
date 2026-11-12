import copy
import os
import unittest

from .creation_world import (build_creation_world_config, example_creation_result,
                             public_creation_world_config, replay_creation_world)


class CreationWorldTests(unittest.TestCase):
    def test_all_three_rounds_are_winnable_and_legacy_items_are_preserved(self):
        for number in (1, 2, 3):
            config = build_creation_world_config(number, {'items': [{'id': 'old', 'label': 'Old'}],
                                                         'expected_sequence': ['old']})
            outcome = replay_creation_world(config, example_creation_result(config))
            self.assertTrue(outcome['completed'])
            self.assertEqual(outcome['score'], 100)
            public = public_creation_world_config(config)
            self.assertEqual(public['items'][0]['id'], 'old')
            self.assertNotIn('expected_sequence', public)

    def test_two_different_landscapes_can_complete(self):
        config = build_creation_world_config(3)
        submission = example_creation_result(config)
        mirror = {cell: (cell // 5) * 5 + 4 - cell % 5 for cell in range(20)}
        # Keep the authored river source, but rearrange the two spare water
        # tiles and the forests without changing day order or meadow access.
        altered = copy.deepcopy(submission)
        changes = {'water-5': 16, 'water-6': 17, 'forest-1': 1, 'forest-2': 6, 'bird-1': 1}
        for command in altered['commands']:
            if command.get('piece_id') in changes:
                command['cell'] = changes[command['piece_id']]
        self.assertTrue(replay_creation_world(config, altered)['completed'])
        self.assertNotEqual(replay_creation_world(config, submission)['placements'],
                            replay_creation_world(config, altered)['placements'])

    def test_disconnected_river_cannot_advance_land_day(self):
        config = build_creation_world_config(1)
        submission = example_creation_result(config)
        for command in submission['commands']:
            if command.get('piece_id') == 'water-3':
                command['cell'] = 16
        with self.assertRaises(ValueError):
            replay_creation_world(config, submission)

    def test_forest_can_block_a_meadow_route(self):
        config = build_creation_world_config(3)
        submission = example_creation_result(config)
        for command in submission['commands']:
            if command.get('piece_id') == 'land-5': command['cell'] = 12
            if command.get('piece_id') == 'land-6': command['cell'] = 17
        with self.assertRaises(ValueError):
            replay_creation_world(config, submission)

    def test_fish_needs_connected_water_and_bird_needs_forest(self):
        config = build_creation_world_config(2)
        for piece, bad_cell in (('fish-1', 3), ('bird-1', 8)):
            submission = example_creation_result(config)
            for command in submission['commands']:
                if command.get('piece_id') == piece: command['cell'] = bad_cell
            with self.subTest(piece=piece), self.assertRaises(ValueError):
                replay_creation_world(config, submission)

    def test_day_order_future_pieces_and_claimed_score_are_rejected(self):
        config = build_creation_world_config(3)
        for submission in (
            {'commands': [{'op': 'advance', 'day': 2}], 'elapsed_seconds': 0},
            {'commands': [{'op': 'place', 'piece_id': 'fish-1', 'cell': 5}], 'elapsed_seconds': 0},
            {**example_creation_result(config), 'completed': True},
            {'commands': [], 'elapsed_seconds': True},
            {'commands': [{'op': 'place', 'piece_id': 'light-1', 'cell': True}], 'elapsed_seconds': 0},
        ):
            with self.subTest(submission=submission), self.assertRaises(ValueError):
                replay_creation_world(config, submission)

    def test_rearranging_ground_updates_habitats_and_is_replayed(self):
        config = build_creation_world_config(3)
        submission = example_creation_result(config)
        submission['commands'].extend([
            {'op': 'remove', 'piece_id': 'water-2'},
            {'op': 'place', 'piece_id': 'water-2', 'cell': 7},
        ])
        outcome = replay_creation_world(config, submission)
        self.assertFalse(outcome['completed'])
        self.assertFalse(outcome['habitats']['river_connected'])
        self.assertFalse(outcome['habitats']['fish_safe'])


if os.environ.get('DJANGO_SETTINGS_MODULE'):
    import uuid
    from django.test import TestCase
    from django.utils import timezone
    from rest_framework.test import APIClient
    from apps.accounts.models import KidProfile, User
    from apps.progress.services import build_profile_level
    from .models import Game, GameAttempt, GameLevel, KidGameProgress
    from .services import evaluate_level

    class CreationWorldApiTests(TestCase):
        def setUp(self):
            self.parent=User.objects.create_user(email='creation-api@example.com',password='Creation-test-123!',email_verified_at=timezone.now())
            self.profile=KidProfile.objects.create(parent=self.parent,display_name='Ada',avatar_key=KidProfile.AvatarKey.DOVE)
            self.client=APIClient();self.client.force_authenticate(self.parent)
            self.level=GameLevel.objects.get(game__slug='creation-order',level_number=1)
            # Only this legacy fixture is republished to cover its preserved
            # command protocol. The actual catalogue retirement has its own tests.
            Game.objects.filter(pk=self.level.game_id).update(is_published=True)

        def submit(self,result=None,*,number=1,operation=None,profile=None):
            level=GameLevel.objects.get(game=self.level.game,level_number=number)
            return self.client.post('/api/games/creation-order/submit/',{
                'profile_id':str(profile or self.profile.pk),'level_number':number,
                'operation_id':str(operation or uuid.uuid4()),
                'result':result if result is not None else example_creation_result(level.config),
            },format='json')

        def test_all_seeded_rounds_validate_and_server_evaluate_valid_commands(self):
            for level in GameLevel.objects.filter(game=self.level.game):
                level.full_clean()
                self.assertEqual(level.config['mode'],'living_world')
                evaluation=evaluate_level(level,example_creation_result(level.config))
                self.assertTrue(evaluation.completed)
                self.assertEqual(evaluation.score,100)
                self.assertEqual(evaluation.stars,3)

        def test_http_completion_retry_conflict_and_50_plus_stars_reward(self):
            operation=uuid.uuid4();result=example_creation_result(self.level.config)
            first=self.submit(result,operation=operation);retry=self.submit(result,operation=operation)
            conflict=self.submit({**result,'elapsed_seconds':121},operation=operation)
            self.assertEqual(first.status_code,201);self.assertEqual(retry.status_code,200);self.assertEqual(conflict.status_code,409)
            self.assertTrue(first.data['completed']);self.assertEqual(first.data['stars'],3)
            self.assertEqual(first.data['attempt_id'],retry.data['attempt_id'])
            self.assertEqual(build_profile_level(self.profile)['xp'],110)
            progress=KidGameProgress.objects.get(profile=self.profile,game=self.level.game)
            self.assertEqual(progress.level_progress['1']['completion_xp'],50)
            self.assertEqual(progress.level_progress['1']['attempts'],1)
            self.assertEqual(GameAttempt.objects.count(),1)

        def test_locked_second_round_and_first_completion_unlock(self):
            self.assertEqual(self.submit(number=2).status_code,400)
            self.assertEqual(GameAttempt.objects.count(),0)
            self.assertEqual(self.submit(number=1).status_code,201)
            self.assertEqual(self.submit(number=2).status_code,201)
            self.assertEqual(KidGameProgress.objects.get(profile=self.profile,game=self.level.game).highest_completed_level,2)

        def test_empty_world_is_incomplete_without_reward(self):
            response=self.submit({'commands':[],'elapsed_seconds':0})
            self.assertEqual(response.status_code,201);self.assertFalse(response.data['completed']);self.assertEqual(response.data['stars'],0)
            self.assertEqual(build_profile_level(self.profile)['xp'],0)

        def test_malformed_unknown_and_client_reward_claims_are_rejected(self):
            invalid=[{'commands':[{'op':'place','piece_id':'unicorn','cell':0}],'elapsed_seconds':0},
                     {'commands':[{'op':'advance','day':True}],'elapsed_seconds':0},
                     {'commands':[{'op':'place','piece_id':'light-1','cell':0,'score':100}],'elapsed_seconds':0},
                     {**example_creation_result(self.level.config),'completed':True}]
            for result in invalid:self.assertEqual(self.submit(result).status_code,400)
            self.assertEqual(GameAttempt.objects.count(),0)

        def test_foreign_profile_is_not_disclosed(self):
            other=User.objects.create_user(email='foreign-creation@example.com',password='Foreign-test-123!')
            profile=KidProfile.objects.create(parent=other,display_name='Other',avatar_key=KidProfile.AvatarKey.DOVE)
            self.assertEqual(self.submit(profile=profile.pk).status_code,404)
            self.assertEqual(GameAttempt.objects.count(),0)


if __name__ == '__main__': unittest.main()
