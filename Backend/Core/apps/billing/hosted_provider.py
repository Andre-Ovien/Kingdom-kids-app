"""Explicit hosted-subscription provider profile; no app-owned charge dispatcher."""
import re
from urllib.parse import urlsplit
from django.conf import settings
from django.views.decorators.debug import sensitive_variables
from .client import SquareSandboxClient,SquareProductionClient,SquareClientError
from .configuration import (SquareDisabled,SquareConfigurationError,active_billing_environment,
    environment_prefix,provider_identifier,square_configuration,SquareCheckoutConfiguration)

RETURN_URL='https://kingdom-kids.app/payments/return/'


def hosted_enabled(environment=None):
    environment=environment or active_billing_environment()
    return getattr(settings,environment_prefix(environment)+'_HOSTED_SUBSCRIPTIONS_ENABLED',False) is True


@sensitive_variables()
def hosted_configuration(*,environment=None,readonly=False):
    environment=environment or active_billing_environment();prefix=environment_prefix(environment)
    if active_billing_environment()!=environment or (not readonly and not hosted_enabled(environment)):raise SquareDisabled('Hosted subscriptions are disabled.')
    if not readonly and (getattr(settings,'PARENT_CONTENT_ACCESS_STATUS_ENABLED',False) is not True or settings.PAID_CONTENT_ENTITLEMENT_ENVIRONMENT!=environment):
        raise SquareDisabled('Hosted access status is not configured.')
    old_flags=('SQUARE_PRODUCTION_CONTROLLED_CHECKOUT_ENABLED','SQUARE_PRODUCTION_CHECKOUT_ENABLED',
        'PARENT_CHECKOUT_PRODUCTION_ENABLED','SQUARE_PRODUCTION_TERM_BILLING_ENABLED',
        'SQUARE_PRODUCTION_TERM_RECONCILIATION_ENABLED','SQUARE_PRODUCTION_RELEASE_QUALIFIED',
        'SQUARE_SANDBOX_RECONCILIATION_JOBS_ENABLED','SQUARE_SANDBOX_RENEWAL_JOBS_ENABLED',
        'SQUARE_PRODUCTION_RENEWALS_ENABLED','SQUARE_PRODUCTION_RECONCILIATION_JOBS_ENABLED','SQUARE_PRODUCTION_RENEWAL_JOBS_ENABLED')
    if environment=='production' and not readonly:
        if (getattr(settings,'SQUARE_HOSTED_RELEASE_QUALIFIED',False) is not True
                or settings.PAID_CONTENT_ENFORCEMENT_ENABLED is not True
                or getattr(settings,'SQUARE_PRODUCTION_CONTROLLED_PARENT_IDS','')!=''
                or any(getattr(settings,n,False) is not False for n in old_flags)):
            raise SquareDisabled('Hosted production is not explicitly qualified.')
    if type(settings.SQUARE_HTTP_TIMEOUT_SECONDS) is not int or not 1<=settings.SQUARE_HTTP_TIMEOUT_SECONDS<=5:
        raise SquareConfigurationError('Hosted requests require a bounded provider timeout of at most five seconds.')
    provider=square_configuration(environment=environment)
    signed=square_configuration(environment=environment,webhook=True) if not readonly else None
    origin=getattr(settings,'PARENT_CHECKOUT_ORIGIN','')
    parsed=urlsplit(origin)
    if (parsed.scheme!='https' or not parsed.hostname or parsed.username or parsed.password or parsed.port not in (None,443)
            or parsed.path or parsed.query or parsed.fragment or any(c in origin for c in '\\?#')
            or (signed is not None and signed.notification_url!=origin+'/api/billing/square/webhook/')):
        raise SquareConfigurationError('Hosted checkout requires its exact secure callback origin.')
    location=provider_identifier(getattr(settings,prefix+'_LOCATION_ID',''),192)
    if not readonly:
        ids=[provider_identifier(getattr(settings,prefix+'_HOSTED_'+period+'_VARIATION_ID',''),192) for period in ('MONTHLY','YEARLY')]
        if len(set(ids))!=2:raise SquareConfigurationError('Hosted plans require distinct reviewed variation IDs.')
    if (getattr(settings,prefix+'_HTTP_TRANSPORT_ENABLED',False) is not True
            and not callable(getattr(settings,prefix+'_TRANSPORT_FACTORY',None))):
        raise SquareConfigurationError('Hosted provider transport is not explicitly configured.')
    return SquareCheckoutConfiguration(provider,location,'')


