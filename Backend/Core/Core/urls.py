from django.conf import settings
from django.conf.urls.static import static
from django.contrib import admin
from django.urls import include, path

from .health import live, ready
from apps.billing.parent_checkout_web import parent_checkout

urlpatterns = [
    path('parent/checkout/', parent_checkout, name='parent-checkout'),
    path('health/live/', live, name='health-live'),
    path('health/ready/', ready, name='health-ready'),
    path('admin/', admin.site.urls),
    path('api/accounts/', include('apps.accounts.urls')),
    path('api/stories/', include('apps.stories.urls')),
    path('api/videos/', include('apps.videos.urls')),
    path('api/games/', include('apps.games.urls')),
    path('api/progress/', include('apps.progress.urls')),
    path('api/bible/', include('apps.bible.urls')),
    path('api/billing/', include('apps.billing.urls')),
]

if settings.DEBUG:
    urlpatterns += static(settings.MEDIA_URL, document_root=settings.MEDIA_ROOT)
