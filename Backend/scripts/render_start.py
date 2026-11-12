"""Render startup: strict settings, explicit billing qualification, then Gunicorn.

No credentials are generated locally or printed. Render's independently generated
256-bit seeds are expanded to meet the application's existing string-length rules.
"""
import base64
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import time

BACKEND = Path(__file__).resolve().parents[1]
PRIVATE_MEDIA_MAP = BACKEND / 'content/releases/cloudinary_first_release_v1.json'
PRIVATE_MEDIA_MAP_SHA256 = '70e57ac281c330383db3e3a8c899c80d1816a41f400dae6a9a269b46c6436876'
MIGRATION_LOCK = 54255181082000
DISABLED_FLAGS = (
    'SQUARE_SANDBOX_ENABLED', 'SQUARE_SANDBOX_CHECKOUT_ENABLED',
    'SQUARE_SANDBOX_RECONCILIATION_ENABLED', 'SQUARE_SANDBOX_CANCELLATION_ENABLED',
    'SQUARE_SANDBOX_TERM_BILLING_ENABLED', 'SQUARE_SANDBOX_TERM_RECONCILIATION_ENABLED',
    'SQUARE_SANDBOX_HTTP_TRANSPORT_ENABLED', 'PAID_CONTENT_ENFORCEMENT_ENABLED',
    'PARENT_CHECKOUT_SANDBOX_ENABLED', 'PARENT_CONTENT_ACCESS_STATUS_ENABLED',
)
SANDBOX_QUALIFICATION_HOST = 'kingdom-kids-checkout-staging.onrender.com'
PRODUCTION_CUSTOM_HOST = 'api.kingdom-kids.app'
PRODUCTION_CUSTOM_ORIGIN = 'https://' + PRODUCTION_CUSTOM_HOST
SANDBOX_QUALIFICATION_FLAGS = (
    'SQUARE_SANDBOX_ENABLED', 'SQUARE_SANDBOX_TERM_BILLING_ENABLED',
    'SQUARE_SANDBOX_TERM_RECONCILIATION_ENABLED', 'SQUARE_SANDBOX_HTTP_TRANSPORT_ENABLED',
    'PARENT_CHECKOUT_SANDBOX_ENABLED', 'PARENT_CONTENT_ACCESS_STATUS_ENABLED',
)
PRODUCTION_ONLY_FLAGS = (
    'SQUARE_PRODUCTION_ENABLED', 'SQUARE_PRODUCTION_CHECKOUT_ENABLED',
    'SQUARE_PRODUCTION_TERM_BILLING_ENABLED', 'SQUARE_PRODUCTION_TERM_RECONCILIATION_ENABLED',
    'SQUARE_PRODUCTION_HTTP_TRANSPORT_ENABLED', 'SQUARE_PRODUCTION_RELEASE_QUALIFIED',
    'SQUARE_PRODUCTION_RENEWALS_ENABLED', 'PARENT_CHECKOUT_PRODUCTION_ENABLED',
    'SQUARE_PRODUCTION_RECONCILIATION_JOBS_ENABLED', 'SQUARE_PRODUCTION_RENEWAL_JOBS_ENABLED',
)
SANDBOX_ONLY_FLAGS = tuple(flag for flag in DISABLED_FLAGS if flag not in {
    'PAID_CONTENT_ENFORCEMENT_ENABLED', 'PARENT_CONTENT_ACCESS_STATUS_ENABLED'}) + (
    'SQUARE_SANDBOX_RECONCILIATION_JOBS_ENABLED', 'SQUARE_SANDBOX_RENEWAL_JOBS_ENABLED',
)
PRODUCTION_QUALIFICATION_FLAGS = PRODUCTION_ONLY_FLAGS + (
    'PAID_CONTENT_ENFORCEMENT_ENABLED', 'PARENT_CONTENT_ACCESS_STATUS_ENABLED',
    'PARENT_CHECKOUT_HANDOFF_ENABLED', 'DJANGO_EMAIL_DELIVERY_ENABLED',
    'CLOUDINARY_PRIVATE_DELIVERY_ENABLED',
)
CONTROLLED_PRODUCTION_FLAGS = (
    'SQUARE_PRODUCTION_ENABLED', 'SQUARE_PRODUCTION_CHECKOUT_ENABLED',
    'SQUARE_PRODUCTION_TERM_BILLING_ENABLED', 'SQUARE_PRODUCTION_TERM_RECONCILIATION_ENABLED',
    'SQUARE_PRODUCTION_HTTP_TRANSPORT_ENABLED', 'PARENT_CHECKOUT_PRODUCTION_ENABLED',
    'PARENT_CONTENT_ACCESS_STATUS_ENABLED', 'SQUARE_PRODUCTION_CONTROLLED_CHECKOUT_ENABLED',
    'DJANGO_EMAIL_DELIVERY_ENABLED', 'CLOUDINARY_PRIVATE_DELIVERY_ENABLED',
)
CONTROLLED_PRODUCTION_DISABLED_FLAGS = (
    'RENDER_PRODUCTION_CHECKOUT_QUALIFICATION_ENABLED', 'RENDER_PRODUCTION_OPERATIONS_QUALIFIED',
    'RENDER_PRODUCTION_CUSTOM_DOMAIN_VERIFIED', 'SQUARE_PRODUCTION_RELEASE_QUALIFIED',
    'PAID_CONTENT_ENFORCEMENT_ENABLED', 'SQUARE_PRODUCTION_RENEWALS_ENABLED',
    'SQUARE_PRODUCTION_RECONCILIATION_JOBS_ENABLED', 'SQUARE_PRODUCTION_RENEWAL_JOBS_ENABLED',
)
SANDBOX_CONFIGURATION_SLOTS = (
    'SQUARE_SANDBOX_ACCESS_TOKEN', 'SQUARE_SANDBOX_MERCHANT_ID', 'SQUARE_SANDBOX_LOCATION_ID',
    'SQUARE_SANDBOX_APPLICATION_ID', 'SQUARE_SANDBOX_WEBHOOK_SIGNATURE_KEY',
    'SQUARE_SANDBOX_WEBHOOK_NOTIFICATION_URL', 'SQUARE_SANDBOX_PLAN_VARIATION_ID',
    'SQUARE_SANDBOX_TEST_PARENT_IDS',
)
SANDBOX_IMPORT_SLOTS = (
    'KK_TEST_FAMILY_IMPORT_ZLIB_B64', 'KK_TEST_FAMILY_IMPORT_SHA256', 'KK_TEST_FAMILY_IMPORT_EMAIL',
    'KK_SANDBOX_TEST_PARENT_LOOKUP_EMAIL',
)


