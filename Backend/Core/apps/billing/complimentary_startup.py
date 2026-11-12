"""Default-absent one-time operator operation on the approved Free-host profile."""
from datetime import datetime
import json
import re
from uuid import UUID
from .complimentary_errors import ComplimentaryRejected, SAFE_CODES

HOST = 'kingdom-kids-checkout-staging.onrender.com'
PREFIX = 'KK_COMPLIMENTARY_ACCESS_'
FIELDS = {'OPERATION', 'PARENT_ID', 'ENVIRONMENT', 'REQUEST_ID', 'OWNER_SHA256',
          'VALID_UNTIL', 'AUTHORIZED_BY', 'REASON', 'GRANT_ID'}


class ComplimentaryStartupRejected(Exception):
    def __init__(self, code):
        self.safe_code = code if code in SAFE_CODES else 'internal_error'
        super().__init__('Complimentary startup operation refused [' + self.safe_code + '].')


def _uuid(value):
    result = UUID(value)
    if str(result) != value: raise ValueError
    return str(result)


def apply_startup_operation(environ, *, output=print):
    # Strip before any validation/import/query, including on rejected input.
    names = [name for name in environ if name.startswith(PREFIX)]
    if not names: return False
    raw = {name.removeprefix(PREFIX): environ.pop(name) for name in names}
    stage = 'invalid_request'
    try:
        if set(raw) - FIELDS: raise ValueError
        stage = 'invalid_profile'
        if (environ.get('RENDER_EXTERNAL_HOSTNAME') != HOST
                or environ.get('DJANGO_ALLOWED_HOSTS') != HOST
                or environ.get('PARENT_CHECKOUT_ORIGIN') != 'https://' + HOST
                or environ.get('RENDER_HOSTED_PRODUCTION_CHECKOUT_ENABLED') != 'true'
                or environ.get('DJANGO_DEBUG') != 'false'
                or environ.get('SQUARE_ENVIRONMENT') != 'production'
                or environ.get('PAID_CONTENT_ENTITLEMENT_ENVIRONMENT') != 'production'
                or environ.get('PAID_CONTENT_ENFORCEMENT_ENABLED') != 'true'
                or environ.get('PARENT_CONTENT_ACCESS_STATUS_ENABLED') != 'true'
                or raw.get('ENVIRONMENT') != 'production'):
            raise ValueError
        stage = 'invalid_owner'
        if (not re.fullmatch('[1-9][0-9]{0,18}', raw.get('PARENT_ID', ''))
                or int(raw['PARENT_ID']) > 9223372036854775807
                or not re.fullmatch('[a-f0-9]{64}', raw.get('OWNER_SHA256', ''))):
            raise ValueError
        stage = 'invalid_request'
        if (raw.get('OPERATION') not in {'grant', 'revoke'}
                or raw.get('REASON') != 'user_requested_test_access'
                or not re.fullmatch('[A-Za-z0-9_-]{1,96}', raw.get('AUTHORIZED_BY', ''))):
            raise ValueError
        common = dict(parent_id=int(raw['PARENT_ID']), environment='production',
            request_reference=_uuid(raw['REQUEST_ID']), owner_sha256=raw['OWNER_SHA256'],
            authorized_by=raw['AUTHORIZED_BY'], apply=True)
        if raw['OPERATION'] == 'grant':
            if raw.get('GRANT_ID'): raise ValueError
            stage = 'invalid_expiry'
            expiry = datetime.fromisoformat(raw['VALID_UNTIL'].replace('Z', '+00:00'))
            if expiry.tzinfo is None or expiry.utcoffset() is None: raise ValueError
            stage = 'internal_error'
            from .complimentary import grant_access
            row, changed = grant_access(**common, valid_until=expiry, reason_code=raw['REASON'])
        else:
            if raw.get('VALID_UNTIL'): raise ValueError
            identifier = _uuid(raw['GRANT_ID'])
            stage = 'internal_error'
            from .complimentary import revoke_access
            row, changed = revoke_access(**common, grant_id=identifier)
        output('KK_COMPLIMENTARY_ACCESS_RECEIPT ' + json.dumps({
            'grant_id': str(row.pk), 'environment': row.environment,
            'state': 'revoked' if row.revoked_at else 'granted', 'changed': changed,
            'valid_until': row.valid_until.isoformat()}, sort_keys=True))
        return True
    except Exception as error:
        if isinstance(error, ComplimentaryRejected): code = error.safe_code
        elif isinstance(error, (KeyError, ValueError, TypeError, OverflowError)): code = stage
        else: code = 'internal_error'
        # Static codes only; no account, fingerprint, config or DB error text.
        output('KK_COMPLIMENTARY_ACCESS_REFUSED reason=' + code)
        raise ComplimentaryStartupRejected(code) from None
