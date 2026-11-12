"""Opt-in, allowlisted private media URLs; never uploads or stores signed URLs.

The deployment map contains immutable public IDs and verified byte identities,
not credentials or delivery URLs. All network work remains in the media client.
"""
from functools import lru_cache
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import time
from urllib.parse import urlencode

from django.conf import settings
from django.core.exceptions import ImproperlyConfigured
from django.utils.cache import patch_cache_control
from django.views.decorators.debug import sensitive_variables

_SHA = re.compile(r'[0-9a-f]{64}\Z')
_PUBLIC_ID = re.compile(r'kingdom-kids/media-v1/sha256-([0-9a-f]{64})(?:\.[a-z0-9]+)?\Z')
_CLOUD = re.compile(r'[a-z0-9][a-z0-9_-]{0,62}\Z')
_FORMAT = re.compile(r'[a-z0-9]{1,12}\Z')
_MAX_MAP_BYTES = 1_048_576


def delivery_enabled():
    return bool(getattr(settings, 'CLOUDINARY_PRIVATE_DELIVERY_ENABLED', False))


def canonical_source_path(value):
    """Only exact repository aliases; never decode or normalize caller input."""
    if not isinstance(value, str) or not value or len(value) > 400:
        return None
    if any(character in value for character in ('\\', '%', '?', '#', '\x00')):
        return None
    path = PurePosixPath(value)
    if (str(path) != value or path.is_absolute()
            or any(part in {'', '.', '..'} for part in value.split('/'))):
        return None
    if not value.startswith(('Frontend/mobile/assets/', 'Backend/media/')):
        return None
    return value


@lru_cache(maxsize=4)
def _load_map(filename, expected_sha256):
    if not isinstance(expected_sha256, str) or not _SHA.fullmatch(expected_sha256):
        raise ImproperlyConfigured('Private media requires a pinned release map SHA256.')
    try:
        descriptor = os.open(Path(filename), os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0))
        with os.fdopen(descriptor, 'rb') as source:
            payload = source.read(_MAX_MAP_BYTES + 1)
        if len(payload) > _MAX_MAP_BYTES or hashlib.sha256(payload).hexdigest() != expected_sha256:
            raise ValueError
        data = json.loads(payload)
        if (not isinstance(data, dict)
                or data.get('schema_version') != 1 or data.get('scope') != 'first_release_only'
                or data.get('remote_originals_verified') is not True
                or not _CLOUD.fullmatch(data.get('cloud_name', ''))
                or not isinstance(data.get('assets'), dict)
                or not 1 <= len(data['assets']) <= 1000):
            raise ValueError
        for alias, item in data['assets'].items():
            if canonical_source_path(alias) is None or not isinstance(item, dict):
                raise ValueError
            match = _PUBLIC_ID.fullmatch(item.get('public_id', ''))
            if (not match or match.group(1) != item.get('sha256')
                    or item.get('type') != 'authenticated'
                    or item.get('resource_type') not in {'image', 'video', 'raw'}
                    or not _FORMAT.fullmatch(item.get('format', ''))
                    or type(item.get('bytes')) is not int or item['bytes'] <= 0
                    or not isinstance(item.get('uses'), list) or not item['uses']
                    or not all(isinstance(use, str) and len(use) <= 300 for use in item['uses'])):
                raise ValueError
        return data
    except (OSError, ValueError, TypeError, KeyError):
        raise ImproperlyConfigured('Private media release map is missing or invalid.') from None


def _request_can_sign(request):
    user = getattr(request, 'user', None)
    return bool(request is not None and user is not None
                and user.is_authenticated and user.is_active and user.is_email_verified)


