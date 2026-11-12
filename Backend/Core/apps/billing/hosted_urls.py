from django.urls import path
from .hosted_views import HostedQuoteView,HostedAuthorizeView,HostedPrepareView,HostedStatusView,HostedReconcileView,HostedCancelView
urlpatterns=[path('quote/',HostedQuoteView.as_view()),path('authorize/',HostedAuthorizeView.as_view()),
 path('prepare/',HostedPrepareView.as_view()),path('attempts/<uuid:attempt_id>/status/',HostedStatusView.as_view()),
 path('attempts/<uuid:attempt_id>/reconcile/',HostedReconcileView.as_view()),path('attempts/<uuid:attempt_id>/cancel/',HostedCancelView.as_view())]
