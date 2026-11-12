from django.db import IntegrityError, transaction
from django.shortcuts import get_object_or_404
from rest_framework import serializers, status
from rest_framework.response import Response
from rest_framework.throttling import ScopedRateThrottle, UserRateThrottle
from rest_framework.views import APIView
from rest_framework.permissions import IsAuthenticated
from apps.billing.permissions import HasPaidContentAccess

from apps.accounts.models import KidProfile
from apps.stories.catalogue_policy import UNAVAILABLE_STORY_SLUGS
from apps.stories.models import Story

from .models import KidActivityEvent
from .serializers import (
    KidActivityEventCreateSerializer,
    ProfileSummaryQuerySerializer,
    StreakPresentationClaimSerializer,
)
from .services import (
    XP_PER_COMPLETED_STORY,
    StreakTimezoneChangeTooSoon,
    activity_reward_payload,
    build_kid_profile_summary,
    build_profile_level,
    build_reward_receipt,
    claim_streak_presentation,
)


class KidActivityEventCreateView(APIView):
    """Append story activity to one owned child's immutable event ledger."""

    permission_classes = (IsAuthenticated, HasPaidContentAccess)

    throttle_classes = (ScopedRateThrottle, UserRateThrottle)
    throttle_scope = 'activity_write'

    def post(self, request, profile_id):
        profile = get_object_or_404(
            KidProfile,
            pk=profile_id,
            parent=request.user,
        )
        input_serializer = KidActivityEventCreateSerializer(data=request.data)
        input_serializer.is_valid(raise_exception=True)
        data = input_serializer.validated_data

        existing = KidActivityEvent.objects.filter(
            profile=profile,
            operation_id=data['operation_id'],
        ).first()
        if existing is not None:
            return self._replay(existing, data)

        story = Story.objects.filter(
            pk=data['story_id'],
            is_published=True,
        ).exclude(slug__in=UNAVAILABLE_STORY_SLUGS).first()
        if story is None:
            # Unavailable catalogue items are intentionally indistinguishable
            # from missing stories at this public write boundary.
            return Response(
                {'detail': 'Story not found.'},
                status=status.HTTP_404_NOT_FOUND,
            )

        try:
            with transaction.atomic():
                # Story, visit, and game rewards share this lock so simultaneous
                # activities cannot both claim the same level transition.
                profile = get_object_or_404(
                    KidProfile.objects.select_for_update(),
                    pk=profile.pk,
                    parent=request.user,
                )
                existing = KidActivityEvent.objects.filter(
                    profile=profile,
                    operation_id=data['operation_id'],
                ).first()
                if existing is not None:
                    return self._replay(existing, data)
                previous_level = build_profile_level(profile)
                xp_awarded = 0
                if (
                    data['event_type'] == KidActivityEvent.EventType.STORY_COMPLETED
                    and not KidActivityEvent.objects.filter(
                        profile=profile,
                        story=story,
                        event_type=KidActivityEvent.EventType.STORY_COMPLETED,
                    ).exists()
                ):
                    xp_awarded = XP_PER_COMPLETED_STORY
                event = KidActivityEvent.objects.create(
                    profile=profile,
                    operation_id=data['operation_id'],
                    event_type=data['event_type'],
                    story=story,
                    reward_receipt=build_reward_receipt(
                        previous_level,
                        xp_awarded=xp_awarded,
                    ),
                )
        except IntegrityError:
            # A concurrent request with this operation can win the unique
            # constraint. Once it commits, replay its stable result.
            existing = KidActivityEvent.objects.filter(
                profile=profile,
                operation_id=data['operation_id'],
            ).first()
            if existing is not None:
                return self._replay(existing, data)
            raise

        return Response(
            self._event_payload(event, replay=False),
            status=status.HTTP_201_CREATED,
        )

    def _replay(self, event, submitted_data):
        if (
            event.event_type != submitted_data['event_type']
            or event.story_id != submitted_data['story_id']
        ):
            return Response(
                {
                    'detail': (
                        'operation_id was already used for a different '
                        'activity event.'
                    )
                },
                status=status.HTTP_409_CONFLICT,
            )
        return Response(self._event_payload(event, replay=True))

    @staticmethod
    def _event_payload(event, *, replay):
        return {
            'event_id': str(event.pk),
            'operation_id': str(event.operation_id),
            'profile_id': str(event.profile_id),
            'event_type': event.event_type,
            'story_id': str(event.story_id),
            'recorded_at': serializers.DateTimeField().to_representation(
                event.created_at
            ),
            'idempotent_replay': replay,
            **activity_reward_payload(event.reward_receipt),
        }


class KidProfileSummaryView(APIView):
    """Read one owned child's learning progress summary."""

    throttle_classes = (ScopedRateThrottle, UserRateThrottle)
    throttle_scope = 'summary'

    def get(self, request, profile_id):
        query = ProfileSummaryQuerySerializer(data=request.query_params)
        query.is_valid(raise_exception=True)
        profile = get_object_or_404(
            KidProfile,
            pk=profile_id,
            parent=request.user,
        )
        return Response(
            build_kid_profile_summary(
                profile,
                timezone_offset_minutes=query.validated_data[
                    'timezone_offset_minutes'
                ],
            )
        )


class StreakPresentationClaimView(APIView):
    """Claim the one streak presentation currently due for an owned child."""

    permission_classes = (IsAuthenticated, HasPaidContentAccess)

    throttle_classes = (ScopedRateThrottle, UserRateThrottle)
    throttle_scope = 'streak_claim'

    def post(self, request, profile_id):
        input_serializer = StreakPresentationClaimSerializer(data=request.data)
        input_serializer.is_valid(raise_exception=True)
        profile = get_object_or_404(
            KidProfile,
            pk=profile_id,
            parent=request.user,
        )
        try:
            claim = claim_streak_presentation(
                profile,
                timezone_offset_minutes=input_serializer.validated_data[
                    'timezone_offset_minutes'
                ],
            )
        except StreakTimezoneChangeTooSoon as exc:
            return Response(
                {
                    'code': 'streak_timezone_change_too_soon',
                    'detail': (
                        'The streak timezone was recently used. Try again '
                        'after the cooldown.'
                    ),
                    'retry_after': exc.retry_after,
                },
                status=status.HTTP_409_CONFLICT,
                headers={'Retry-After': str(exc.retry_after)},
            )
        return Response(claim)
