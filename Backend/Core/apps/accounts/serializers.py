from collections.abc import Mapping
from dataclasses import dataclass

from django.contrib.auth import password_validation
from Core.email_capability import require_email_delivery
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
from rest_framework_simplejwt.tokens import UntypedToken
from rest_framework_simplejwt.token_blacklist.models import OutstandingToken
from rest_framework_simplejwt.utils import get_md5_hash_password

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
    WaitlistSubscriber,
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
            'streak_timezone_offset_minutes',
            'updated_at',
        )
        read_only_fields = (
            'profile_id',
            'streak_timezone_offset_minutes',
            'updated_at',
        )


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


@dataclass(frozen=True)
class RegistrationResult:
    user: User | None
    email: str
    issue_challenge: bool


class RegistrationSerializer(serializers.Serializer):
    email = serializers.EmailField(max_length=254)
    password = serializers.CharField(
        write_only=True,
        trim_whitespace=False,
        max_length=128,
    )
    password_confirmation = serializers.CharField(
        write_only=True,
        trim_whitespace=False,
        max_length=128,
    )

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
        require_email_delivery()
        password = validated_data.pop('password')
        validated_data.pop('password_confirmation')
        email = validated_data['email']

        with transaction.atomic():
            user = User.objects.select_for_update().filter(email=email).first()
            if user is not None:
                return self._existing_account_result(user, email, password)

            try:
                # Keep the insert in a savepoint. If another registration wins
                # the unique-email race, the outer transaction stays usable so
                # we can lock and apply the same reclaimability rules to its row.
                with transaction.atomic():
                    user = User.objects.create_user(
                        password=password,
                        **validated_data,
                    )
                    return RegistrationResult(
                        user=user,
                        email=email,
                        issue_challenge=True,
                    )
            except IntegrityError as exc:
                try:
                    user = User.objects.select_for_update().get(email=email)
                except User.DoesNotExist:
                    raise exc from None
                return self._existing_account_result(user, email, password)

    @staticmethod
    def _existing_account_result(
        user: User,
        email: str,
        password: str,
    ) -> RegistrationResult:
        # Registration must never reset a password without proof of email
        # ownership. A pending parent using the same password may safely resume;
        # every other duplicate gets a non-actionable, non-enumerating response.
        can_resume = (
            user.is_active
            and not user.is_email_verified
            and user.check_password(password)
        )
        return RegistrationResult(
            user=user if can_resume else None,
            email=email,
            issue_challenge=can_resume,
        )


class DeleteAccountSerializer(serializers.Serializer):
    password = serializers.CharField(
        write_only=True,
        trim_whitespace=False,
        max_length=128,
    )

    def validate_password(self, value: str) -> str:
        user = self.context['request'].user
        if not user.check_password(value):
            raise serializers.ValidationError(
                'The password is incorrect.'
            )
        return value


class LogoutSerializer(serializers.Serializer):
    refresh = serializers.CharField(
        trim_whitespace=False,
        max_length=4096,
    )


class DeleteUnverifiedAccountSerializer(serializers.Serializer):
    """Authorize deletion without issuing a session to an unverified account."""

    email = serializers.EmailField(max_length=254)
    password = serializers.CharField(
        write_only=True,
        trim_whitespace=False,
        max_length=128,
    )
    confirmation = serializers.RegexField(r'^DELETE$')

    def validate_email(self, value: str) -> str:
        return User.objects.normalize_email(value)

    def to_internal_value(self, data):
        if isinstance(data, Mapping):
            unknown_fields = sorted(set(data) - set(self.fields))
            if unknown_fields:
                raise serializers.ValidationError(
                    {field: ['Unknown field.'] for field in unknown_fields}
                )
        return super().to_internal_value(data)


class PasswordResetRequestSerializer(serializers.Serializer):
    email = serializers.EmailField(max_length=254)

    def validate_email(self, value: str) -> str:
        return User.objects.normalize_email(value)


class PasswordResetVerifySerializer(serializers.Serializer):
    challenge_id = serializers.UUIDField()
    code = serializers.RegexField(
        r'^[0-9]{6}$',
        write_only=True,
        error_messages={'invalid': 'Enter the six-digit password reset code.'},
    )

    def to_internal_value(self, data):
        if isinstance(data, Mapping):
            unknown_fields = sorted(set(data) - set(self.fields))
            if unknown_fields:
                raise serializers.ValidationError(
                    {field: ['Unknown field.'] for field in unknown_fields}
                )
        return super().to_internal_value(data)


