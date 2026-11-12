import copy
import os
import unittest
from .wise_builders import build_wise_builders_config, example_builders_result, replay_wise_builders


class WiseBuildersTests(unittest.TestCase):
    def test_three_storm_rounds_compare_rock_and_sand(self):
        for number in (1, 2, 3):
            config=build_wise_builders_config(number)
            replay=replay_wise_builders(config,example_builders_result(config))
            self.assertTrue(replay['completed'])
            self.assertEqual(replay['stood'], {'house-a':True,'house-b':False})
            self.assertEqual(replay['score'],100)

    def test_children_can_build_on_either_side(self):
        config=build_wise_builders_config(2)
        result=example_builders_result(config)
        for command in result['commands']:
            if command['op']=='foundation': command['material']='sand' if command['material']=='rock' else 'rock'
        replay=replay_wise_builders(config,result)
        self.assertTrue(replay['completed'])
        self.assertEqual(replay['stood'],{'house-a':False,'house-b':True})

    def test_roof_needs_four_walls_and_foundation(self):
        config=build_wise_builders_config(1)
        for commands in ([{'op':'place','house_id':'house-a','part':'back-wall'}],
                         [{'op':'foundation','house_id':'house-a','material':'rock'},
                          {'op':'place','house_id':'house-a','part':'roof'}], [{'op':'storm'}]):
            with self.assertRaises(ValueError): replay_wise_builders(config,{'commands':commands,'elapsed_seconds':0})

    def test_equal_foundations_do_not_complete_the_comparison(self):
        config=build_wise_builders_config(1)
        submission=example_builders_result(config)
        for c in submission['commands']:
            if c['op']=='foundation': c['material']='rock'
        self.assertFalse(replay_wise_builders(config,submission)['completed'])

    def test_collapsed_sand_house_requires_rebuilding(self):
        config=build_wise_builders_config(3)
        result=example_builders_result(config)
        result['commands'].append({'op':'storm'})
        with self.assertRaises(ValueError): replay_wise_builders(config,result)

    def test_extra_claims_unknown_parts_boolean_times_rejected(self):
        config=build_wise_builders_config(1)
        submissions=[{**example_builders_result(config),'score':100},
                     {'commands':[],'elapsed_seconds':True},
                     {'commands':[{'op':'foundation','house_id':[],'material':'rock'}],'elapsed_seconds':0},
                     {'commands':[{'op':'foundation','house_id':'house-a','material':'water'}],'elapsed_seconds':0}]
        for result in submissions:
            with self.assertRaises(ValueError): replay_wise_builders(config,result)


if os.environ.get('DJANGO_SETTINGS_MODULE'):
    import uuid
    from django.test import TestCase
    from django.utils import timezone
    from rest_framework.test import APIClient
    from apps.accounts.models import KidProfile,User
    from apps.progress.services import build_profile_level
    from .models import Game,GameAttempt,GameLevel,KidGameProgress
    from .services import evaluate_level

    class WiseBuildersApiTests(TestCase):
        def setUp(self):
            self.parent=User.objects.create_user(email='builders-api@example.com',password='Builders-test-123!',email_verified_at=timezone.now())
            self.profile=KidProfile.objects.create(parent=self.parent,display_name='Ada',avatar_key=KidProfile.AvatarKey.DOVE)
            self.client=APIClient();self.client.force_authenticate(self.parent)
            self.level=GameLevel.objects.get(game__slug='wise-and-foolish-builders',level_number=1)
            # This retired quest is published only in the legacy API fixture.
            Game.objects.filter(pk=self.level.game_id).update(is_published=True)

        def submit(self,result=None,*,number=1,operation=None,profile=None):
            level=GameLevel.objects.get(game=self.level.game,level_number=number)
            return self.client.post('/api/games/wise-and-foolish-builders/submit/',{
                'profile_id':str(profile or self.profile.pk),'level_number':number,'operation_id':str(operation or uuid.uuid4()),
                'result':result if result is not None else example_builders_result(level.config),
            },format='json')

        def test_seeded_three_storm_rounds_validate_and_evaluate(self):
            for level in GameLevel.objects.filter(game=self.level.game):
                level.full_clean();self.assertEqual(level.config['mode'],'wise_builders')
                evaluation=evaluate_level(level,example_builders_result(level.config))
                self.assertTrue(evaluation.completed);self.assertEqual(evaluation.stars,3)
                self.assertEqual(evaluation.details['stood'],{'house-a':True,'house-b':False})

        def test_http_completion_retry_conflict_and_50_plus_stars_reward(self):
            operation=uuid.uuid4();result=example_builders_result(self.level.config)
            first=self.submit(result,operation=operation);retry=self.submit(result,operation=operation)
            conflict=self.submit({**result,'elapsed_seconds':91},operation=operation)
            self.assertEqual(first.status_code,201);self.assertEqual(retry.status_code,200);self.assertEqual(conflict.status_code,409)
            self.assertTrue(first.data['completed']);self.assertEqual(first.data['stars'],3)
            self.assertEqual(first.data['attempt_id'],retry.data['attempt_id']);self.assertEqual(GameAttempt.objects.count(),1)
            self.assertEqual(build_profile_level(self.profile)['xp'],110)
            progress=KidGameProgress.objects.get(profile=self.profile,game=self.level.game)
            self.assertEqual(progress.level_progress['1']['completion_xp'],50);self.assertEqual(progress.level_progress['1']['attempts'],1)

        def test_locked_second_round_unlocks_after_first(self):
            self.assertEqual(self.submit(number=2).status_code,400);self.assertEqual(GameAttempt.objects.count(),0)
            self.assertEqual(self.submit(number=1).status_code,201);self.assertEqual(self.submit(number=2).status_code,201)
            self.assertEqual(KidGameProgress.objects.get(profile=self.profile,game=self.level.game).highest_completed_level,2)

        def test_unbuilt_houses_are_incomplete_without_reward(self):
            response=self.submit({'commands':[],'elapsed_seconds':0})
            self.assertEqual(response.status_code,201);self.assertFalse(response.data['completed']);self.assertEqual(response.data['stars'],0)
            self.assertEqual(build_profile_level(self.profile)['xp'],0)

        def test_unknown_malformed_and_client_claims_are_rejected(self):
            invalid=[{'commands':[{'op':'foundation','house_id':'unknown','material':'rock'}],'elapsed_seconds':0},
                     {'commands':[{'op':'storm','stood':True}],'elapsed_seconds':0},
                     {'commands':[],'elapsed_seconds':False},{**example_builders_result(self.level.config),'stars':3}]
            for result in invalid:self.assertEqual(self.submit(result).status_code,400)
            self.assertEqual(GameAttempt.objects.count(),0)

        def test_foreign_profile_cannot_submit(self):
            other=User.objects.create_user(email='foreign-builders@example.com',password='Foreign-test-123!')
            profile=KidProfile.objects.create(parent=other,display_name='Other',avatar_key=KidProfile.AvatarKey.DOVE)
            self.assertEqual(self.submit(profile=profile.pk).status_code,404);self.assertEqual(GameAttempt.objects.count(),0)


if __name__=='__main__':unittest.main()
