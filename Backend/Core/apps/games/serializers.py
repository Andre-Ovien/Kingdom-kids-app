from rest_framework import serializers
from Core.media_delivery import private_media_url
from Core.media_serializers import PrivateMediaListSerializer, PrivateMediaRepresentation

from .models import Game, GameLevel, KidGameProgress
from .services import public_level_config


def progress_payload(
    progress: KidGameProgress | None,
    *,
    total_levels: int,
    profile_id=None,
) -> dict:
    level_progress = progress.level_progress if progress else {}
    completed_levels = sum(
        bool(value.get('completed'))
        for value in level_progress.values()
        if isinstance(value, dict)
    )
    highest_completed = progress.highest_completed_level if progress else 0
    return {
        'profile_id': progress.profile_id if progress else profile_id,
        'highest_completed_level': highest_completed,
        'current_level': min(highest_completed + 1, total_levels) if total_levels else 1,
        'total_stars': progress.total_stars if progress else 0,
        'max_stars': total_levels * 3,
        'best_score': max(
            (
                int(value.get('best_score', 0))
                for value in level_progress.values()
                if isinstance(value, dict)
            ),
            default=0,
        ),
        'completed_levels': completed_levels,
        'total_levels': total_levels,
        'completion_percent': completed_levels / total_levels if total_levels else 0,
        'last_played_at': progress.last_played_at if progress else None,
    }


class GameLevelSerializer(serializers.ModelSerializer):
    config = serializers.SerializerMethodField()

    class Meta:
        model = GameLevel
        fields = (
            'id',
            'level_number',
            'title',
            'instructions',
            'max_score',
            'config',
        )

    def get_config(self, level: GameLevel) -> dict:
        return public_level_config(level)


class GameListSerializer(PrivateMediaRepresentation, serializers.ModelSerializer):
    total_levels = serializers.SerializerMethodField()
    progress = serializers.SerializerMethodField()
    cover_image_url = serializers.SerializerMethodField()

    class Meta:
        model = Game
        list_serializer_class = PrivateMediaListSerializer
        fields = (
            'id',
            'slug',
            'title',
            'subtitle',
            'description',
            'game_type',
            'difficulty',
            'estimated_duration_seconds',
            'cover_asset_key',
            'cover_image_url',
            'accent_color',
            'icon_key',
            'is_featured',
            'total_levels',
            'progress',
        )

    def get_cover_image_url(self, game: Game) -> str | None:
        return private_media_url(
            self.context.get('request'),
            f'Frontend/mobile/{game.cover_asset_key}',
            use=f'game-cover:{game.slug}',
        )

    def get_total_levels(self, game: Game) -> int:
        annotated = getattr(game, 'total_levels', None)
        return annotated if annotated is not None else len(game.levels.all())

    def get_progress(self, game: Game) -> dict:
        progress_map = self.context.get('progress_map', {})
        return progress_payload(
            progress_map.get(game.pk),
            total_levels=self.get_total_levels(game),
            profile_id=self.context.get('profile_id'),
        )


class GameDetailSerializer(GameListSerializer):
    levels = GameLevelSerializer(many=True, read_only=True)

    class Meta(GameListSerializer.Meta):
        fields = GameListSerializer.Meta.fields + ('levels',)


class GameSubmissionSerializer(serializers.Serializer):
    profile_id = serializers.UUIDField()
    level_number = serializers.IntegerField(min_value=1, max_value=65_535)
    operation_id = serializers.UUIDField()
    result = serializers.JSONField()

    def validate_result(self, value):
        if not isinstance(value, dict):
            raise serializers.ValidationError('Must be an object.')
        forbidden = {'score', 'stars', 'completed', 'max_score'} & set(value)
        if forbidden:
            raise serializers.ValidationError(
                'Score, stars, and completion are computed by the server.'
            )
        return value
