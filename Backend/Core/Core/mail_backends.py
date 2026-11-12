"""A disabled mail backend must never claim delivery, inspect content or log it."""
from django.core.mail.backends.base import BaseEmailBackend
from django.views.decorators.debug import sensitive_variables


class EmailDeliveryDisabled(RuntimeError):
    pass


class DisabledEmailBackend(BaseEmailBackend):
    def open(self):
        raise EmailDeliveryDisabled('Email delivery is disabled.')

    @sensitive_variables()
    def send_messages(self, email_messages):
        # Even fail_silently=True cannot turn an explicit unavailable capability
        # into apparent delivery. Do not iterate/repr the message collection.
        raise EmailDeliveryDisabled('Email delivery is disabled.')

    def close(self):
        return None
