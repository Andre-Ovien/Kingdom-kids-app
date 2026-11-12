"""Native app JWT only; no checkout-audience tokens or redirect authority."""
from django.views.decorators.debug import sensitive_variables
from rest_framework.views import APIView
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.throttling import ScopedRateThrottle,UserRateThrottle
from apps.accounts.authentication import VerifiedEmailJWTAuthentication
from . import hosted_checkout as core
from .checkout import CheckoutRejected,CheckoutBusy,CheckoutConflict
from .configuration import SquareDisabled,SquareConfigurationError,active_billing_environment
from .client import SquareClientError
from .hosted_models import SquareHostedAttempt


class HostedBase(APIView):
    authentication_classes=(VerifiedEmailJWTAuthentication,)
    permission_classes=(IsAuthenticated,)
    throttle_classes=(ScopedRateThrottle,UserRateThrottle)
    throttle_scope='billing_checkout'
    def finalize_response(self,request,response,*args,**kwargs):
        response=super().finalize_response(request,response,*args,**kwargs)
        response['Cache-Control']='no-store, private';response['Referrer-Policy']='no-referrer'
        return response
    def fields(self,request,names):
        value=request.data
        if not isinstance(value,dict) or set(value)!=set(names):raise CheckoutRejected('Only the current checkout fields are accepted.')
        return value
    def error(self,error):
        if isinstance(error,(SquareDisabled,SquareHostedAttempt.DoesNotExist)):return Response({'detail':'Not found.'},status=404)
        if isinstance(error,(CheckoutBusy,CheckoutConflict)):return Response({'code':'checkout_pending','detail':str(error)},status=409)
        if isinstance(error,core.HostedParentAuthorizationRejected):return Response({'code':'invalid_parent_password','detail':'Fresh parent password confirmation is required.'},status=400)
        if isinstance(error,CheckoutRejected):return Response({'code':'checkout_refused','detail':str(error)},status=400)
        return Response({'code':'checkout_uncertain','detail':'Keep this same checkout and check its status. Do not start another payment.'},status=503)
    def owned(self,request,attempt_id):
        return SquareHostedAttempt.objects.get(pk=attempt_id,parent=request.user,environment=active_billing_environment())


class HostedQuoteView(HostedBase):
    def get(self,request):
        try:
            if set(request.query_params)!={'billing_period'} or len(request.query_params.getlist('billing_period'))!=1:raise CheckoutRejected('Select one billing period.')
            return Response(core.quote(parent=request.user,period=request.query_params['billing_period']))
        except (SquareDisabled,SquareConfigurationError,SquareClientError,CheckoutRejected,ValueError,TypeError) as error:return self.error(error)


class HostedAuthorizeView(HostedBase):
    @sensitive_variables()
    def post(self,request):
        try:
            data=self.fields(request,('operation_id','billing_period','password','accepted','disclosure_version','disclosure_sha256'))
            return Response(core.authorize(parent=request.user,**data))
        except (SquareDisabled,SquareConfigurationError,CheckoutRejected,ValueError,TypeError) as error:return self.error(error)


class HostedPrepareView(HostedBase):
    @sensitive_variables()
    def post(self,request):
        try:
            data=self.fields(request,('operation_id','billing_period','authorization_token'))
            return Response(core.prepare(parent=request.user,**data))
        except (SquareDisabled,SquareConfigurationError,SquareClientError,CheckoutRejected,SquareHostedAttempt.DoesNotExist,ValueError,TypeError) as error:return self.error(error)


class HostedStatusView(HostedBase):
    throttle_scope='billing_status'
    def get(self,request,attempt_id):
        try:return Response(core.status(self.owned(request,attempt_id)))
        except (SquareHostedAttempt.DoesNotExist,SquareConfigurationError,SquareClientError) as error:return self.error(error)


class HostedReconcileView(HostedBase):
    throttle_scope='billing_status'
    @sensitive_variables()
    def post(self,request,attempt_id):
        try:
            self.fields(request,());self.owned(request,attempt_id)
            return Response(core.reconcile(parent=request.user,attempt_id=attempt_id))
        except (SquareDisabled,SquareConfigurationError,SquareClientError,CheckoutRejected,SquareHostedAttempt.DoesNotExist,ValueError,TypeError) as error:return self.error(error)


class HostedCancelView(HostedBase):
    @sensitive_variables()
    def post(self,request,attempt_id):
        try:
            data=self.fields(request,('password',));self.owned(request,attempt_id)
            return Response(core.cancel(parent=request.user,attempt_id=attempt_id,**data))
        except (SquareDisabled,SquareConfigurationError,SquareClientError,CheckoutRejected,SquareHostedAttempt.DoesNotExist,ValueError,TypeError) as error:return self.error(error)
