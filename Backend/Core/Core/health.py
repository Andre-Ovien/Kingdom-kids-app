import logging
from uuid import uuid4

from django.core.cache import cache
from django.db import connection
from django.http import JsonResponse
from django.views.decorators.cache import never_cache
from django.views.decorators.http import require_GET


logger = logging.getLogger(__name__)


@require_GET
@never_cache
def live(_request):
    """Process liveness probe. It deliberately does not touch dependencies."""

    return JsonResponse({'status': 'ok'})


@require_GET
@never_cache
def ready(_request):
    """Dependency readiness probe without exposing infrastructure details."""

    cache_key = f'health:ready:{uuid4()}'
    try:
        with connection.cursor() as cursor:
            cursor.execute('SELECT 1')
            if cursor.fetchone() != (1,):
                raise RuntimeError('Unexpected database readiness result.')

        cache.set(cache_key, 'ok', timeout=10)
        if cache.get(cache_key) != 'ok':
            raise RuntimeError('Unexpected cache readiness result.')
    except Exception:
        logger.warning('Readiness dependency check failed.')
        return JsonResponse({'status': 'unavailable'}, status=503)
    finally:
        try:
            cache.delete(cache_key)
        except Exception:
            # The response above already reports dependency failure. Cleanup
            # must not replace it with a debug page when the cache is down.
            logger.warning('Readiness cache cleanup failed.')

    return JsonResponse({'status': 'ok'})
