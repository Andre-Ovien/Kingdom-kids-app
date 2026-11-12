from django.core.exceptions import ValidationError as DjangoValidationError
from django.db import IntegrityError, transaction
from django.db.models import Count, Prefetch
from django.utils import timezone
from rest_framework import status, viewsets
from rest_framework.decorators import action
from rest_framework.exceptions import NotFound, ValidationError
from rest_framework.response import Response
from rest_framework.throttling import ScopedRateThrottle
from rest_framework.permissions import IsAuthenticated
from apps.billing.permissions import HasPaidContentAccess

from apps.accounts.models import KidProfile
from apps.progress.progression import XP_PER_COMPLETED_LEVEL, earned_completion_xp
from apps.progress.services import build_profile_level, milestone_reward_payload

from .models import Game, GameAttempt, GameLevel, KidGameProgress
from .serializers import (
    GameDetailSerializer,
    GameListSerializer,
    GameSubmissionSerializer,
    progress_payload,
)
from .services import GameResultError, evaluate_level


class GameViewSet(viewsets.ReadOnlyModelViewSet):
    """Profile-scoped catalogue, level content, and authoritative scoring."""

    permission_classes = (IsAuthenticated, HasPaidContentAccess)

    lookup_field = 'slug'
    lookup_value_regex = r'[-a-zA-Z0-9_]+'

    def get_throttles(self):
        throttles = list(super().get_throttles())
        if self.action == 'submit':
            self.throttle_scope = 'game_submit'
            throttles.append(ScopedRateThrottle())
        return throttles

    def get_queryset(self):
        queryset = (
            Game.objects.filter(is_published=True)
            .annotate(total_levels=Count('levels'))
            .order_by('sort_order', 'title')
        )
        if self.action == 'retrieve':
            queryset = queryset.prefetch_related(
                Prefetch('levels', queryset=GameLevel.objects.order_by('level_number')),
            )
        return queryset

    def get_serializer_class(self):
        if self.action == 'retrieve':
            return GameDetailSerializer
        return GameListSerializer

    def list(self, request, *args, **kwargs):
        profile = self._owned_profile(request.query_params.get('profile_id'))
        # Serialize the same evaluated catalogue whose IDs scope progress.
        # Reusing the annotated queryset in an IN subquery would repeat its
        # game/level aggregate and pull display ordering into a map lookup.
        queryset = list(self.filter_queryset(self.get_queryset()))
        progress_map = {
            item.game_id: item
            for item in KidGameProgress.objects.filter(
                profile=profile,
                game_id__in=[game.pk for game in queryset],
            ).order_by()
        }
        serializer = self.get_serializer(
            queryset,
            many=True,
            context={
                **self.get_serializer_context(),
                'progress_map': progress_map,
                'profile_id': profile.pk,
            },
        )
        return Response(serializer.data)

    def retrieve(self, request, *args, **kwargs):
        profile = self._owned_profile(request.query_params.get('profile_id'))
        game = self.get_object()
        progress = KidGameProgress.objects.filter(
            profile=profile,
            game=game,
        ).first()
        serializer = self.get_serializer(
            game,
            context={
                **self.get_serializer_context(),
                'progress_map': {game.pk: progress} if progress else {},
                'profile_id': profile.pk,
            },
        )
        return Response(serializer.data)

    @action(detail=True, methods=('post',), url_path='submit')
    def submit(self, request, *args, **kwargs):
        game = self.get_object()
        input_serializer = GameSubmissionSerializer(data=request.data)
        input_serializer.is_valid(raise_exception=True)
        data = input_serializer.validated_data
        profile = self._owned_profile(data['profile_id'])
        try:
            level = game.levels.get(level_number=data['level_number'])
        except GameLevel.DoesNotExist as exc:
            raise NotFound('That level does not exist for this game.') from exc

        existing = GameAttempt.objects.filter(
            profile=profile,
            operation_id=data['operation_id'],
        ).select_related('game', 'level').first()
        if existing:
            return self._replay(existing, game, level, data['result'])

        try:
            evaluation = evaluate_level(level, data['result'])
        except GameResultError as exc:
            raise ValidationError({'result': [str(exc)]}) from exc

        try:
            with transaction.atomic():
                # Serialize a child's overall XP across different quests as
                # well as the per-quest progress row below.
                profile = KidProfile.objects.select_for_update().filter(
                    pk=profile.pk,
                    parent=request.user,
                ).first()
                if profile is None:
                    raise NotFound('Kid profile not found.')
                existing = GameAttempt.objects.filter(
                    profile=profile,
                    operation_id=data['operation_id'],
                ).select_related('game', 'level').first()
                if existing is not None:
                    return self._replay(existing, game, level, data['result'])

                previous_level = build_profile_level(profile)
                progress, _ = KidGameProgress.objects.get_or_create(
                    profile=profile,
                    game=game,
                )
                progress = KidGameProgress.objects.select_for_update().get(pk=progress.pk)
                if level.level_number > progress.highest_completed_level + 1:
                    raise ValidationError(
                        {'level_number': ['Complete the previous level first.']}
                    )

                self._apply_progress(progress, level, evaluation)
                current_level = build_profile_level(profile)
                evaluation_details = dict(evaluation.details)
                # This private receipt belongs to the server, not an engine
                # answer. Store it with the immutable attempt so a lost response
                # can be retried without changing the milestone it earned.
                evaluation_details.pop('_level_milestone', None)
                if current_level['number'] > previous_level['number']:
                    evaluation_details['_level_milestone'] = {
                        'previous_level': previous_level['number'],
                        'level': current_level,
                    }
                attempt = GameAttempt.objects.create(
                    profile=profile,
                    game=game,
                    level=level,
                    operation_id=data['operation_id'],
                    submitted_result=data['result'],
                    completed=evaluation.completed,
                    score=evaluation.score,
                    stars=evaluation.stars,
                    feedback=evaluation.feedback,
                    evaluation=evaluation_details,
                )
        except IntegrityError:
            # A concurrent request with the same operation can win the unique
            # constraint. Its committed response is the idempotent result.
            existing = GameAttempt.objects.filter(
                profile=profile,
                operation_id=data['operation_id'],
            ).select_related('game', 'level').first()
            if existing:
                return self._replay(existing, game, level, data['result'])
            raise

        return Response(
            self._attempt_payload(attempt, progress, replay=False),
            status=status.HTTP_201_CREATED,
        )

    def _owned_profile(self, raw_profile_id):
        if raw_profile_id in (None, ''):
            raise ValidationError({'profile_id': ['This field is required.']})
        try:
            # UUIDField raises Django's validation error for malformed values
            # before touching the database; translate it to an API 400.
            profile = KidProfile.objects.filter(
                pk=raw_profile_id,
                parent=self.request.user,
            ).first()
        except (DjangoValidationError, TypeError, ValueError) as exc:
            raise ValidationError(
                {'profile_id': ['Must be a valid UUID.']}
            ) from exc
        if profile is None:
            # A 404 does not disclose whether another parent's profile exists.
            raise NotFound('Kid profile not found.')
        return profile

    def _replay(self, attempt, game, level, submitted_result):
        if (
            attempt.game_id != game.pk
            or attempt.level_id != level.pk
            or attempt.submitted_result != submitted_result
        ):
            return Response(
                {'detail': 'operation_id was already used for a different submission.'},
                status=status.HTTP_409_CONFLICT,
            )
        progress = KidGameProgress.objects.get(
            profile=attempt.profile,
            game=attempt.game,
        )
        return Response(self._attempt_payload(attempt, progress, replay=True))

    @staticmethod
    def _apply_progress(progress, level, evaluation):
        level_progress = dict(progress.level_progress)
        key = str(level.level_number)
        previous = level_progress.get(key, {})
        completion_xp = earned_completion_xp(previous)
        if previous.get('completed') is not True and evaluation.completed:
            completion_xp = XP_PER_COMPLETED_LEVEL
        level_progress[key] = {
            'best_score': max(int(previous.get('best_score', 0)), evaluation.score),
            'best_stars': max(int(previous.get('best_stars', 0)), evaluation.stars),
            'completed': bool(previous.get('completed')) or evaluation.completed,
            # Keep old awards on a replay or better star result. Only the
            # first new completion uses the current reward rate.
            'completion_xp': completion_xp,
            'attempts': int(previous.get('attempts', 0)) + 1,
        }
        highest = 0
        while level_progress.get(str(highest + 1), {}).get('completed'):
            highest += 1
        progress.level_progress = level_progress
        progress.highest_completed_level = highest
        progress.total_stars = sum(
            int(item.get('best_stars', 0))
            for item in level_progress.values()
            if isinstance(item, dict)
        )
        progress.last_played_at = timezone.now()
        progress.save(
            update_fields=(
                'level_progress',
                'highest_completed_level',
                'total_stars',
                'last_played_at',
                'updated_at',
            )
        )

    @staticmethod
    def _attempt_payload(attempt, progress, *, replay):
        total_levels = attempt.game.levels.count()
        return {
            'attempt_id': attempt.pk,
            'operation_id': attempt.operation_id,
            'game_slug': attempt.game.slug,
            'profile_id': attempt.profile_id,
            'level_number': attempt.level.level_number,
            'completed': attempt.completed,
            'score': attempt.score,
            'max_score': attempt.level.max_score,
            'stars': attempt.stars,
            'feedback': attempt.feedback,
            'progress': progress_payload(progress, total_levels=total_levels),
            'idempotent_replay': replay,
            'level_milestone': (
                milestone_reward_payload(attempt.evaluation.get('_level_milestone'))
                if isinstance(attempt.evaluation, dict)
                else None
            ),
        }
