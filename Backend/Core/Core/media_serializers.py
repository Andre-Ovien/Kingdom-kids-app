"""Keep bearer URLs out of production exception-report representation frames."""
from django.views.decorators.debug import sensitive_variables
from rest_framework import serializers


class PrivateMediaRepresentation:
    @sensitive_variables()
    def to_representation(self, instance):
        return super().to_representation(instance)


class PrivateMediaListSerializer(PrivateMediaRepresentation, serializers.ListSerializer):
    pass
