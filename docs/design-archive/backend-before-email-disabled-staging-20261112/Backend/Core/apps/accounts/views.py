from django.conf import settings
from django.core.exceptions import ValidationError as DjangoValidationError
from django.db import transaction
from django.shortcuts import get_object_or_404
from django.views.decorators.debug import sensitive_variables
from rest_framework import status, viewsets
from rest_framework.exceptions import ValidationError
from rest_framework.parsers import JSONParser
from rest_framework.permissions import AllowAny, IsAuthenticated
from rest_framework.response import Response
from rest_framework.throttling import ScopedRateThrottle, UserRateThrottle
from rest_framework.views import APIView
from rest_framework_simplejwt.exceptions import TokenError
from rest_framework_simplejwt.settings import api_settings
from rest_framework_simplejwt.token_blacklist.models import OutstandingToken
from rest_framework_simplejwt.tokens import RefreshToken
from rest_framework_simplejwt.views import TokenObtainPairView, TokenRefreshView

from .account_deletion import (
    InvalidAccountDeletionChallenge,
    confirm_account_deletion,
    request_account_deletion,
)
from .email_verification import (
    EmailAlreadyVerified,
    InvalidVerificationChallenge,
    InvalidVerificationCode,
    ResendTooSoon,
    VerificationDeliveryDelayed,
    confirm_email_verification,
    issue_email_verification_challenge,
    private_registration_payload,
    resend_email_verification,
    verification_payload,
)
from .models import (
    EmailVerificationChallenge,
    KidProfile,
    KidProfilePreferences,
    User,
    WaitlistSubscriber,
)
from .password_reset import (
    InvalidPasswordResetChallenge,
    confirm_password_reset,
    request_password_reset,
    verify_password_reset_code,
)
from .serializers import (
    AccountDeletionConfirmSerializer,
    AccountDeletionRequestSerializer,
    DeleteAccountSerializer,
    DeleteUnverifiedAccountSerializer,
    EmailVerificationConfirmSerializer,
    EmailVerificationResendSerializer,
    KidProfileSerializer,
    KidProfilePreferencesSerializer,
    LoginSerializer,
    LogoutSerializer,
    ParentSerializer,
    PasswordResetConfirmSerializer,
    PasswordResetRequestSerializer,
    PasswordResetVerifySerializer,
    RefreshSerializer,
    RegistrationSerializer,
    WaitlistSignupSerializer,
)
from .throttles import (
    AccountDeletionEmailRateThrottle,
    LoginEmailRateThrottle,
    PasswordResetEmailRateThrottle,
    RegistrationEmailRateThrottle,
    UnverifiedAccountDeletionEmailRateThrottle,
)


def _token_response(user) -> dict[str, object]:
    if not user.is_active or not user.is_email_verified:
        raise ValueError('Cannot issue session tokens for this account.')
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


class NoStoreResponseMixin:
    """Keep credentials, challenge handles and family data out of HTTP caches."""

    def finalize_response(self, request, response, *args, **kwargs):
        response = super().finalize_response(request, response, *args, **kwargs)
        response['Cache-Control'] = 'no-store'
        return response


class RegisterView(NoStoreResponseMixin, APIView):
    permission_classes = (AllowAny,)
    throttle_classes = (ScopedRateThrottle, RegistrationEmailRateThrottle)
    throttle_scope = 'auth'

    def post(self, request):
        serializer = RegistrationSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        try:
            with transaction.atomic():
                result = serializer.save()
                if not result.issue_challenge or result.user is None:
                    return Response(
                        {
                            'verification': private_registration_payload(
                                result.email
                            )
                        },
                        status=status.HTTP_202_ACCEPTED,
                    )
                challenge = issue_email_verification_challenge(result.user)
        except VerificationDeliveryDelayed as exc:
            return _delivery_delayed_response(exc.challenge_id)
        return Response(
            {'verification': verification_payload(challenge)},
            status=status.HTTP_202_ACCEPTED,
        )


class WaitlistSignupView(APIView):
    """Accept a footer signup without disclosing existing subscribers."""

    permission_classes = (AllowAny,)
    throttle_classes = (ScopedRateThrottle,)
    throttle_scope = 'waitlist'

    def post(self, request):
        serializer = WaitlistSignupSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        serializer.save()
        return Response(
            {'detail': 'Thanks. Your waitlist request has been received.'},
            status=status.HTTP_202_ACCEPTED,
        )