class StartupRejected(RuntimeError):
    pass


def _production_origin_matches(environ):
    host = environ.get('RENDER_EXTERNAL_HOSTNAME', '')
    if not isinstance(host, str) or not re.fullmatch(r'[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.onrender\.com', host):
        return False
    label = host.removesuffix('.onrender.com')
    placeholder_words = ('example', 'placeholder', 'replace', 'changeme', 'your')
    if (len(label) > 63 or label in {'localhost', 'test'}
            or any(word in label.split('-') for word in placeholder_words)):
        return False
    custom_verified = environ.get('RENDER_PRODUCTION_CUSTOM_DOMAIN_VERIFIED', 'false')
    if environ.get('RENDER_PRODUCTION_APPROVED_ORIGIN') == PRODUCTION_CUSTOM_ORIGIN:
        hosts = environ.get('DJANGO_ALLOWED_HOSTS', '').split(',')
        return (custom_verified == 'true' and len(hosts) == 2
            and set(hosts) == {host, PRODUCTION_CUSTOM_HOST}
            and environ.get('PARENT_CHECKOUT_ORIGIN') == PRODUCTION_CUSTOM_ORIGIN
            and environ.get('SQUARE_PRODUCTION_WEBHOOK_NOTIFICATION_URL') ==
                PRODUCTION_CUSTOM_ORIGIN + '/api/billing/square/webhook/')
    if custom_verified != 'false' or host == SANDBOX_QUALIFICATION_HOST:
        return False
    if (label in {'example', 'localhost', 'production', 'staging', 'sandbox', 'test'}
            or any(word in label.split('-') for word in ('example', 'placeholder', 'replace', 'changeme', 'your', 'sandbox', 'staging'))):
        return False
    origin = 'https://' + host
    return (environ.get('RENDER_PRODUCTION_APPROVED_ORIGIN') == origin
            and environ.get('PARENT_CHECKOUT_ORIGIN') == origin
            and environ.get('DJANGO_ALLOWED_HOSTS', host) == host
            and environ.get('SQUARE_PRODUCTION_WEBHOOK_NOTIFICATION_URL') == origin + '/api/billing/square/webhook/')


