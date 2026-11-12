"""Explicit unavailable-mail capability, independent of debug/auth shortcuts."""
from django.conf import settings
from rest_framework.exceptions import APIException


class EmailDeliveryUnavailable(APIException):
    status_code = 503
    default_code = 'email_unavailable'

    def __init__(self):
        super().__init__({
            'code': 'email_unavailable',
            'detail': 'Email-dependent account actions are temporarily unavailable. Please try again later.',
        })


def require_email_delivery():
    if getattr(settings, 'EMAIL_DELIVERY_ENABLED', True) is not True:
        raise EmailDeliveryUnavailable()


class EmailDependentViewMixin:
    """Reject before parsing, validation, credential checks or account writes."""

    def initial(self, request, *args, **kwargs):
        require_email_delivery()
        return super().initial(request, *args, **kwargs)