def variation_id(period,environment):
    if period not in {'monthly','yearly'}:raise SquareConfigurationError('Unknown hosted billing period.')
    return provider_identifier(getattr(settings,environment_prefix(environment)+'_HOSTED_'+period.upper()+'_VARIATION_ID',''),192)


def approved_provider_url(value,*,environment):
    if not isinstance(value,str) or len(value)>2048 or any(ord(c)<=32 for c in value):raise SquareClientError('Invalid hosted checkout address.')
    parsed=urlsplit(value)
    if parsed.scheme!='https' or parsed.username or parsed.password or parsed.port is not None or parsed.query or parsed.fragment:
        raise SquareClientError('Invalid hosted checkout address.')
    if environment=='production':
        valid=(parsed.hostname=='square.link' and re.fullmatch(r'/u/[A-Za-z0-9_-]{1,255}',parsed.path)
            or parsed.hostname=='checkout.square.site' and re.fullmatch(r'/merchant/[A-Za-z0-9_-]{1,192}/order/[A-Za-z0-9_-]{1,192}',parsed.path))
    else:
        valid=(parsed.hostname=='sandbox.square.link' and re.fullmatch(r'/u/[A-Za-z0-9_-]{1,255}',parsed.path)
            or parsed.hostname=='connect.squareupsandbox.com' and re.fullmatch(r'/v2/online-checkout/sandbox-testing-panel/[A-Za-z0-9_-]{1,192}/[A-Za-z0-9_-]{1,192}',parsed.path))
    if not valid:raise SquareClientError('Hosted checkout address is outside the approved provider.')
    return value


class _HostedProtocol:
    def _authorize_operation(self,method,path,payload=None):
        creation=method=='POST' and path=='/v2/online-checkout/payment-links'
        hosted_configuration(environment=self.environment,readonly=not creation)
        if method=='GET' and any(path.startswith('/v2/'+p) for p in ('merchants/','locations/','catalog/object/','subscriptions/','invoices/','orders/','payments/','refunds/','cards/','customers/','online-checkout/payment-links/')):return
        if method=='POST' and path in {'/v2/subscriptions/search','/v2/online-checkout/payment-links'}:return
        if method=='POST' and re.fullmatch(r'/v2/subscriptions/[^/]+/cancel',path):return
        if method=='DELETE' and re.fullmatch(r'/v2/online-checkout/payment-links/[^/]+',path):return
        raise SquareDisabled('This hosted adapter cannot create an app-owned charge or stored card.')
    def create_hosted_subscription_link(self,*,payload):
        return self.request('POST','/v2/online-checkout/payment-links',payload)


class HostedSandboxClient(_HostedProtocol,SquareSandboxClient):pass
class HostedProductionClient(_HostedProtocol,SquareProductionClient):pass


@sensitive_variables()
def hosted_client(*,environment=None,readonly=False):
    environment=environment or active_billing_environment();hosted_configuration(environment=environment,readonly=readonly)
    prefix=environment_prefix(environment);factory=getattr(settings,prefix+'_TRANSPORT_FACTORY',None)
    if callable(factory):transport=factory()
    elif getattr(settings,prefix+'_HTTP_TRANSPORT_ENABLED',False) is True:
        from .http_transport import ProductionTransport,SandboxTransport
        transport=ProductionTransport() if environment=='production' else SandboxTransport()
    else:raise SquareConfigurationError('Hosted provider transport is unavailable.')
    if not callable(getattr(transport,'send',None)) or (isinstance(getattr(transport,'environment',None),str) and transport.environment!=environment):
        raise SquareConfigurationError('Hosted provider transport belongs to another environment.')
    return (HostedProductionClient if environment=='production' else HostedSandboxClient)(transport)
