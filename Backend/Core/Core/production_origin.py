"""Keep the platform hostname health-only for the pinned custom release origin."""
from django.conf import settings
from django.http import HttpResponse


PRODUCTION_CUSTOM_HOST = 'api.kingdom-kids.app'
PRODUCTION_CUSTOM_ORIGIN = 'https://' + PRODUCTION_CUSTOM_HOST
HEALTH_PATHS = frozenset({'/health/live/', '/health/ready/'})


class ProductionOriginMiddleware:
    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        if (getattr(settings, 'SQUARE_ENVIRONMENT', 'sandbox') == 'production'
                and getattr(settings, 'PARENT_CHECKOUT_ORIGIN', '') == PRODUCTION_CUSTOM_ORIGIN):
            # get_host still enforces Django's exact ALLOWED_HOSTS. In custom
            # mode the Render alias may serve only the two platform probes.
            host = request.get_host()
            if host not in {PRODUCTION_CUSTOM_HOST, PRODUCTION_CUSTOM_HOST + ':443'} and request.path not in HEALTH_PATHS:
                response = HttpResponse(status=404)
                response['Cache-Control'] = 'no-store'
                return response
        return self.get_response(request)
