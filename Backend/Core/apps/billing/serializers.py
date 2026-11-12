from rest_framework import serializers


class CheckoutConsentSerializer(serializers.Serializer):
    password = serializers.CharField(write_only=True, trim_whitespace=False, max_length=1024)
    disclosure_version = serializers.CharField(max_length=96)
    accepted = serializers.BooleanField()

    def to_internal_value(self, data):
        if not isinstance(data, dict) or set(data) - set(self.fields) or type(data.get('accepted')) is not bool:
            raise serializers.ValidationError({'non_field_errors': ['Only the current disclosure and fresh parent confirmation are accepted.']})
        return super().to_internal_value(data)


class CheckoutCardSerializer(serializers.Serializer):
    password = serializers.CharField(write_only=True, trim_whitespace=False, max_length=1024)
    source_id = serializers.CharField(write_only=True, trim_whitespace=False, max_length=16_384,
                                     required=False, allow_blank=False)

    def to_internal_value(self, data):
        if not isinstance(data, dict) or set(data) - set(self.fields):
            raise serializers.ValidationError({'non_field_errors': ['Only a tokenized Sandbox source and fresh parent confirmation are accepted.']})
        return super().to_internal_value(data)


class TermCheckoutConsentSerializer(CheckoutConsentSerializer):
    billing_period = serializers.ChoiceField(choices=('monthly', 'yearly'), default='monthly')
    disclosure_sha256 = serializers.CharField(min_length=64, max_length=64)


class TermCheckoutCardSerializer(CheckoutCardSerializer):
    verification_token = serializers.CharField(write_only=True, trim_whitespace=False,
        max_length=16_384, required=False, allow_blank=False)
    postal_code = serializers.RegexField(r'^[0-9]{5}$', required=False, default='94103', write_only=True)
    charge_source_id = serializers.CharField(write_only=True, trim_whitespace=False,
        max_length=16_384, required=False, allow_blank=False)

    def validate(self, attrs):
        if 'charge_source_id' in attrs and any(key in attrs for key in ('source_id', 'verification_token')):
            raise serializers.ValidationError('Use one payment workflow, never mixed card sources.')
        return attrs


class TermPrepareCardSerializer(TermCheckoutCardSerializer):
    source_id = serializers.CharField(write_only=True, trim_whitespace=False, max_length=16_384)
    postal_code = serializers.RegexField(r'^[0-9]{5}$', required=True, write_only=True)


class StopRenewalSerializer(serializers.Serializer):
    password = serializers.CharField(write_only=True, trim_whitespace=False, max_length=1024)

    def to_internal_value(self, data):
        if not isinstance(data, dict) or set(data) != {'password'}:
            raise serializers.ValidationError({'non_field_errors': ['Fresh parent confirmation is required.']})
        return super().to_internal_value(data)
