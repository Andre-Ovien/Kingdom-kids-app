from rest_framework.routers import SimpleRouter

from .views import GameViewSet

app_name = 'games'

router = SimpleRouter()
router.register('', GameViewSet, basename='game')

urlpatterns = router.urls
