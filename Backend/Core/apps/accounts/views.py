from django.db import transaction
from django.shortcuts import get_object_or_404
from rest_framework import status, viewsets
from rest_framework.permissions import AllowAny, IsAuthenticated
from rest_framework.response import Response
from rest_framework.throttling import ScopedRateThrottle
from rest_framework.views import APIView
from rest_framework_simplejwt.exceptions import TokenError
from rest_framework_simplejwt.settings import api_settings
from rest_framework_simplejwt.tokens import RefreshToken
from rest_framework_simplejwt.views import TokenObtainPairView, TokenRefreshView

from .email_verification import (
    EmailAlreadyVerified,
    InvalidVerificationChallenge,
    InvalidVerificationCode,
    ResendTooSoon,
    VerificationDeliveryDelayed,
    confirm_email_verification,
    issue_email_verification_challenge,
    resend_email_verification,
    verification_payload,
)
from .models import EmailVerificationChallenge, KidProfile, KidProfilePreferences
from .serializers import (
    EmailVerificationConfirmSerializer,
    EmailVerificationResendSerializer,
    KidProfileSerializer,
    KidProfilePreferencesSerializer,
    LoginSerializer,
    ParentSerializer,
    RefreshSerializer,
    RegistrationSerializer,
)


def _token_response(user) -> dict[str, object]:
    if not user.is_email_verified:
        raise ValueError('Cannot issue session tokens before email verification.')
    refresh = RefreshToken.for_user(user)
    return {
        'user': ParentSerializer(user).data,
        'access': str(refresh.access_token),
        'refresh': str(refresh),
    }


def _delivery_delayed_response(challenge_id) -> Response:
    challenge = EmailVerificationChallenge.objects.select_related('user').get(
        pk=challenge_id
    )
    return Response(
        {
            'code': 'verification_delivery_delayed',
            'detail': (
                'We could not send the verification email yet. '
                'You can request another code now.'
            ),
            'verification_delivery_delayed': True,
            'verification': verification_payload(challenge),
        },
        status=status.HTTP_202_ACCEPTED,
    )


class RegisterView(APIView):
    permission_classes = (AllowAny,)
    throttle_classes = (ScopedRateThrottle,)
    throttle_scope = 'auth'

    def post(self, request):
        serializer = RegistrationSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        try:
            with transaction.atomic():
                user = serializer.save()
                challenge = issue_email_verification_challenge(user)
        except VerificationDeliveryDelayed as exc:
            return _delivery_delayed_response(exc.challenge_id)
        return Response(
            {'verification': verification_payload(challenge)},
            status=status.HTTP_202_ACCEPTED,
        )


class EmailVerificationConfirmView(APIView):
    permission_classes = (AllowAny,)
    throttle_classes = (ScopedRateThrottle,)
    throttle_scope = 'verification_confirm'

    def post(self, request):
        serializer = EmailVerificationConfirmSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        try:
            user = confirm_email_verification(**serializer.validated_data)
        except (InvalidVerificationChallenge, InvalidVerificationCode):
            return Response(
                {
                    'code': 'invalid_or_expired_code',
                    'detail': 'That verification code is incorrect or has expired.',
                },
                status=status.HTTP_400_BAD_REQUEST,
            )
        return Response(_token_response(user), status=status.HTTP_200_OK)


class EmailVerificationResendView(APIView):
    permission_classes = (AllowAny,)
    throttle_classes = (ScopedRateThrottle,)
    throttle_scope = 'verification_resend'

    def post(self, request):
        serializer = EmailVerificationResendSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        try:
            challenge = resend_email_verification(**serializer.validated_data)
        except VerificationDeliveryDelayed as exc:
            return _delivery_delayed_response(exc.challenge_id)
        except InvalidVerificationChallenge:
            return Response(
                {
                    'code': 'invalid_verification_challenge',
                    'detail': 'That verification request is no longer available.',
                },
                status=status.HTTP_400_BAD_REQUEST,
            )
        except EmailAlreadyVerified:
            return Response(
                {
                    'code': 'email_already_verified',
                    'detail': 'This email address is already verified.',
                },
                status=status.HTTP_409_CONFLICT,
            )
        except ResendTooSoon as exc:
            return Response(
                {
                    'code': 'resend_too_soon',
                    'detail': 'Please wait before requesting another code.',
                    'retry_after': exc.retry_after,
                },
                status=status.HTTP_429_TOO_MANY_REQUESTS,
                headers={'Retry-After': str(exc.retry_after)},
            )

        return Response(
            {'verification': verification_payload(challenge)},
            status=status.HTTP_202_ACCEPTED,
        )