def production_checkout_checks(environ):
    """Pure, redacted configuration checks; no provider/DB/runtime readiness claim."""
    def credential(name, minimum, maximum):
        value = environ.get(name, '')
        return (isinstance(value, str) and minimum <= len(value) <= maximum and value.isascii()
                and not value.lower().startswith('sandbox')
                and all(32 < ord(char) < 127 for char in value))
    application = environ.get('SQUARE_PRODUCTION_APPLICATION_ID', '')
    return {
        'production_startup_opt_in': environ.get('RENDER_PRODUCTION_CHECKOUT_QUALIFICATION_ENABLED') == 'true',
        'production_release_and_billing_flags': all(environ.get(flag) == 'true' for flag in PRODUCTION_QUALIFICATION_FLAGS),
        'production_environment_and_entitlement': (environ.get('SQUARE_ENVIRONMENT') == 'production'
            and environ.get('PAID_CONTENT_ENTITLEMENT_ENVIRONMENT') == 'production'),
        'custom_domain_attestation': environ.get('RENDER_PRODUCTION_CUSTOM_DOMAIN_VERIFIED', 'false') == (
            'true' if environ.get('RENDER_PRODUCTION_APPROVED_ORIGIN') == PRODUCTION_CUSTOM_ORIGIN else 'false'),
        'approved_same_origin_and_callback': _production_origin_matches(environ),
        'reviewed_provider_api_version': environ.get('SQUARE_API_VERSION', '2026-09-16') == '2026-09-16',
        'production_public_application_id': isinstance(application, str)
            and re.fullmatch(r'sq0id[pb]-[A-Za-z0-9_-]{8,160}', application) is not None,
        'production_credential_shapes': all(credential(*item) for item in (
            ('SQUARE_PRODUCTION_ACCESS_TOKEN', 16, 4096), ('SQUARE_PRODUCTION_MERCHANT_ID', 1, 192),
            ('SQUARE_PRODUCTION_LOCATION_ID', 1, 192), ('SQUARE_PRODUCTION_WEBHOOK_SIGNATURE_KEY', 16, 512))),
        'sandbox_flags_disabled': environ.get('RENDER_SANDBOX_CHECKOUT_QUALIFICATION_ENABLED', 'false') == 'false'
            and all(environ.get(flag, 'false') == 'false' for flag in SANDBOX_ONLY_FLAGS),
        'sandbox_configuration_absent': all(environ.get(name, '') == '' for name in SANDBOX_CONFIGURATION_SLOTS)
            and not any(name in environ for name in SANDBOX_IMPORT_SLOTS),
        'reviewed_render_proxy': environ.get('DJANGO_TRUST_X_FORWARDED_PROTO') == 'true'
            and environ.get('DJANGO_API_NUM_PROXIES') == '1',
        'operations_explicitly_qualified': environ.get('RENDER_PRODUCTION_OPERATIONS_QUALIFIED') == 'true',
        'controlled_checkout_disabled': environ.get('RENDER_CONTROLLED_PRODUCTION_CHECKOUT_ENABLED', 'false') == 'false'
            and environ.get('SQUARE_PRODUCTION_CONTROLLED_CHECKOUT_ENABLED', 'false') == 'false'
            and environ.get('SQUARE_PRODUCTION_CONTROLLED_PARENT_IDS', '') == '',
    }


def _controlled_parent_ids_valid(value):
    if not isinstance(value, str) or not value.strip() or len(value) > 2100:
        return False
    identifiers = value.split(',')
    return len(identifiers) <= 100 and all(
        re.fullmatch(r'[1-9][0-9]{0,18}', item.strip()) is not None
        and int(item.strip()) <= 9223372036854775807 for item in identifiers)


