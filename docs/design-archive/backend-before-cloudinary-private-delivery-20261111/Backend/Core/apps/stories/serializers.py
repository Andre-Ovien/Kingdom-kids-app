from rest_framework import serializers

from .models import Story, StoryNarration, is_owned_https_media_url
from .narration import validated_narration_segments, validated_narration_words


class StoryNarrationSerializer(serializers.ModelSerializer):
    avatar_key = serializers.CharField(source='narrator.avatar_key')
    voice_key = serializers.CharField(source='narrator.voice_key')
    character_name = serializers.CharField(source='narrator.display_name')
    voice_description = serializers.CharField(source='narrator.voice_description')
    locale = serializers.CharField(source='narrator.locale')
    speech_rate = serializers.FloatField(source='narrator.speech_rate')
    pitch = serializers.FloatField(source='narrator.pitch')
    sample_url = serializers.SerializerMethodField()
    audio_url = serializers.SerializerMethodField()
    audio_available = serializers.SerializerMethodField()
    segments = serializers.SerializerMethodField()
    words = serializers.SerializerMethodField()

    class Meta:
        model = StoryNarration
        fields = (
            'avatar_key',
            'voice_key',
            'character_name',
            'voice_description',
            'locale',
            'speech_rate',
            'pitch',
            'sample_url',
            'status',
            'audio_available',
            'audio_url',
            'duration_seconds',
            'segments',
            'words',
        )

    def get_sample_url(self, narration: StoryNarration) -> str | None:
        url = narration.narrator.available_sample_url
        if url is None:
            return None

        request = self.context.get('request')
        return request.build_absolute_uri(url) if request else url

    def _media_state(self, narration: StoryNarration) -> dict:
        # A ListSerializer reuses its child for the request's narrations. Resolve
        # storage/host policy once per row, without caching on the model or
        # across requests (a deleted/unmounted track must disappear next time).
        cache = self.__dict__.setdefault('_resolved_media', {})
        if narration.pk not in cache:
            matches_text = False
            url = None
            if narration.status == StoryNarration.Status.READY:
                matches_text = narration.matches_story_text
                if not narration.text_sha256 or matches_text:
                    url = narration.available_audio_url
            cache[narration.pk] = {
                'available': bool(url),
                'url': url,
                'matches_text': matches_text,
            }
        return cache[narration.pk]

    def get_audio_available(self, narration: StoryNarration) -> bool:
        return self._media_state(narration)['available']

    def get_audio_url(self, narration: StoryNarration) -> str | None:
        url = self._media_state(narration)['url']
        if url is None:
            return None
        request = self.context.get('request')
        return request.build_absolute_uri(url) if request else url

    def get_segments(self, narration: StoryNarration):
        media = self._media_state(narration)
        if not media['available'] or not media['matches_text']:
            return []
        return validated_narration_segments(
            narration.segments,
            narration.story.body,
            narration.duration_seconds,
        )

    def get_words(self, narration: StoryNarration):
        media = self._media_state(narration)
        if not media['available'] or not media['matches_text']:
            return []
        return validated_narration_words(
            narration.words,
            narration.story.body,
            narration.duration_seconds,
            narration.segments,
        )


class StoryListSerializer(serializers.ModelSerializer):
    rating = serializers.FloatField(read_only=True)
    estimated_read_seconds = serializers.SerializerMethodField()
    cover_image_url = serializers.SerializerMethodField()

    class Meta:
        model = Story
        fields = (
            'id',
            'slug',
            'title',
            'author',
            'category',
            'summary',
            'cover_asset_key',
            'cover_image_url',
            'cover_focus_x',
            'cover_focus_y',
            'rating',
            'review_count',
            'estimated_read_seconds',
            'is_featured',
        )

    def get_estimated_read_seconds(self, story: Story) -> int:
        return story.reading_time_minutes * 60

    def get_cover_image_url(self, story: Story) -> str | None:
        if not is_owned_https_media_url(story.cover_image_url):
            return None
        return story.cover_image_url


class StoryDetailSerializer(StoryListSerializer):
    narrations = StoryNarrationSerializer(many=True, read_only=True)

    class Meta(StoryListSerializer.Meta):
        fields = StoryListSerializer.Meta.fields + ('body', 'narrations')
