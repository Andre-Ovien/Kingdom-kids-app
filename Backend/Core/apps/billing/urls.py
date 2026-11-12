from django.urls import include, path
from .access_status import ParentContentAccessView

from .views import (SquareCheckoutCancelView, SquareCheckoutConfirmView, SquareCheckoutIntentsView,
                    SquareCheckoutPrepareCardView, SquareCheckoutStatusView,
                    SquareCheckoutRestartView, SquareSandboxWebhookView)

urlpatterns = [
    path('', include('apps.billing.handoff_urls')),
    path('content-access/', ParentContentAccessView.as_view(), name='parent-content-access'),
    path('square/webhook/', SquareSandboxWebhookView.as_view(), name='square-sandbox-webhook'),
    path('square/checkout-intents/', SquareCheckoutIntentsView.as_view(), name='square-checkout-intents'),
    path('square/checkout-intents/<uuid:intent_id>/', SquareCheckoutStatusView.as_view(), name='square-checkout-status'),
    path('square/checkout-intents/<uuid:intent_id>/confirm/', SquareCheckoutConfirmView.as_view(), name='square-checkout-confirm'),
    path('square/checkout-intents/<uuid:intent_id>/prepare-card/', SquareCheckoutPrepareCardView.as_view(), name='square-checkout-prepare-card'),
    path('square/checkout-intents/<uuid:intent_id>/cancel/', SquareCheckoutCancelView.as_view(), name='square-checkout-cancel'),
    path('square/checkout-intents/<uuid:intent_id>/restart/', SquareCheckoutRestartView.as_view(), name='square-checkout-restart'),
]