def controlled_production_checkout_checks(environ):
    """Enrolled, nonrenewing production checkout on the existing Free service.

    No hosting-plan assertion or public-release qualification is inferred. The
    core independently enforces enrollment and permanently nonrenewing terms.
    """
    base = production_checkout_checks(environ)
    origin = 'https://' + SANDBOX_QUALIFICATION_HOST
    return {
        'controlled_startup_opt_in': environ.get('RENDER_CONTROLLED_PRODUCTION_CHECKOUT_ENABLED') == 'true',
        'controlled_checkout_and_security_flags': all(environ.get(flag) == 'true' for flag in CONTROLLED_PRODUCTION_FLAGS),
        'bounded_explicit_parent_enrollment': _controlled_parent_ids_valid(environ.get('SQUARE_PRODUCTION_CONTROLLED_PARENT_IDS')),
        'public_release_enforcement_jobs_and_renewals_disabled': all(
            environ.get(flag, 'false') == 'false' for flag in CONTROLLED_PRODUCTION_DISABLED_FLAGS),
        'exact_existing_https_origin_and_callback': (
            environ.get('RENDER_EXTERNAL_HOSTNAME') == SANDBOX_QUALIFICATION_HOST
            and environ.get('DJANGO_ALLOWED_HOSTS', SANDBOX_QUALIFICATION_HOST) == SANDBOX_QUALIFICATION_HOST
            and environ.get('PARENT_CHECKOUT_ORIGIN') == origin
            and environ.get('RENDER_PRODUCTION_APPROVED_ORIGIN', '') in {'', origin}
            and environ.get('SQUARE_PRODUCTION_WEBHOOK_NOTIFICATION_URL') == origin + '/api/billing/square/webhook/'),
        **{key: base[key] for key in (
            'production_environment_and_entitlement', 'reviewed_provider_api_version',
            'production_public_application_id', 'production_credential_shapes',
            'sandbox_flags_disabled', 'sandbox_configuration_absent', 'reviewed_render_proxy')},
    }


def qualify_controlled_production_checkout(environ):
    if not all(controlled_production_checkout_checks(environ).values()):
        raise StartupRejected('Controlled production checkout requires the exact existing HTTPS origin, enrolled parents, production configuration and disabled public-release, enforcement, jobs and renewal gates.')


def qualify_production_checkout(environ):
    if not all(production_checkout_checks(environ).values()):
        raise StartupRejected('Production checkout requires an approved isolated origin, complete production configuration and explicitly qualified billing operations.')


def qualify_checkout(environ):
    """Mutually exclusive, default-OFF exceptions to the original financial guard."""
    sandbox = environ.get('RENDER_SANDBOX_CHECKOUT_QUALIFICATION_ENABLED', 'false')
    production = environ.get('RENDER_PRODUCTION_CHECKOUT_QUALIFICATION_ENABLED', 'false')
    controlled = environ.get('RENDER_CONTROLLED_PRODUCTION_CHECKOUT_ENABLED', 'false')
    controlled_core = environ.get('SQUARE_PRODUCTION_CONTROLLED_CHECKOUT_ENABLED', 'false')
    operations = environ.get('RENDER_PRODUCTION_OPERATIONS_QUALIFIED', 'false')
    custom_verified = environ.get('RENDER_PRODUCTION_CUSTOM_DOMAIN_VERIFIED', 'false')
    handoff = environ.get('PARENT_CHECKOUT_HANDOFF_ENABLED', 'false')
    if any(not isinstance(value, str) or value not in {'true', 'false'}
            for value in (sandbox, production, controlled, controlled_core, operations, handoff, custom_verified)):
        raise StartupRejected('Checkout and operations qualification must be explicitly enabled or disabled.')
    if sum(value == 'true' for value in (sandbox, production, controlled)) > 1:
        raise StartupRejected('Checkout startup profiles must be mutually exclusive.')
    if controlled == 'true':
        qualify_controlled_production_checkout(environ)
        return
    if controlled_core != 'false' or environ.get('SQUARE_PRODUCTION_CONTROLLED_PARENT_IDS', '') != '':
        raise StartupRejected('Controlled checkout and enrollment must remain disabled without its explicit startup qualification.')
    if production == 'true':
        qualify_production_checkout(environ)
        return
    if operations != 'false' or custom_verified != 'false' or any(
            environ.get(flag, 'false') != 'false' for flag in PRODUCTION_ONLY_FLAGS):
        raise StartupRejected('Production billing and operations must remain disabled without explicit startup qualification.')
    if sandbox == 'false' and (handoff != 'false' or any(
            environ.get(flag, 'false') != 'false' for flag in SANDBOX_ONLY_FLAGS)):
        raise StartupRejected('Financial and checkout features must remain disabled without explicit qualification.')
    qualify_sandbox_checkout(environ)


