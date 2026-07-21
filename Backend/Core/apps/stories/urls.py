from rest_framework.routers import SimpleRouter

from .views import StoryViewSet

app_name = 'stories'

router = SimpleRouter()
router.register('', StoryViewSet, basename='story')

urlpatterns = router.urls