class LoginView(TokenObtainPairView):
    permission_classes = (AllowAny,)
    throttle_classes = (ScopedRateThrottle,)
    throttle_scope = 'auth'
    serializer_class = LoginSerializer


class RefreshView(TokenRefreshView):
    permission_classes = (AllowAny,)
    throttle_classes = (ScopedRateThrottle,)
    throttle_scope = 'token_refresh'
    serializer_class = RefreshSerializer


class LogoutView(APIView):
    permission_classes = (IsAuthenticated,)

    def post(self, request):
        refresh_value = request.data.get('refresh')
        if not refresh_value:
            return Response(
                {'refresh': ['This field is required.']},
                status=status.HTTP_400_BAD_REQUEST,
            )

        try:
            refresh = RefreshToken(refresh_value)
            token_user_id = refresh.get(api_settings.USER_ID_CLAIM)
            if str(token_user_id) != str(request.user.pk):
                return Response(
                    {'detail': 'Refresh token does not belong to this account.'},
                    status=status.HTTP_400_BAD_REQUEST,
                )
            refresh.blacklist()
        except TokenError:
            return Response(
                {'refresh': ['Invalid or expired refresh token.']},
                status=status.HTTP_400_BAD_REQUEST,
            )

        return Response(status=status.HTTP_204_NO_CONTENT)


class MeView(APIView):
    permission_classes = (IsAuthenticated,)

    def get(self, request):
        return Response(ParentSerializer(request.user).data)


class KidProfileViewSet(viewsets.ModelViewSet):
    serializer_class = KidProfileSerializer
    permission_classes = (IsAuthenticated,)
    lookup_field = 'id'

    def get_queryset(self):
        return KidProfile.objects.filter(parent=self.request.user)

    def create(self, request, *args, **kwargs):
        serializer = self.get_serializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        validated_data = serializer.validated_data
        profile, created = KidProfile.objects.get_or_create(
            parent=request.user,
            creation_operation_id=validated_data['creation_operation_id'],
            defaults={
                'display_name': validated_data['display_name'],
                'avatar_key': validated_data['avatar_key'],
            },
        )
        response_serializer = self.get_serializer(profile)
        response_status = (
            status.HTTP_201_CREATED if created else status.HTTP_200_OK
        )
        return Response(response_serializer.data, status=response_status)


class KidProfilePreferencesView(APIView):
    """Read or partially update preferences for one owned child profile."""

    permission_classes = (IsAuthenticated,)

    def _owned_profile(self, request, profile_id):
        # A single filtered lookup keeps foreign and missing IDs
        # indistinguishable to the caller.
        return get_object_or_404(
            KidProfile,
            pk=profile_id,
            parent=request.user,
        )

    @staticmethod
    def _preferences(profile):
        # Lock the stable profile row so simultaneous first reads/updates do
        # not race to create the one-to-one defaults.
        with transaction.atomic():
            locked_profile = KidProfile.objects.select_for_update().get(
                pk=profile.pk,
            )
            preferences, _ = KidProfilePreferences.objects.get_or_create(
                profile=locked_profile,
            )
        return preferences

    def get(self, request, profile_id):
        profile = self._owned_profile(request, profile_id)
        serializer = KidProfilePreferencesSerializer(self._preferences(profile))
        return Response(serializer.data)

    def patch(self, request, profile_id):
        profile = self._owned_profile(request, profile_id)
        input_serializer = KidProfilePreferencesSerializer(
            data=request.data,
            partial=True,
        )
        input_serializer.is_valid(raise_exception=True)
        preferences = self._preferences(profile)
        changed_fields = []
        for field in ('story_text_scale', 'narration_enabled'):
            if field in input_serializer.validated_data:
                setattr(preferences, field, input_serializer.validated_data[field])
                changed_fields.append(field)
        if changed_fields:
            preferences.save(update_fields=(*changed_fields, 'updated_at'))
        return Response(KidProfilePreferencesSerializer(preferences).data)
