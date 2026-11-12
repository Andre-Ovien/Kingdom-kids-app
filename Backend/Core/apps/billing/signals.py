from django.conf import settings
from django.db.models.signals import pre_delete
from django.dispatch import receiver
from django.views.decorators.debug import sensitive_variables

from .cancellation import enqueue_account_cancellations


@receiver(pre_delete, sender=settings.AUTH_USER_MODEL, dispatch_uid='square-retain-renewal-cancellation')
@sensitive_variables()
def retain_square_cancellation_before_account_cascade(sender, instance, **kwargs):
    enqueue_account_cancellations(instance)
