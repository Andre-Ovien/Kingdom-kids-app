from django.db.models import Prefetch, Q
from rest_framework import viewsets
from rest_framework.exceptions import ValidationError
from rest_framework.permissions import IsAuthenticated
from apps.billing.permissions import HasPaidContentAccess

from .catalogue_policy import UNAVAILABLE_STORY_SLUGS
from .models import Story, StoryNarration
from .serializers import StoryDetailSerializer, StoryListSerializer


class StoryViewSet(viewsets.ReadOnlyModelViewSet):
    permission_classes = (IsAuthenticated, HasPaidContentAccess)
    lookup_field = 'slug'
    lookup_value_regex = r'[-a-zA-Z0-9_]+'

    def get_queryset(self):
        queryset = Story.objects.filter(is_published=True).exclude(
            slug__in=UNAVAILABLE_STORY_SLUGS,
        )
        if self.action == 'retrieve':
            available_narrations = StoryNarration.objects.filter(
                narrator__is_active=True,
            ).exclude(
                status=StoryNarration.Status.UNAVAILABLE,
            ).select_related('narrator')
            # Reverse prefetch binds each narration back to this exact parent
            # story; joining story again duplicates its potentially large body.
            queryset = queryset.prefetch_related(
                Prefetch('narrations', queryset=available_narrations),
            )
        else:
            # Covers and summaries do not need full story text or audio timings.
            queryset = queryset.defer('body')
        search = self.request.query_params.get('search', '').strip()
        category = self.request.query_params.get('category', '').strip()
        if len(search) > 100:
            raise ValidationError({'search': ['Must be 100 characters or fewer.']})
        if len(category) > 80:
            raise ValidationError({'category': ['Must be 80 characters or fewer.']})
        if search:
            queryset = queryset.filter(
                Q(title__icontains=search)
                | Q(author__icontains=search)
                | Q(category__icontains=search)
                | Q(summary__icontains=search)
            )
        if category:
            queryset = queryset.filter(category__iexact=category)
        return queryset

    def get_serializer_class(self):
        if self.action == 'retrieve':
            return StoryDetailSerializer
        return StoryListSerializer
