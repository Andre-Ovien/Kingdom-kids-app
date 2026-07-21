from rest_framework import serializers

from .models import Story, StoryNarration


class StoryNarrationSerializer(serializers.ModelSerializer):
    avatar_key = serializers.CharField(source='narrator.avatar_key')
    voice_key = serializers.CharField(source='narrator.voice_key')
    character_name = serializers.CharField(source='narrator.display_name')
    voice_description = serializers.CharField(source='narrator.voice_description')
    locale = serializers.CharField(source='narrator.locale')
    speech_rate = serializers.FloatField(source='narrator.speech_rate')
    pitch = serializers.FloatField(source='narrator.pitch')
    sample_url = serializers.SerializerMethodField()
    audio_available = serializers.BooleanField(read_only=True)

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
        )

    def get_sample_url(self, narration: StoryNarration) -> str | None:
        narrator = narration.narrator
        if narrator.cached_sample_available:
            url = narrator.sample_audio.url
        elif narrator.sample_url:
            url = narrator.sample_url
        else:
            return None

        request = self.context.get('request')
        return request.build_absolute_uri(url) if request else url


class StoryListSerializer(serializers.ModelSerializer):
    rating = serializers.FloatField(read_only=True)
    estimated_read_seconds = serializers.SerializerMethodField()

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


class StoryDetailSerializer(StoryListSerializer):
    narrations = StoryNarrationSerializer(many=True, read_only=True)

    class Meta(StoryListSerializer.Meta):
        fields = StoryListSerializer.Meta.fields + ('body', 'narrations')
