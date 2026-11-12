"""Reviewed capture-bound contracts; historical calendar-28 policies are read-only."""
from dataclasses import dataclass
from decimal import Decimal
import hashlib
import json
from pathlib import Path
from .plans import POLICY_SHA256, confirmed_content_plan

MONTHLY_POLICY_ID = 'all-content-30-days-usd-999-v2'
YEARLY_POLICY_ID = 'all-content-yearly-usd-9990-v2'
ACTIVE_POLICY_IDS = (MONTHLY_POLICY_ID, YEARLY_POLICY_ID)
MONTHLY_POLICY_SHA256 = '162242535dc87f050f476483c8820f4d7a3f958b5d41c53b68b1e168cf424650'
YEARLY_POLICY_SHA256 = '69d5345418ca8b12595fbc2b5a4fce967c6c7cf2c1467f2e6884b97dae950ae3'
LEGACY_YEARLY_ID = 'all-content-yearly-usd-10789-v1'
LEGACY_YEARLY_SHA256 = '0a275eb3d5ba1020aa41f358211124b79912d71a3d2a191193378a9be91ddb17'
ONE_PERIOD_MONTHLY_ID = 'all-content-one-period-monthly-usd-999-v1'
ONE_PERIOD_YEARLY_ID = 'all-content-one-period-yearly-usd-9990-v1'

@dataclass(frozen=True)
class ContentTermPlan:
    billing_period: str
    policy_id: str
    policy_sha256: str
    amount_minor: int
    cadence: str
    disclosure_version: str
    coverage_rule: str = ''
    purchasable: bool = True
    renewable: bool = True

    @property
    def amount_display(self):
        return str((Decimal(self.amount_minor) / 100).quantize(Decimal('0.01')))


def _read_policy(name, expected_sha):
    raw = Path(__file__).with_name(name).read_bytes()
    if hashlib.sha256(raw).hexdigest() != expected_sha:
        raise ValueError('Commercial policy differs from its reviewed version.')
    return json.loads(raw)


def content_term_plan(billing_period='monthly'):
    if billing_period == 'monthly':
        plan = ContentTermPlan('monthly',MONTHLY_POLICY_ID,MONTHLY_POLICY_SHA256,999,'DAYS_30',
                               'usd999-30days-capture-v2','elapsed_days_30')
        data = _read_policy('content_policy_30_days_v2.json',plan.policy_sha256)
    elif billing_period == 'yearly':
        plan = ContentTermPlan('yearly',YEARLY_POLICY_ID,YEARLY_POLICY_SHA256,9990,'ANNUAL',
                               'usd9990-year-capture-v2','calendar_year_1')
        data = _read_policy('content_policy_yearly_v2.json',plan.policy_sha256)
    else: raise ValueError('Unknown reviewed billing period.')
    if (data['policy_id'],data['amount_minor'],data['cadence'],data['coverage_rule'],data['currency']) != (
            plan.policy_id,plan.amount_minor,plan.cadence,plan.coverage_rule,'USD'):
        raise ValueError('Commercial policy differs from its reviewed version.')
    return plan


def one_period_plan(billing_period):
    current = content_term_plan(billing_period)
    monthly = billing_period == 'monthly'
    plan = ContentTermPlan(billing_period,ONE_PERIOD_MONTHLY_ID if monthly else ONE_PERIOD_YEARLY_ID,
        '5779d50ace484667548f1c4ae00c7ac52df77393b7bf93a79c9205198e2df54f' if monthly else
        'c193c8f93f5abdf93e4e602117eb1bfada7d340d09d8fad5c3619cd57299a8e4',
        current.amount_minor,current.cadence,'usd999-one-period-30days-v1' if monthly else
        'usd9990-one-period-year-v1',current.coverage_rule,renewable=False)
    data = _read_policy('content_policy_one_period_'+billing_period+'_v1.json',plan.policy_sha256)
    if (data['policy_id'],data['amount_minor'],data['cadence'],data['coverage_rule'],data['currency'],
            data['renewal'],data['card_storage']) != (plan.policy_id,plan.amount_minor,plan.cadence,
            plan.coverage_rule,'USD','none','none'):
        raise ValueError('One-period policy differs from its reviewed version.')
    return plan


def checkout_term_plan(billing_period='monthly', *, environment='sandbox'):
    from .configuration import controlled_production_checkout
    if environment == 'production' and controlled_production_checkout():
        return one_period_plan(billing_period)
    return content_term_plan(billing_period)


def term_plan_for_policy(policy_id):
    if policy_id == ONE_PERIOD_MONTHLY_ID: return one_period_plan('monthly')
    if policy_id == ONE_PERIOD_YEARLY_ID: return one_period_plan('yearly')
    if policy_id == MONTHLY_POLICY_ID: return content_term_plan('monthly')
    if policy_id == YEARLY_POLICY_ID: return content_term_plan('yearly')
    if policy_id == 'all-content-monthly-usd-999-v1':
        old = confirmed_content_plan()
        return ContentTermPlan('monthly',old.policy_id,POLICY_SHA256,999,'MONTHLY',
                               'usd999-app-terms-28-v1',purchasable=False)
    if policy_id == LEGACY_YEARLY_ID:
        _read_policy('content_policy_yearly_v1.json',LEGACY_YEARLY_SHA256)
        return ContentTermPlan('yearly',policy_id,LEGACY_YEARLY_SHA256,10789,'ANNUAL',
                               'usd10789-yearly-app-terms-28-v1',purchasable=False)
    raise ValueError('Unknown immutable content policy.')
