from django.urls import path

from .views import KidActivityEventCreateView, KidProfileSummaryView


app_name = 'progress'

urlpatterns = [
    path(
        'kid-profiles/<uuid:profile_id>/activity-events/',
        KidActivityEventCreateView.as_view(),
        name='kid-activity-event-create',
    ),
    path(
        'kid-profiles/<uuid:profile_id>/summary/',
        KidProfileSummaryView.as_view(),
        name='kid-profile-summary',
    ),
]