def production_preflight_report(environ):
    """Offline contract only. Passing never establishes public release readiness.

    A copy may expand configured signing seeds during the unchanged local
    startup guards. The caller's environment and runtime gates are not changed.
    Original Django production checks, DB/cache readiness, backups, scheduler
    heartbeats and canonical provider qualification remain separate evidence.
    """
    controlled = environ.get('RENDER_CONTROLLED_PRODUCTION_CHECKOUT_ENABLED', 'false') != 'false'
    checks = controlled_production_checkout_checks(environ) if controlled else production_checkout_checks(environ)
    local_shape = False
    if all(checks.values()):
        try:
            prepare_environment(dict(environ))
            local_shape = True
        except (StartupRejected, ValueError, TypeError, OSError):
            pass
    checks['original_local_startup_guards'] = local_shape
    disabled_draft = all(environ.get(flag, 'false') == 'false' for flag in PRODUCTION_ONLY_FLAGS) and (
        environ.get('RENDER_PRODUCTION_CHECKOUT_QUALIFICATION_ENABLED', 'false') == 'false'
        and environ.get('RENDER_PRODUCTION_OPERATIONS_QUALIFIED', 'false') == 'false'
        and environ.get('RENDER_PRODUCTION_CUSTOM_DOMAIN_VERIFIED', 'false') == 'false'
        and environ.get('RENDER_CONTROLLED_PRODUCTION_CHECKOUT_ENABLED', 'false') == 'false'
        and environ.get('SQUARE_PRODUCTION_CONTROLLED_CHECKOUT_ENABLED', 'false') == 'false'
        and environ.get('SQUARE_PRODUCTION_CONTROLLED_PARENT_IDS', '') == '')
    return {'schema_version': 1, 'kind': 'offline_production_checkout_configuration',
        'profile': 'controlled_production' if controlled else 'full_public_production',
        'status': 'local_configuration_valid' if all(checks.values()) else 'disabled_draft' if disabled_draft else 'blocked',
        'local_configuration_valid': all(checks.values()), 'public_release_ready': False,
        'activation_performed': False, 'provider_operations': 0, 'database_operations': 0,
        'environment_mutations': 0, 'checks': checks,
        'custom_domain_dns_ca_proof': 'external_evidence_required_not_checked' if
            environ.get('RENDER_PRODUCTION_APPROVED_ORIGIN') == PRODUCTION_CUSTOM_ORIGIN else 'not_selected',
        'failed_checks': sorted(name for name, passed in checks.items() if not passed),
        'automatic_renewals_enabled': False if controlled else None,
        'scheduled_jobs_claimed': False if controlled else None,
        'runtime_qualification_required': [
            'original_django_production_checks', 'existing_database_and_cache_readiness',
            'canonical_production_merchant_and_location', 'signed_webhook_delivery',
            'explicit_parent_enrollment_and_manual_canonical_recovery',
            'nonrenewing_controlled_checkout_policy'] if controlled else [
            'original_django_production_checks', 'qualified_non_sleeping_hosting',
            'custom_domain_dns_mapping_and_certificate_if_selected',
            'durable_database_restore_test_and_cache', 'canonical_production_merchant_and_location',
            'signed_webhook_delivery_and_reconciliation', 'scheduled_reconciliation_and_renewal_heartbeats',
            'monitoring_and_incident_response', 'approved_mobile_storefront_release']}


