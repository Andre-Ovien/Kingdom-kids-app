from rest_framework_simplejwt.authentication import JWTAuthentication
from rest_framework_simplejwt.exceptions import AuthenticationFailed


class VerifiedEmailJWTAuthentication(JWTAuthentication):
    """Reject bearer tokens when the parent no longer has a verified email."""

    def get_user(self, validated_token):
        user = super().get_user(validated_token)
        if not user.is_email_verified:
            raise AuthenticationFailed(
                'Email verification is required.',
                code='email_verification_required',
            )
        return user