class PasswordResetConfirmSerializer(serializers.Serializer):
    challenge_id = serializers.UUIDField()
    code = serializers.RegexField(
        r'^[0-9]{6}$',
        error_messages={'invalid': 'Enter the six-digit password reset code.'},
    )
    new_password = serializers.CharField(
        write_only=True,
        trim_whitespace=False,
        max_length=128,
    )
    new_password_confirmation = serializers.CharField(
        write_only=True,
        trim_whitespace=False,
        max_length=128,
    )

    def validate(self, attrs):
        if attrs['new_password'] != attrs['new_password_confirmation']:
            raise serializers.ValidationError(
                {'new_password_confirmation': 'Passwords do not match.'}
            )
        try:
            # The service repeats this with the locked real user after the code
            # is proven so Django's user-attribute similarity checks also run.
            password_validation.validate_password(attrs['new_password'])
        except DjangoValidationError as exc:
            raise serializers.ValidationError(
                {'new_password': list(exc.messages)}
            ) from exc
        return attrs


class AccountDeletionRequestSerializer(serializers.Serializer):
    email = serializers.EmailField(max_length=254)

    def validate_email(self, value: str) -> str:
        return User.objects.normalize_email(value)

    def to_internal_value(self, data):
        if isinstance(data, Mapping):
            unknown_fields = sorted(set(data) - set(self.fields))
            if unknown_fields:
                raise serializers.ValidationError(
                    {field: ['Unknown field.'] for field in unknown_fields}
                )
        return super().to_internal_value(data)


class AccountDeletionConfirmSerializer(serializers.Serializer):
    challenge_id = serializers.UUIDField()
    code = serializers.RegexField(
        r'^[0-9]{6}$',
        error_messages={'invalid': 'Enter the six-digit account deletion code.'},
    )
    confirmation = serializers.RegexField(r'^DELETE$')

    def to_internal_value(self, data):
        if isinstance(data, Mapping):
            unknown_fields = sorted(set(data) - set(self.fields))
            if unknown_fields:
                raise serializers.ValidationError(
                    {field: ['Unknown field.'] for field in unknown_fields}
                )
        return super().to_internal_value(data)


class WaitlistSignupSerializer(serializers.Serializer):
    """Validate an explicit waitlist request without exposing membership."""

    email = serializers.EmailField(max_length=254)

    def validate_email(self, value: str) -> str:
        return User.objects.normalize_email(value)

    def create(self, validated_data):
        email = validated_data['email']
        try:
            with transaction.atomic():
                subscriber, _ = WaitlistSubscriber.objects.get_or_create(
                    email=email,
                    defaults={
                        'consent_source': (
                            WaitlistSubscriber.ConsentSource.WEBSITE_FOOTER
                        ),
                    },
                )
        except IntegrityError:
            # A simultaneous case-insensitive insert can win the unique
            # constraint. Returning its row keeps the public command idempotent.
            subscriber = WaitlistSubscriber.objects.get(email__iexact=email)
        return subscriber


class LoginSerializer(TokenObtainPairSerializer):
    """SimpleJWT login response enriched with the authenticated parent."""

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        # SimpleJWT creates these fields in __init__; declaring them on this
        # subclass alone would be overwritten. Match registration's bounds and
        # preserve the exact password, including intentional outer spaces.
        self.fields[self.username_field] = serializers.EmailField(
            write_only=True,
            max_length=254,
        )
        self.fields['password'] = serializers.CharField(
            write_only=True,
            trim_whitespace=False,
            max_length=128,
            style={'input_type': 'password'},
        )

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

    refresh = serializers.CharField(trim_whitespace=False, max_length=4096)

    def validate(self, attrs):
        raw_refresh = attrs['refresh']
        untyped = UntypedToken(raw_refresh)
        if untyped.get(api_settings.TOKEN_TYPE_CLAIM) != 'refresh':
            raise InvalidToken('Token has the wrong type.')
        jti = untyped.get(api_settings.JTI_CLAIM)
        user_id = untyped.get(api_settings.USER_ID_CLAIM)
        try:
            with transaction.atomic():
                # Deletion and password recovery lock the parent before its
                # related rows. Use that same order so refresh rotation cannot
                # hold a token lock while waiting on a parent being deleted.
                user = User.objects.select_for_update().get(
                    pk=user_id,
                    is_active=True,
                    email_verified_at__isnull=False,
                )
                OutstandingToken.objects.select_for_update().get(
                    jti=jti,
                    user=user,
                )
                refresh = RefreshToken(raw_refresh)
                if refresh.get(api_settings.REVOKE_TOKEN_CLAIM) != (
                    get_md5_hash_password(user.password)
                ):
                    raise InvalidToken(
                        'The account password changed after this token was issued.'
                    )
                return super().validate(attrs)
        except (OutstandingToken.DoesNotExist, User.DoesNotExist) as exc:
            raise InvalidToken(
                'No active account found for this refresh token.'
            ) from exc


class EmailVerificationConfirmSerializer(serializers.Serializer):
    challenge_id = serializers.UUIDField()
    code = serializers.RegexField(
        r'^[0-9]{6}$',
        error_messages={'invalid': 'Enter the six-digit verification code.'},
    )


class EmailVerificationResendSerializer(serializers.Serializer):
    challenge_id = serializers.UUIDField()