def qualify_sandbox_checkout(environ):
    """A local config check for one explicitly authorized staging origin only.

    No SDK/provider calls or secret values in errors. Canonical account/location
    matching remains a separate provider qualification, never a startup claim.
    """
    opted_in = environ.get('RENDER_SANDBOX_CHECKOUT_QUALIFICATION_ENABLED', 'false')
    if opted_in not in {'true', 'false'}:
        raise StartupRejected('Sandbox checkout qualification must be explicitly enabled or disabled.')
    if opted_in == 'false':
        if any(environ.get(flag, 'false') != 'false' for flag in DISABLED_FLAGS):
            raise StartupRejected('Financial, paid enforcement and parent checkout features must stay disabled.')
        return
    try:
        origin = 'https://' + SANDBOX_QUALIFICATION_HOST
        if (environ.get('RENDER_EXTERNAL_HOSTNAME') != SANDBOX_QUALIFICATION_HOST
                or environ.get('PARENT_CHECKOUT_ORIGIN') != origin
                or environ.get('SQUARE_ENVIRONMENT') != 'sandbox'
                or environ.get('PAID_CONTENT_ENTITLEMENT_ENVIRONMENT') != 'sandbox'
                or environ.get('DJANGO_TRUST_X_FORWARDED_PROTO') != 'true'
                or environ.get('DJANGO_API_NUM_PROXIES') != '1'
                or environ.get('SQUARE_API_VERSION', '2026-09-16') != '2026-09-16'
                or any(environ.get(flag) != 'true' for flag in SANDBOX_QUALIFICATION_FLAGS)
                or any(environ.get(flag, 'false') != 'false' for flag in DISABLED_FLAGS
                       if flag not in SANDBOX_QUALIFICATION_FLAGS)
                or environ.get('SQUARE_SANDBOX_WEBHOOK_NOTIFICATION_URL') != origin + '/api/billing/square/webhook/'):
            raise ValueError
        application = environ.get('SQUARE_SANDBOX_APPLICATION_ID', '')
        if not isinstance(application, str) or not re.fullmatch(r'sandbox-[A-Za-z0-9_-]{8,160}', application):
            raise ValueError
        for name, minimum, maximum in (
            ('SQUARE_SANDBOX_ACCESS_TOKEN', 16, 4096),
            ('SQUARE_SANDBOX_MERCHANT_ID', 1, 192),
            ('SQUARE_SANDBOX_LOCATION_ID', 1, 192),
            ('SQUARE_SANDBOX_WEBHOOK_SIGNATURE_KEY', 16, 512),
        ):
            value = environ.get(name, '')
            if (not isinstance(value, str) or not minimum <= len(value) <= maximum
                    or not value.isascii() or any(ord(char) <= 32 or ord(char) == 127 for char in value)):
                raise ValueError
        # Match the application enrollment parser without loading Django before
        # its original production settings checks have run.
        raw_ids = environ.get('SQUARE_SANDBOX_TEST_PARENT_IDS', '')
        if not isinstance(raw_ids, str) or not raw_ids.strip() or len(raw_ids) > 2100:
            raise ValueError
        identifiers = raw_ids.split(',')
        if len(identifiers) > 100:
            raise ValueError
        for identifier in identifiers:
            identifier = identifier.strip()
            if (not re.fullmatch(r'[1-9][0-9]{0,18}', identifier)
                    or int(identifier) > 9223372036854775807):
                raise ValueError
    except (ValueError, TypeError, AttributeError):
        raise StartupRejected('Sandbox checkout qualification requires the exact approved staging origin, enrolled test parents and complete Sandbox configuration.') from None


def qualify_private_media(environ):
    """Check the exact shipped map/config locally; never contact the provider."""
    enabled = environ.get('CLOUDINARY_PRIVATE_DELIVERY_ENABLED', 'false')
    if enabled not in {'true', 'false'}:
        raise StartupRejected('Private media activation must be explicit.')
    if enabled == 'false':
        return
    try:
        if environ.get('CLOUDINARY_PRIVATE_MEDIA_MAP_SHA256') != PRIVATE_MEDIA_MAP_SHA256:
            raise ValueError
        descriptor = os.open(PRIVATE_MEDIA_MAP, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0))
        with os.fdopen(descriptor, 'rb') as source:
            payload = source.read(1_048_577)
        if len(payload) > 1_048_576 or hashlib.sha256(payload).hexdigest() != PRIVATE_MEDIA_MAP_SHA256:
            raise ValueError
        release = json.loads(payload)
        cloud = environ.get('CLOUDINARY_CLOUD_NAME', '')
        key = environ.get('CLOUDINARY_API_KEY', '')
        secret = environ.get('CLOUDINARY_API_SECRET', '')
        ttl = int(environ.get('CLOUDINARY_PRIVATE_URL_TTL_SECONDS', '300'))
        hosts = {host.strip().lower() for host in environ.get('DJANGO_CONTENT_MEDIA_HOSTS', '').split(',')}
        if (release.get('schema_version') != 1 or release.get('scope') != 'first_release_only'
                or release.get('remote_originals_verified') is not True
                or not cloud or cloud != release.get('cloud_name')
                or not re.fullmatch(r'[0-9]{6,64}', key)
                or not 16 <= len(secret) <= 200 or any(ord(char) <= 32 or ord(char) == 127 for char in secret)
                or not 30 <= ttl <= 900 or 'api.cloudinary.com' not in hosts):
            raise ValueError
        secret.encode('utf-8')
    except (OSError, ValueError, TypeError, AttributeError, UnicodeError):
        raise StartupRejected('Private media credentials, approved map pin or HTTPS host configuration are incomplete.') from None


