from django.db import IntegrityError, transaction
from django.shortcuts import get_object_or_404
from rest_framework import serializers, status
from rest_framework.response import Response
from rest_framework.views import APIView

from apps.accounts.models import KidProfile
from apps.stories.models import Story

from .models import KidActivityEvent
from .serializers import (
    KidActivityEventCreateSerializer,
    ProfileSummaryQuerySerializer,
)
from .services import build_kid_profile_summary


class KidActivityEventCreateView(APIView):
    """Append story activity to one owned child's immutable event ledger."""

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
        ).first()
        if story is None:
            # Unpublished catalogue items are intentionally indistinguishable
            # from missing stories at this public write boundary.
            return Response(
                {'detail': 'Story not found.'},
                status=status.HTTP_404_NOT_FOUND,
            )

        try:
            with transaction.atomic():
                event = KidActivityEvent.objects.create(
                    profile=profile,
                    operation_id=data['operation_id'],
                    event_type=data['event_type'],
                    story=story,
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
        }


class KidProfileSummaryView(APIView):
    """Read one owned child's game-derived profile summary."""

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