class PasswordResetRequestView(NoStoreResponseMixin, APIView):
    """Issue a real or decoy recovery handle with one generic response."""

    permission_classes = (AllowAny,)
    throttle_classes = (ScopedRateThrottle, PasswordResetEmailRateThrottle)
    throttle_scope = 'password_reset_request'

    def post(self, request):
        serializer = PasswordResetRequestSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        challenge_id = request_password_reset(serializer.validated_data['email'])
        return Response(
            {
                'detail': (
                    'If an eligible account exists for that email, a password '
                    'reset code has been sent.'
                ),
                'challenge_id': str(challenge_id),
                'expires_in': int(settings.PASSWORD_RESET_TTL.total_seconds()),
            },
            status=status.HTTP_202_ACCEPTED,
        )


class PasswordResetVerifyView(NoStoreResponseMixin, APIView):
    permission_classes = (AllowAny,)
    throttle_classes = (ScopedRateThrottle,)
    # Verification and final confirmation share an IP budget as well as the
    # challenge's locked attempt counter.
    throttle_scope = 'password_reset_confirm'

    def post(self, request):
        serializer = PasswordResetVerifySerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        try:
            verify_password_reset_code(
                challenge_id=serializer.validated_data['challenge_id'],
                code=serializer.validated_data['code'],
            )
        except InvalidPasswordResetChallenge:
            return Response(
                {
                    'code': 'invalid_or_expired_password_reset',
                    'detail': (
                        'That password reset code is incorrect or has expired.'
                    ),
                },
                status=status.HTTP_400_BAD_REQUEST,
            )
        return Response(status=status.HTTP_204_NO_CONTENT)


class PasswordResetConfirmView(NoStoreResponseMixin, APIView):
    permission_classes = (AllowAny,)
    throttle_classes = (ScopedRateThrottle,)
    throttle_scope = 'password_reset_confirm'

    def post(self, request):
        serializer = PasswordResetConfirmSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        try:
            confirm_password_reset(
                challenge_id=serializer.validated_data['challenge_id'],
                code=serializer.validated_data['code'],
                new_password=serializer.validated_data['new_password'],
            )
        except InvalidPasswordResetChallenge:
            return Response(
                {
                    'code': 'invalid_or_expired_password_reset',
                    'detail': (
                        'That password reset code is incorrect or has expired.'
                    ),
                },
                status=status.HTTP_400_BAD_REQUEST,
            )
        except DjangoValidationError as exc:
            return Response(
                {'new_password': list(exc.messages)},
                status=status.HTTP_400_BAD_REQUEST,
            )
        return Response(status=status.HTTP_204_NO_CONTENT)


class AccountDeletionRequestView(NoStoreResponseMixin, APIView):
    """Issue a real or decoy deletion handle with one generic response."""

    permission_classes = (AllowAny,)
    parser_classes = (JSONParser,)
    throttle_classes = (ScopedRateThrottle, AccountDeletionEmailRateThrottle)
    throttle_scope = 'account_deletion_request'

    def post(self, request):
        serializer = AccountDeletionRequestSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        challenge_id = request_account_deletion(
            serializer.validated_data['email']
        )
        return Response(
            {
                'detail': (
                    'If an eligible account exists for that email, an account '
                    'deletion code has been sent.'
                ),
                'challenge_id': str(challenge_id),
                'expires_in': int(
                    settings.ACCOUNT_DELETION_TTL.total_seconds()
                ),
            },
            status=status.HTTP_202_ACCEPTED,
        )


class AccountDeletionConfirmView(NoStoreResponseMixin, APIView):
    permission_classes = (AllowAny,)
    parser_classes = (JSONParser,)
    throttle_classes = (ScopedRateThrottle,)
    throttle_scope = 'account_deletion_confirm'

    @sensitive_variables()
    def post(self, request):
        serializer = AccountDeletionConfirmSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        try:
            confirm_account_deletion(
                challenge_id=serializer.validated_data['challenge_id'],
                code=serializer.validated_data['code'],
            )
        except InvalidAccountDeletionChallenge:
            return Response(
                {
                    'code': 'invalid_or_expired_account_deletion',
                    'detail': (
                        'That account deletion code is incorrect or has expired.'
                    ),
                },
                status=status.HTTP_400_BAD_REQUEST,
            )

        return Response(status=status.HTTP_204_NO_CONTENT)


class EmailVerificationConfirmView(NoStoreResponseMixin, APIView):
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


class EmailVerificationResendView(NoStoreResponseMixin, APIView):
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


class LoginView(NoStoreResponseMixin, TokenObtainPairView):
    permission_classes = (AllowAny,)
    throttle_classes = (ScopedRateThrottle, LoginEmailRateThrottle)
    throttle_scope = 'auth'
    serializer_class = LoginSerializer


class RefreshView(NoStoreResponseMixin, TokenRefreshView):
    permission_classes = (AllowAny,)
    throttle_classes = (ScopedRateThrottle,)
    throttle_scope = 'token_refresh'
    serializer_class = RefreshSerializer


class LogoutView(NoStoreResponseMixin, APIView):
    permission_classes = (IsAuthenticated,)

    def post(self, request):
        serializer = LogoutSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        refresh_value = serializer.validated_data['refresh']

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