def lookup_sandbox_test_parent(environ, *, user_model=None, validate=None, emit=None):
    """Optional operator lookup: readonly receipt, never automatic enrollment.

    Absent by default with no Django import/query. The temporary email is removed
    even on rejection and is never included in a receipt or error message.
    """
    name = 'KK_SANDBOX_TEST_PARENT_LOOKUP_EMAIL'
    if name not in environ:
        return
    email = environ.pop(name)
    try:
        if (environ.get('RENDER_SANDBOX_CHECKOUT_QUALIFICATION_ENABLED') != 'true'
                or environ.get('RENDER_EXTERNAL_HOSTNAME') != SANDBOX_QUALIFICATION_HOST
                or not isinstance(email, str) or not 3 <= len(email) <= 254
                or email != email.strip() or any(ord(char) <= 32 or ord(char) == 127 for char in email)):
            raise ValueError
        qualify_sandbox_checkout(environ)
        if validate is None:
            from django.core.validators import validate_email
            validate = validate_email
        validate(email)
        if user_model is None:
            from django.contrib.auth import get_user_model
            user_model = get_user_model()
        normalized = user_model.objects.normalize_email(email)
        matches = list(user_model.objects.filter(email=normalized, is_active=True,
            email_verified_at__isnull=False, is_staff=False, is_superuser=False).only(
                'pk', 'is_active', 'email_verified_at', 'is_staff', 'is_superuser').order_by('pk')[:2])
        if len(matches) != 1:
            raise ValueError
        parent = matches[0]
        if (type(parent.pk) is not int or parent.pk <= 0 or not parent.is_active
                or not parent.email_verified_at or parent.is_staff or parent.is_superuser):
            raise ValueError
        count = parent.kid_profiles.count()
        if type(count) is not int or count < 0:
            raise ValueError
        receipt = {'sandbox_test_parent_lookup': 'eligible_parent',
                   'parent_id': parent.pk, 'profile_count': count}
    except Exception:
        raise StartupRejected('Sandbox test-parent lookup requires one eligible verified non-admin parent on the approved staging service.') from None
    (emit or print)(json.dumps(receipt, sort_keys=True), flush=True)


def prepare_environment(environ):
    """Validate only explicit staging inputs; no environment values enter errors."""
    if environ.get('DJANGO_DEBUG') != 'false':
        raise StartupRejected('Explicit production mode is required.')
    email_enabled = environ.get('DJANGO_EMAIL_DELIVERY_ENABLED')
    if email_enabled not in {'true', 'false'}:
        raise StartupRejected('Email delivery must be explicitly enabled or disabled.')
    if email_enabled == 'true':
        from email.utils import parseaddr
        try:
            sender = environ.get('DJANGO_DEFAULT_FROM_EMAIL', '')
            address = parseaddr(sender, strict=True)[1]
            domain = environ.get('RESEND_VERIFIED_DOMAIN', '')
            key = environ.get('RESEND_API_KEY', '')
            if (environ.get('DJANGO_EMAIL_BACKEND') != 'Core.resend_backend.EmailBackend'
                    or not re.fullmatch(r'[^\s<>@]+@[^\s<>@]+\.[^\s<>@]+', address)
                    or any(ord(c) < 32 or ord(c) == 127 for c in sender)
                    or domain in {'', 'localhost', 'resend.dev'}
                    or address.rsplit('@', 1)[1].lower() != domain
                    or not 16 <= len(key) <= 256 or not key.isascii()
                    or any(ord(c) <= 32 or ord(c) == 127 for c in key)):
                raise ValueError
        except (ValueError, TypeError):
            raise StartupRejected('Enabled email requires configured Resend HTTPS and a verified sender domain.') from None
    qualify_checkout(environ)
    qualify_private_media(environ)
    for target, seed_name in (
        ('DJANGO_SECRET_KEY', 'RENDER_DJANGO_SECRET_SEED'),
        ('DJANGO_JWT_SIGNING_KEY', 'RENDER_JWT_SIGNING_SEED'),
    ):
        if environ.get(target):
            continue  # Existing explicit keys still face all original Django guards.
        try:
            seed = base64.b64decode(environ.get(seed_name, ''), validate=True)
        except (ValueError, TypeError):
            raise StartupRejected('A valid platform-generated signing seed is required.') from None
        if len(seed) != 32:
            raise StartupRejected('A valid platform-generated signing seed is required.')
        environ[target] = hashlib.sha512(b'kingdom-kids/render-staging/' + target.encode() + b'\0' + seed).hexdigest()
    # Do not retain duplicate seed values in the server's inherited environment.
    environ.pop('RENDER_DJANGO_SECRET_SEED', None)
    environ.pop('RENDER_JWT_SIGNING_SEED', None)
    host = environ.get('RENDER_EXTERNAL_HOSTNAME', '')
    if not re.fullmatch(r'[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.onrender\.com', host):
        raise StartupRejected('The exact Render public hostname is required.')
    if environ.get('DJANGO_ALLOWED_HOSTS', host) != host:
        custom_qualified = (environ.get('RENDER_PRODUCTION_CHECKOUT_QUALIFICATION_ENABLED') == 'true'
            and environ.get('RENDER_PRODUCTION_APPROVED_ORIGIN') == PRODUCTION_CUSTOM_ORIGIN
            and _production_origin_matches(environ))
        if not custom_qualified:
            raise StartupRejected('Only exact qualified public hostnames are permitted.')
    else:
        environ['DJANGO_ALLOWED_HOSTS'] = host
    # The Blueprint uses only Render's same-region private Key Value URL and
    # blocks every external cache IP. Never opt out of TLS for an arbitrary URL.
    from urllib.parse import urlsplit
    cache = urlsplit(environ.get('DJANGO_CACHE_URL', ''))
    if cache.scheme == 'redis' and (
        environ.get('DJANGO_CACHE_ALLOW_INSECURE') != 'true'
        or not re.fullmatch(r'red-[a-z0-9-]+', cache.hostname or '')
        or cache.port not in (None, 6379)
    ):
        raise StartupRejected('Unencrypted cache must be Render private Key Value only.')
    port = environ.get('PORT', '10000')
    if not port.isdecimal() or not 1024 <= int(port) <= 65535:
        raise StartupRejected('A valid non-privileged application port is required.')
    return port


