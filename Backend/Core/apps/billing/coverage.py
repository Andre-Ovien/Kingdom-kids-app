"""Pure app-contract coverage; dates originate only from canonical capture proof."""
from datetime import timedelta, timezone
from hashlib import sha256
import json
from zoneinfo import ZoneInfo


def coverage_end(captured_at, rule, billing_timezone):
    if captured_at.tzinfo is None or captured_at.utcoffset() is None:
        raise ValueError('Capture time must be timezone-aware.')
    if rule == 'elapsed_days_30':
        return captured_at.astimezone(timezone.utc) + timedelta(days=30)
    if rule != 'calendar_year_1': raise ValueError('Unknown reviewed duration.')
    zone = ZoneInfo(billing_timezone)
    local = captured_at.astimezone(zone)
    # Same local anniversary; Feb29 is clamped to Feb28 next year.
    day = 28 if local.month == 2 and local.day == 29 else local.day
    target = local.replace(year=local.year+1,day=day,tzinfo=None)
    candidates = [target.replace(tzinfo=zone,fold=fold).astimezone(timezone.utc) for fold in (0,1)]
    valid = [instant for instant in candidates if instant.astimezone(zone).replace(tzinfo=None) == target]
    if valid: return max(valid)  # Later occurrence for an ambiguous anniversary.
    # Nonexistent wall time: normalize forward by the zone's gap, never backward.
    forward = [instant for instant in candidates if instant.astimezone(zone).replace(tzinfo=None) > target]
    if not forward: raise ValueError('Annual anniversary cannot be qualified in this timezone.')
    return min(forward)


def coverage_hash(term, agreement):
    fields = {'term':str(term.pk),'payment':term.payment_id,'policy':agreement.policy_sha256,
        'rule':term.coverage_rule,'timezone':agreement.billing_timezone,
        'captured_at':term.captured_at.isoformat() if term.captured_at else None,
        'valid_from':term.valid_from.isoformat() if term.valid_from else None,
        'valid_until':term.valid_until.isoformat() if term.valid_until else None}
    return sha256(json.dumps(fields,sort_keys=True,separators=(',',':')).encode()).hexdigest()
