from collections.abc import Mapping

from rest_framework import serializers

from .models import KidActivityEvent


class KidActivityEventCreateSerializer(serializers.Serializer):
    """Validate the complete, deliberately small story-event command."""

    operation_id = serializers.UUIDField()
    event_type = serializers.ChoiceField(choices=KidActivityEvent.EventType.choices)
    story_id = serializers.UUIDField()

    def to_internal_value(self, data):
        if isinstance(data, Mapping):
            unknown_fields = sorted(set(data) - set(self.fields))
            if unknown_fields:
                raise serializers.ValidationError(
                    {
                        field: ['Unknown field.']
                        for field in unknown_fields
                    }
                )
        return super().to_internal_value(data)


class ProfileSummaryQuerySerializer(serializers.Serializer):
    """Validate the fixed device offset used for local activity buckets."""

    timezone_offset_minutes = serializers.IntegerField(
        required=False,
        default=0,
        min_value=-840,
        max_value=840,
    )