def control_socket_path():
    # mkdtemp creates a private 0700 directory. Never let Gunicorn create its
    # default $HOME/.gunicorn beneath the deliberately read-only /app tree.
    directory = tempfile.mkdtemp(prefix='kingdom-kids-gunicorn-', dir='/tmp')
    return str(Path(directory) / 'control.sock')


@contextmanager
def migration_lock(connection_parameters, *, connect=None, clock=time.monotonic, sleep=time.sleep):
    """A separate session lock serializes old/new startup migration attempts."""
    if connect is None:
        import psycopg
        connect = psycopg.connect
    with connect(**connection_parameters, autocommit=True) as lock_connection:
        with lock_connection.cursor() as cursor:
            deadline = clock() + 120
            while True:
                cursor.execute('SELECT pg_try_advisory_lock(%s)', (MIGRATION_LOCK,))
                if cursor.fetchone()[0]:
                    break
                if clock() >= deadline:
                    raise StartupRejected('Another deployment still owns the migration lock.')
                sleep(1)
            try:
                yield
            finally:
                cursor.execute('SELECT pg_advisory_unlock(%s)', (MIGRATION_LOCK,))


def start():
    port = prepare_environment(os.environ)
    os.chdir(BACKEND)
    sys.path.insert(0, str(BACKEND / 'Core'))
    os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'Core.settings')
    import django
    django.setup()  # All original production settings checks remain authoritative.
    from django.core.management import call_command
    from django.db import connections
    call_command('check', deploy=True, fail_level='ERROR')
    database = connections['default']
    if database.vendor != 'postgresql':
        raise StartupRejected('Deployment migrations require PostgreSQL.')
    with migration_lock(database.get_connection_params()):
        call_command('migrate', interactive=False)
        call_command('install_published_matching_release', apply=True, publish=True)
        if os.environ.get('CLOUDINARY_PRIVATE_DELIVERY_ENABLED', 'false') == 'true':
            call_command('install_private_media_release')
        if os.environ.get('KK_TEST_FAMILY_IMPORT_ZLIB_B64'):
            call_command('install_private_test_family', apply=True)
            for name in ('KK_TEST_FAMILY_IMPORT_ZLIB_B64', 'KK_TEST_FAMILY_IMPORT_SHA256', 'KK_TEST_FAMILY_IMPORT_EMAIL'):
                os.environ.pop(name, None)
    lookup_sandbox_test_parent(os.environ)
    connections.close_all()
    # One synchronous worker fits the Free instance and keeps DB usage bounded.
    # Access logs omit request URLs, which can contain query parameters.
    os.execvp('gunicorn', ['gunicorn', '--chdir', 'Core', 'Core.wsgi:application',
        '--bind', f'0.0.0.0:{port}', '--workers', '1', '--timeout', '30',
        '--control-socket', control_socket_path(), '--control-socket-mode', '384',
        '--graceful-timeout', '30', '--access-logfile', '-',
        '--access-logformat', '%(h)s %(s)s %(L)s', '--error-logfile', '-'])


if __name__ == '__main__':
    try:
        start()
    except Exception:
        # No traceback/environment/connection string is printed at this boundary.
        print('Render startup failed: configuration validation or migrations did not complete.', file=sys.stderr)
        raise SystemExit(1) from None
