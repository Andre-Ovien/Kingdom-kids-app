from django.conf import settings
from django.conf.urls.static import static
from django.contrib import admin
from django.urls import include, path

urlpatterns = [
    path('admin/', admin.site.urls),
    path('api/accounts/', include('apps.accounts.urls')),
    path('api/stories/', include('apps.stories.urls')),
    path('api/videos/', include('apps.videos.urls')),
    path('api/games/', include('apps.games.urls')),
    path('api/progress/', include('apps.progress.urls')),
    path('api/bible/', include('apps.bible.urls')),
]

if settings.DEBUG:
    urlpatterns += static(settings.MEDIA_URL, document_root=settings.MEDIA_ROOT)
