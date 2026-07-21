from django.contrib.auth import password_validation
from django.contrib.auth.models import update_last_login
from django.core.exceptions import ValidationError as DjangoValidationError
from django.db import IntegrityError, transaction
from rest_framework import serializers
from rest_framework.exceptions import APIException
from rest_framework_simplejwt.exceptions import InvalidToken
from rest_framework_simplejwt.settings import api_settings
from rest_framework_simplejwt.serializers import (
    TokenObtainPairSerializer,
    TokenObtainSerializer,
)
from rest_framework_simplejwt.serializers import TokenRefreshSerializer
from rest_framework_simplejwt.tokens import RefreshToken

from .email_verification import (
    VerificationDeliveryDelayed,
    challenge_for_unverified_login,
    verification_payload,
)
from .models import (
    EmailVerificationChallenge,
    KidProfile,
    KidProfilePreferences,
    User,
)


class KidProfileSerializer(serializers.ModelSerializer):
    operation_id = serializers.UUIDField(
        source='creation_operation_id',
        write_only=True,
        required=False,
    )

    class Meta:
        model = KidProfile
        fields = (
            'id',
            'display_name',
            'avatar_key',
            'operation_id',
            'created_at',
            'updated_at',
        )
        read_only_fields = ('id', 'created_at', 'updated_at')

    def validate(self, attrs):
        if self.instance is None and 'creation_operation_id' not in attrs:
            raise serializers.ValidationError(
                {'operation_id': 'This field is required.'}
            )
        if self.instance is not None and 'creation_operation_id' in attrs:
            raise serializers.ValidationError(
                {'operation_id': 'This field cannot be changed.'}
            )
        return attrs

    def validate_display_name(self, value: str) -> str:
        display_name = ' '.join(value.split())
        if not display_name:
            raise serializers.ValidationError('Display name cannot be blank.')
        return display_name


class KidProfilePreferencesSerializer(serializers.ModelSerializer):
    profile_id = serializers.UUIDField(read_only=True)

    class Meta:
        model = KidProfilePreferences
        fields = (
            'profile_id',
            'story_text_scale',
            'narration_enabled',
            'updated_at',
        )
        read_only_fields = ('profile_id', 'updated_at')


class ParentSerializer(serializers.ModelSerializer):
    kid_profiles = KidProfileSerializer(many=True, read_only=True)
    email_verified = serializers.BooleanField(
        source='is_email_verified',
        read_only=True,
    )

    class Meta:
        model = User
        fields = ('id', 'email', 'email_verified', 'kid_profiles')
        read_only_fields = fields


class RegistrationSerializer(serializers.Serializer):
    email = serializers.EmailField(max_length=254)
    password = serializers.CharField(write_only=True, trim_whitespace=False)
    password_confirmation = serializers.CharField(write_only=True, trim_whitespace=False)

    def validate_email(self, value: str) -> str:
        return User.objects.normalize_email(value)

    def validate(self, attrs):
        if attrs['password'] != attrs['password_confirmation']:
            raise serializers.ValidationError(
                {'password_confirmation': 'Passwords do not match.'}
            )

        try:
            password_validation.validate_password(
                attrs['password'],
                user=User(email=attrs['email']),
            )
        except DjangoValidationError as exc:
            raise serializers.ValidationError({'password': list(exc.messages)}) from exc

        return attrs

    def create(self, validated_data):
        password = validated_data.pop('password')
        validated_data.pop('password_confirmation')
        email = validated_data['email']

        with transaction.atomic():
            user = User.objects.select_for_update().filter(email=email).first()
            if user is not None:
                return self._reclaim_pending_user(user, password)

            try:
                # Keep the insert in a savepoint. If another registration wins
                # the unique-email race, the outer transaction stays usable so
                # we can lock and apply the same reclaimability rules to its row.
                with transaction.atomic():
                    return User.objects.create_user(
                        password=password,
                        **validated_data,
                    )
            except IntegrityError as exc:
                try:
                    user = User.objects.select_for_update().get(email=email)
                except User.DoesNotExist:
                    raise exc
                return self._reclaim_pending_user(user, password)

    def _reclaim_pending_user(self, user: User, password: str) -> User:
        if not user.is_active or user.is_email_verified:
            raise serializers.ValidationError(
                {'email': 'An account with this email already exists.'}
            )

        user.set_password(password)
        user.save(update_fields=('password',))
        return user


class LoginSerializer(TokenObtainPairSerializer):
    """SimpleJWT login response enriched with the authenticated parent."""

    class EmailVerificationRequired(APIException):
        status_code = 403
        default_code = 'email_verification_required'

        def __init__(self, challenge, *, delivery_delayed=False):
            detail = {
                'code': 'email_verification_required',
                'detail': 'Verify your email address before signing in.',
                'verification': verification_payload(challenge),
            }
            if delivery_delayed:
                detail.update(
                    {
                        'verification_delivery_code': (
                            'verification_delivery_delayed'
                        ),
                        'verification_delivery_delayed': True,
                    }
                )
            super().__init__(detail)

    def validate(self, attrs):
        email = attrs.get(self.username_field)
        if isinstance(email, str):
            attrs[self.username_field] = User.objects.normalize_email(email)

        # Authenticate first, but do not mint tokens until ownership of the
        # account email has been verified.
        data = TokenObtainSerializer.validate(self, attrs)
        if not self.user.is_email_verified:
            try:
                challenge = challenge_for_unverified_login(self.user)
            except VerificationDeliveryDelayed as exc:
                challenge = (
                    EmailVerificationChallenge.objects.select_related('user').get(
                        pk=exc.challenge_id
                    )
                )
                raise self.EmailVerificationRequired(
                    challenge,
                    delivery_delayed=True,
                ) from exc
            raise self.EmailVerificationRequired(challenge)

        refresh = self.get_token(self.user)
        data['refresh'] = str(refresh)
        data['access'] = str(refresh.access_token)
        if api_settings.UPDATE_LAST_LOGIN:
            update_last_login(None, self.user)
        data['user'] = ParentSerializer(self.user).data
        return data


class RefreshSerializer(TokenRefreshSerializer):
    """Reject refreshes for a parent that has since been disabled or removed."""

    def validate(self, attrs):
        refresh = RefreshToken(attrs['refresh'])
        user_id = refresh.get(api_settings.USER_ID_CLAIM)
        if not User.objects.filter(
            pk=user_id,
            is_active=True,
            email_verified_at__isnull=False,
        ).exists():
            raise InvalidToken('No active account found for this refresh token.')
        try:
            return super().validate(attrs)
        except User.DoesNotExist as exc:
            # The account can be removed after the check above and before
            # SimpleJWT resolves it while refreshing the token.
            raise InvalidToken('No active account found for this refresh token.') from exc


class EmailVerificationConfirmSerializer(serializers.Serializer):
    challenge_id = serializers.UUIDField()
    code = serializers.RegexField(
        r'^[0-9]{6}$',
        error_messages={'invalid': 'Enter the six-digit verification code.'},
    )


class EmailVerificationResendSerializer(serializers.Serializer):
    challenge_id = serializers.UUIDField()
