"""Provider-managed recurring cadence, distinct from historical app-owned terms."""
from dataclasses import dataclass
from .checkout import fingerprint

@dataclass(frozen=True)
class HostedPlan:
    period:str
    amount:int
    cadence:str
    coverage_rule:str
    policy_id:str
    policy_sha256:str


def hosted_plan(period):
    if period not in {'monthly','yearly'}:raise ValueError('Unknown hosted billing period.')
    amount,cadence,rule=(999,'THIRTY_DAYS','elapsed_days_30') if period=='monthly' else (9990,'ANNUAL','calendar_year_1')
    data={'version':1,'billing_controller':'square_hosted_subscriptions','billing_period':period,
        'amount_minor':amount,'currency':'USD','cadence':cadence,'coverage_rule':rule,
        'provider_billing_anchor':'subscription_start_date_no_fixed_monthly_anchor',
        'access_start':'canonical_completed_card_capture','free_period':False,'proration':False,
        'automatic_renewal':True,'card_storage':'square_managed','policy_id':'square-hosted-'+period+'-usd-'+str(amount)+'-v1'}
    return HostedPlan(period,amount,cadence,rule,data['policy_id'],fingerprint(data))


def disclosure(period,environment):
    plan=hosted_plan(period);amount=f'{plan.amount/100:.2f}'
    interval='30 days' if period=='monthly' else '12 calendar months'
    cadence='every 30 days' if period=='monthly' else 'every year'
    data={'schema_version':1,'environment':environment,'billing_period':period,'amount_minor':plan.amount,
        'currency':'USD','policy_id':plan.policy_id,'policy_sha256':plan.policy_sha256,
        'disclosure_version':'square-hosted-recurring-'+period+'-v1','cadence':plan.cadence,
        'automatic_renewal':True,'billing_controller':'square_hosted_subscriptions',
        'disclosure':f'Square will charge ${amount} USD now and automatically {cadence} until you cancel. '
            f'Each successful payment provides {interval} of access to all stories and games, starting when payment completes. '
            'Square saves your card and manages recurring payments on its secure payment page. '
            'There is no free period or proration. Renewal billing follows Square’s subscription dates; '
            'it is not promised to occur at the same time of day as your first payment. '
            'You can stop future renewals in parent account settings. Canceling keeps your verified already-paid access until its original end.'}
    data['disclosure_sha256']=fingerprint(data)
    return data
