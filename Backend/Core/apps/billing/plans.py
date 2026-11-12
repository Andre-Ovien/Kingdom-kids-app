"""Confirmed immutable commercial terms and pure, unsent Square draft builder."""
from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
from uuid import UUID, NAMESPACE_URL, uuid5


POLICY_PATH = Path(__file__).with_name('content_policy_v1.json')
POLICY_SHA256 = '7f555ab521fb32ccf92714ac2572e1e2d9d379fc63f300d7810ff9c3da50cbda'
ALL_CONTENT_FEATURE = 'all_stories_and_games'


@dataclass(frozen=True)
class ConfirmedContentPlan:
    policy_id: str = 'all-content-monthly-usd-999-v1'
    amount_minor: int = 999
    currency: str = 'USD'
    cadence: str = 'MONTHLY'
    anchor_day: int = 28
    can_prorate: bool = False
    first_charge: str = 'full_amount_immediately'
    access_feature: str = ALL_CONTENT_FEATURE


def confirmed_content_plan():
    raw = POLICY_PATH.read_bytes()
    if hashlib.sha256(raw).hexdigest() != POLICY_SHA256:
        raise ValueError('Commercial policy differs from the reviewed terms.')
    data = json.loads(raw)
    plan = ConfirmedContentPlan()
    if (data['amount_minor'], data['currency'], data['billing_cadence'],
            data['monthly_billing_anchor_date'], data['can_prorate']) != (
            plan.amount_minor, plan.currency, plan.cadence, plan.anchor_day, plan.can_prorate):
        raise ValueError('Commercial policy differs from the reviewed terms.')
    return plan


def square_catalogue_request(*, operation_id, location_id):
    """Return one atomic plan+variation batch. Never sends or reads credentials.

    The caller must retain this operation UUID for exact retries; a different
    release/location is a different deterministic provider request identity.
    """
    plan = confirmed_content_plan()
    operation_id = UUID(str(operation_id))
    if (not isinstance(location_id, str) or not 1 <= len(location_id) <= 192
            or any(ord(character) <= 32 or ord(character) == 127 for character in location_id)):
        raise ValueError('A valid explicit sandbox location ID is required.')
    location_id.encode('utf-8')
    key = uuid5(NAMESPACE_URL, f'kingdom-kids/catalogue/{plan.policy_id}/{location_id}/{operation_id}')
    plan_id, variation_id = '#kingdom-kids-full-content-v1', '#kingdom-kids-monthly-999-v1'
    presence = {'present_at_all_locations': False, 'present_at_location_ids': [location_id]}
    return {'idempotency_key': str(key), 'batches': [{'objects': [
        {'type': 'SUBSCRIPTION_PLAN', 'id': plan_id, **presence,
         'subscription_plan_data': {'name': 'Kingdom Kids all stories and games'}},
        {'type': 'SUBSCRIPTION_PLAN_VARIATION', 'id': variation_id, **presence,
         'subscription_plan_variation_data': {
             'name': 'Monthly full access USD 9.99', 'subscription_plan_id': plan_id,
             'monthly_billing_anchor_date': plan.anchor_day, 'can_prorate': plan.can_prorate,
             'phases': [{'ordinal': 0, 'cadence': plan.cadence,
                         'pricing': {'type': 'STATIC', 'price_money': {
                             'amount': plan.amount_minor, 'currency': plan.currency}}}],
         }},
    ]}]}
