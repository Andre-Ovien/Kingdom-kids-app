from django.urls import path
from .handoff_views import CheckoutHandoffIssueView, CheckoutHandoffRedeemView, CheckoutHandoffRevokeView

urlpatterns = [
    path('checkout-handoffs/', CheckoutHandoffIssueView.as_view(), name='checkout-handoff-issue'),
    path('checkout-handoffs/redeem/', CheckoutHandoffRedeemView.as_view(), name='checkout-handoff-redeem'),
    path('checkout-handoffs/revoke/', CheckoutHandoffRevokeView.as_view(), name='checkout-handoff-revoke'),
]