class MeView(NoStoreResponseMixin, APIView):
    permission_classes = (IsAuthenticated,)

    def get_throttles(self):
        if self.request.method == 'DELETE':
            self.throttle_scope = 'account_delete'
            return (ScopedRateThrottle(), UserRateThrottle())
        return super().get_throttles()

    def get(self, request):
        return Response(ParentSerializer(request.user).data)

    @sensitive_variables()
    def delete(self, request):
        serializer = DeleteAccountSerializer(
            data=request.data,
            context={'request': request},
        )
        serializer.is_valid(raise_exception=True)
        with transaction.atomic():
            user = request.user.__class__.objects.select_for_update().get(
                pk=request.user.pk,
            )
            # Re-check against the locked row. The serializer's first check
            # gives the normal validation response, while this closes the
            # narrow window in which a concurrent password reset could change
            # the credential before deletion acquires its database lock.
            if not user.check_password(serializer.validated_data['password']):
                raise ValidationError(
                    {'password': ['The password is incorrect.']}
                )
            # A waitlist request is independent data but belongs to the same
            # person and must be erased with an account deletion request.
            WaitlistSubscriber.objects.filter(email__iexact=user.email).delete()
            OutstandingToken.objects.filter(user=user).delete()
            user.delete()
        return Response(status=status.HTTP_204_NO_CONTENT)


class UnverifiedAccountDeletionView(NoStoreResponseMixin, APIView):
    """Delete a password-proven pending account without revealing its state."""

    permission_classes = (AllowAny,)
    throttle_classes = (
        ScopedRateThrottle,
        UnverifiedAccountDeletionEmailRateThrottle,
    )
    throttle_scope = 'unverified_account_delete'

    @sensitive_variables()
    def delete(self, request):
        serializer = DeleteUnverifiedAccountSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        email = serializer.validated_data['email']
        password = serializer.validated_data['password']

        with transaction.atomic():
            user = (
                User.objects.select_for_update()
                .filter(
                    email=email,
                    is_active=True,
                    email_verified_at__isnull=True,
                )
                .first()
            )
            if user is None:
                # Match Django's nonexistent-user password work so the generic
                # response does not become a cheap account-state timing probe.
                dummy_user = User(email=email)
                dummy_user.set_password(password)
            elif user.check_password(password):
                OutstandingToken.objects.filter(user=user).delete()
                user.delete()

        # Wrong, verified, disabled, missing, and successfully deleted accounts
        # are deliberately indistinguishable to an unauthenticated caller.
        return Response(status=status.HTTP_204_NO_CONTENT)


class KidProfileViewSet(NoStoreResponseMixin, viewsets.ModelViewSet):
    serializer_class = KidProfileSerializer
    permission_classes = (IsAuthenticated,)
    lookup_field = 'id'

    def get_queryset(self):
        return KidProfile.objects.filter(parent=self.request.user)

    def get_throttles(self):
        throttles = list(super().get_throttles())
        if self.action in {'create', 'update', 'partial_update', 'destroy'}:
            self.throttle_scope = 'profile_write'
            throttles.append(ScopedRateThrottle())
        return throttles

    def create(self, request, *args, **kwargs):
        serializer = self.get_serializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        validated_data = serializer.validated_data
        with transaction.atomic():
            parent = request.user.__class__.objects.select_for_update().get(
                pk=request.user.pk,
            )
            profile = KidProfile.objects.filter(
                parent=parent,
                creation_operation_id=validated_data['creation_operation_id'],
            ).first()
            if profile is not None:
                if (
                    profile.display_name != validated_data['display_name']
                    or profile.avatar_key != validated_data['avatar_key']
                ):
                    return Response(
                        {
                            'detail': (
                                'operation_id was already used for a different '
                                'kid profile.'
                            )
                        },
                        status=status.HTTP_409_CONFLICT,
                    )
                created = False
            else:
                if KidProfile.objects.filter(parent=parent).count() >= (
                    settings.MAX_KID_PROFILES
                ):
                    raise ValidationError(
                        {
                            'detail': (
                                f'An account can have at most '
                                f'{settings.MAX_KID_PROFILES} kid profiles.'
                            )
                        }
                    )
                profile = KidProfile.objects.create(
                    parent=parent,
                    creation_operation_id=validated_data[
                        'creation_operation_id'
                    ],
                    display_name=validated_data['display_name'],
                    avatar_key=validated_data['avatar_key'],
                )
                created = True
        response_serializer = self.get_serializer(profile)
        response_status = (
            status.HTTP_201_CREATED if created else status.HTTP_200_OK
        )
        return Response(response_serializer.data, status=response_status)


class KidProfilePreferencesView(NoStoreResponseMixin, APIView):
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