@sensitive_variables()
def private_media_url(request, source_path, *, use, now=None):
    """Sign only an exact approved alias/use for an authorized API response.

    This is not a media endpoint and performs no provider requests. Endpoint
    authorization still owns paid access and (for games) child ownership.
    """
    if not delivery_enabled() or not _request_can_sign(request):
        return None
    alias = canonical_source_path(source_path)
    if alias is None or not isinstance(use, str):
        return None
    release = _load_map(str(settings.CLOUDINARY_PRIVATE_MEDIA_MAP), settings.CLOUDINARY_PRIVATE_MEDIA_MAP_SHA256)
    item = release['assets'].get(alias)
    if item is None or use not in item['uses']:
        return None
    cloud = settings.CLOUDINARY_CLOUD_NAME
    api_key = settings.CLOUDINARY_API_KEY
    api_secret = settings.CLOUDINARY_API_SECRET
    ttl = settings.CLOUDINARY_PRIVATE_URL_TTL_SECONDS
    if (not isinstance(cloud, str) or not _CLOUD.fullmatch(cloud)
            or cloud != release['cloud_name']
            or not isinstance(api_key, str) or not re.fullmatch(r'[0-9]{6,64}', api_key)
            or not isinstance(api_secret, str) or not 16 <= len(api_secret) <= 200
            or any(character.isspace() for character in api_secret)
            or type(ttl) is not int or not 30 <= ttl <= 900
            or 'api.cloudinary.com' not in settings.CONTENT_MEDIA_HOSTS):
        raise ImproperlyConfigured('Private media server configuration is incomplete.')
    timestamp = int(time.time() if now is None else now)
    expires_at = timestamp + ttl
    if settings.PAID_CONTENT_ENFORCEMENT_ENABLED:
        # A verified access deadline must be supplied by the billing guard;
        # latest subscription/provider calendar guesses are never accepted.
        if not hasattr(request, '_paid_content_media_until'):
            from apps.billing.permissions import paid_content_access_until
            request._paid_content_media_until = paid_content_access_until(
                request.user, at=datetime.fromtimestamp(timestamp, timezone.utc),
            )
        deadline = request._paid_content_media_until
        if deadline is None:
            return None
        expires_at = min(expires_at, int(deadline.timestamp()))
        if expires_at <= timestamp:
            return None
    params = {
        'timestamp': timestamp,
        'public_id': item['public_id'],
        'format': item['format'],
        'type': 'authenticated',
        'expires_at': expires_at,
    }
    # Cloudinary SDK signature version 2: sorted final parameters, escaping '&'
    # before joining. API key is deliberately excluded; secret is only appended
    # to the hash input. No transformation or arbitrary URL parameter is allowed.
    signed = '&'.join(sorted(f'{key}={value}'.replace('&', '%26') for key, value in params.items()))
    params['signature'] = hashlib.sha256((signed + api_secret).encode('utf-8')).hexdigest()
    params['api_key'] = api_key
    query = urlencode(params)
    url = f'https://api.cloudinary.com/v1_1/{cloud}/{item["resource_type"]}/download?{query}'
    request._private_media_signed = True
    # DRF serializers receive a Request wrapper; Django middleware observes its
    # underlying HttpRequest after the view returns.
    getattr(request, '_request', request)._private_media_signed = True
    return url


class PrivateMediaNoStoreMiddleware:
    """Do not cache API responses containing short-lived bearer media URLs."""
    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        path = getattr(request, 'path', '')
        if delivery_enabled() and any(
            path == prefix or path.startswith(prefix + '/')
            for prefix in ('/api/stories', '/api/games')
        ):
            return self._private_response(request)
        return self._response(request)

    @sensitive_variables()
    def _private_response(self, request):
        # Includes view/DRF list/renderer ancestors holding earlier signed
        # fields if a later field fails. Default-OFF requests are unaffected.
        return self._response(request)

    def _response(self, request):
        response = self.get_response(request)
        if getattr(request, '_private_media_signed', False):
            patch_cache_control(response, private=True, no_store=True, max_age=0)
            response['Pragma'] = 'no-cache'
            response['Expires'] = '0'
        return response
