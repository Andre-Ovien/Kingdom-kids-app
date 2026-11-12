import hashlib
import hmac
from collections.abc import Mapping

from django.conf import settings
from rest_framework.throttling import SimpleRateThrottle

from .models import User


class NormalizedEmailRateThrottle(SimpleRateThrottle):
    """Rate-limit one normalized email without placing PII in cache keys."""

    email_field = 'email'

    def get_cache_key(self, request, view):
        # JSON may contain an array, scalar, or null. Let the endpoint's
        # serializer return its normal 400 instead of failing before validation.
        if not isinstance(request.data, Mapping):
            return None
        raw_email = request.data.get(self.email_field)
        if not isinstance(raw_email, str) or not raw_email.strip():
            return None
        normalized = User.objects.normalize_email(raw_email)
        digest = hmac.new(
            settings.SECRET_KEY.encode(),
            normalized.encode(),
            hashlib.sha256,
        ).hexdigest()
        return self.cache_format % {
            'scope': self.scope,
            'ident': digest,
        }


class RegistrationEmailRateThrottle(NormalizedEmailRateThrottle):
    scope = 'registration_email'


class LoginEmailRateThrottle(NormalizedEmailRateThrottle):
    scope = 'login_email'


class PasswordResetEmailRateThrottle(NormalizedEmailRateThrottle):
    scope = 'password_reset_email'


class AccountDeletionEmailRateThrottle(NormalizedEmailRateThrottle):
    scope = 'account_deletion_email'


class UnverifiedAccountDeletionEmailRateThrottle(NormalizedEmailRateThrottle):
    scope = 'unverified_account_delete'
