from django.urls import path

from .views import (
    KidActivityEventCreateView,
    KidProfileSummaryView,
    StreakPresentationClaimView,
)


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
    path(
        'kid-profiles/<uuid:profile_id>/streak-presentations/claim/',
        StreakPresentationClaimView.as_view(),
        name='streak-presentation-claim',
    ),
]
