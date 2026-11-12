from django.urls import include, path
from rest_framework.routers import DefaultRouter

from .views import (
    AccountDeletionConfirmView,
    AccountDeletionRequestView,
    EmailVerificationConfirmView,
    EmailVerificationResendView,
    KidProfilePreferencesView,
    KidProfileViewSet,
    LoginView,
    LogoutView,
    MeView,
    PasswordResetConfirmView,
    PasswordResetRequestView,
    PasswordResetVerifyView,
    RefreshView,
    RegisterView,
    UnverifiedAccountDeletionView,
    WaitlistSignupView,
)

app_name = 'accounts'

router = DefaultRouter()
router.register('kid-profiles', KidProfileViewSet, basename='kid-profile')

urlpatterns = [
    path('register/', RegisterView.as_view(), name='register'),
    path('waitlist/', WaitlistSignupView.as_view(), name='waitlist'),
    path(
        'email-verification/confirm/',
        EmailVerificationConfirmView.as_view(),
        name='email-verification-confirm',
    ),
    path(
        'email-verification/resend/',
        EmailVerificationResendView.as_view(),
        name='email-verification-resend',
    ),
    path('login/', LoginView.as_view(), name='login'),
    path(
        'password-reset/request/',
        PasswordResetRequestView.as_view(),
        name='password-reset-request',
    ),
    path(
        'password-reset/verify/',
        PasswordResetVerifyView.as_view(),
        name='password-reset-verify',
    ),
    path(
        'password-reset/confirm/',
        PasswordResetConfirmView.as_view(),
        name='password-reset-confirm',
    ),
    path(
        'account-deletion/request/',
        AccountDeletionRequestView.as_view(),
        name='account-deletion-request',
    ),
    path(
        'account-deletion/confirm/',
        AccountDeletionConfirmView.as_view(),
        name='account-deletion-confirm',
    ),
    path('token/refresh/', RefreshView.as_view(), name='token-refresh'),
    path('logout/', LogoutView.as_view(), name='logout'),
    path('me/', MeView.as_view(), name='me'),
    path(
        'unverified-account/',
        UnverifiedAccountDeletionView.as_view(),
        name='unverified-account-delete',
    ),
    path(
        'kid-profiles/<uuid:profile_id>/preferences/',
        KidProfilePreferencesView.as_view(),
        name='kid-profile-preferences',
    ),
    path('', include(router.urls)),
]
