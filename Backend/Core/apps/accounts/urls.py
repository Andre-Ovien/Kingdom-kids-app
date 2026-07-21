from django.urls import include, path
from rest_framework.routers import DefaultRouter

from .views import (
    EmailVerificationConfirmView,
    EmailVerificationResendView,
    KidProfilePreferencesView,
    KidProfileViewSet,
    LoginView,
    LogoutView,
    MeView,
    RefreshView,
    RegisterView,
)

app_name = 'accounts'

router = DefaultRouter()
router.register('kid-profiles', KidProfileViewSet, basename='kid-profile')

urlpatterns = [
    path('register/', RegisterView.as_view(), name='register'),
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
    path('token/refresh/', RefreshView.as_view(), name='token-refresh'),
    path('logout/', LogoutView.as_view(), name='logout'),
    path('me/', MeView.as_view(), name='me'),
    path(
        'kid-profiles/<uuid:profile_id>/preferences/',
        KidProfilePreferencesView.as_view(),
        name='kid-profile-preferences',
    ),
    path('', include(router.urls)),
]
