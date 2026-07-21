from django.db.models import Prefetch, Q
from rest_framework import viewsets

from .models import Story, StoryNarration
from .serializers import StoryDetailSerializer, StoryListSerializer


class StoryViewSet(viewsets.ReadOnlyModelViewSet):
    lookup_field = 'slug'
    lookup_value_regex = r'[-a-zA-Z0-9_]+'

    def get_queryset(self):
        available_narrations = StoryNarration.objects.filter(
            narrator__is_active=True,
        ).exclude(
            status=StoryNarration.Status.UNAVAILABLE,
        ).select_related('narrator')
        queryset = Story.objects.filter(is_published=True).prefetch_related(
            Prefetch('narrations', queryset=available_narrations),
        )
        search = self.request.query_params.get('search', '').strip()
        category = self.request.query_params.get('category', '').strip()
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
