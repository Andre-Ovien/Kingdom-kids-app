from django.utils import timezone
from rest_framework.test import APITestCase
from rest_framework_simplejwt.tokens import RefreshToken

from apps.accounts.models import User

from .models import Game


class GameProfileQueryBoundaryTests(APITestCase):
    def setUp(self):
        parent = User.objects.create_user(
            email='game-query-reader@example.com',
            password='A-strong-password-123!',
            email_verified_at=timezone.now(),
        )
        token = RefreshToken.for_user(parent).access_token
        self.client.credentials(HTTP_AUTHORIZATION=f'Bearer {token}')

    def test_list_and_detail_reject_invalid_profile_uuid_without_server_errors(self):
        game = Game.objects.filter(is_published=True).first()
        for path in ('/api/games/', f'/api/games/{game.slug}/'):
            for profile_id in ('not-a-uuid', '123', 'null'):
                with self.subTest(path=path, profile_id=profile_id):
                    response = self.client.get(path, {'profile_id': profile_id})
                    self.assertEqual(response.status_code, 400)
                    self.assertIn('profile_id', response.data)


class QuizAnswerTypeBoundaryTests(APITestCase):
    def setUp(self):
        from django.core.cache import cache
        from apps.accounts.models import KidProfile
        from .models import GameLevel
        cache.clear()
        self.addCleanup(cache.clear)
        parent = User.objects.create_user(
            email='quiz-answer-boundary@example.test', password='Strong-test-password-123!',
            email_verified_at=timezone.now(),
        )
        self.profile = KidProfile.objects.create(parent=parent, display_name='Ada', avatar_key='kai')
        self.game = Game.objects.filter(is_published=True, game_type='quiz').first()
        self.level = GameLevel.objects.get(game=self.game, level_number=1)
        self.question = self.level.config['questions'][0]
        self.client.force_authenticate(parent)
        self.client.raise_request_exception = False

    def test_nontext_question_and_option_ids_are_400_not_500_and_write_nothing(self):
        import uuid
        from .models import GameAttempt, KidGameProgress
        for bad in ([], {}, None, True, 17):
            for field in ('question_id', 'option_id'):
                with self.subTest(field=field, value=bad):
                    answer = {'question_id': self.question['id'],
                              'option_id': self.question['options'][0]['id']}
                    answer[field] = bad
                    response = self.client.post(
                        f'/api/games/{self.game.slug}/submit/',
                        {'profile_id': str(self.profile.pk), 'level_number': 1,
                         'operation_id': str(uuid.uuid4()), 'result': {'answers': [answer]}},
                        format='json',
                    )
                    self.assertEqual(response.status_code, 400)
        self.assertFalse(GameAttempt.objects.filter(profile=self.profile).exists())
        self.assertFalse(KidGameProgress.objects.filter(profile=self.profile).exists())
