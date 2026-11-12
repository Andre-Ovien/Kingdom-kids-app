from django.conf import settings
from apps.accounts.authentication import VerifiedEmailJWTAuthentication
from .checkout_auth import CheckoutSessionAuthentication
from rest_framework.exceptions import NotFound
from rest_framework.permissions import AllowAny, IsAuthenticated
from rest_framework.throttling import ScopedRateThrottle, UserRateThrottle
from rest_framework.response import Response
from rest_framework.views import APIView
from django.views.decorators.debug import sensitive_variables

from .configuration import SquareConfigurationError, SquareDisabled, square_configuration
from .configuration import checkout_configuration, configured_client, require_payment_parent, active_billing_environment, require_checkout_enabled, environment_prefix
from .checkout import (CheckoutBusy, CheckoutConflict, CheckoutRejected, checkout_status,
                       confirm_direct_checkout, public_terms, reserve_checkout)
from .client import SquareClientError
from .models import SquareCheckoutIntent, SquareContentAgreement
from .serializers import (TermCheckoutCardSerializer, TermCheckoutConsentSerializer, TermPrepareCardSerializer,
                          StopRenewalSerializer)
from .term_plans import term_plan_for_policy
from .terms import (cancel_agreement, confirm_term_checkout, reserve_term_checkout,
                    restart_unpaid_checkout, term_configuration, term_disclosure, verify_payment_location)
from .webhooks import (SquareWebhookConflict, SquareWebhookInvalid,
                       record_notification, valid_signature)


class SquareSandboxWebhookView(APIView):
    authentication_classes = ()
    permission_classes = (AllowAny,)
    parser_classes = ()
    throttle_classes = ()

    @sensitive_variables()
    def post(self, request):
        try:
            config = square_configuration(webhook=True, environment=active_billing_environment())
        except SquareDisabled:
            return self.reply({'detail': 'Not found.'}, 404)
        except SquareConfigurationError:
            return self.reply({'detail': 'Square sandbox is not configured.'}, 503)
        if (request.content_type or '').split(';', 1)[0].lower() != 'application/json':
            return self.reply({'detail': 'JSON is required.'}, 415)
        if request.headers.get('Content-Encoding', 'identity').lower() != 'identity':
            return self.reply({'detail': 'Encoded event bodies are not supported.'}, 415)
        # Bounded stream read also covers absent/untrusted Content-Length.
        raw = request.read(config.max_webhook_bytes + 1)
        if len(raw) > config.max_webhook_bytes:
            return self.reply({'detail': 'Event body is too large.'}, 413)
        if not valid_signature(raw_body=raw, signature=request.headers.get('x-square-hmacsha256-signature'),
                               configuration=config):
            return self.reply({'detail': 'Invalid signature.'}, 403)
        try:
            created = record_notification(raw_body=raw, configuration=config)
        except SquareWebhookInvalid:
            return self.reply({'detail': 'Invalid signed event.'}, 400)
        except SquareWebhookConflict:
            return self.reply({'detail': 'Event conflict.'}, 409)
        # Hosted Square renewals need no app-owned charging scheduler. Apply
        # only bounded canonical reads after durable signed receipt, and ask
        # Square to retry an uncertain observation instead of acknowledging it.
        from .hosted_provider import hosted_enabled
        from .hosted_models import SquareHostedAttempt
        if hosted_enabled(config.environment) or SquareHostedAttempt.objects.filter(
                environment=config.environment,merchant_id=config.merchant_id).exists():
            from .parsing import strict_json
            from .models import SquareWebhookReceipt
            from .hosted_receipts import process_hosted_receipt
            try:
                event_id=strict_json(raw)['event_id']
                receipt=SquareWebhookReceipt.objects.get(environment=config.environment,
                    merchant_id=config.merchant_id,event_id=event_id)
                result=process_hosted_receipt(receipt_id=receipt.pk)
                if result not in {'processed','ignored'}:
                    return self.reply({'received':True,'reconciliation':'pending'},503)
            except Exception:
                return self.reply({'received':True,'reconciliation':'pending'},503)
        return self.reply({'received': True, 'duplicate': not created}, 200)

    def reply(self, data, status):
        response = Response(data, status=status)
        response['Cache-Control'] = 'no-store'
        return response


class SquareCheckoutBase(APIView):
    authentication_classes = (CheckoutSessionAuthentication, VerifiedEmailJWTAuthentication)
    permission_classes = (IsAuthenticated,)
    throttle_classes = (ScopedRateThrottle, UserRateThrottle)
    throttle_scope = 'billing_checkout'
    requires_purchase = True

    def initial(self, request, *args, **kwargs):
        super().initial(request, *args, **kwargs)
        try:
            self.environment = active_billing_environment()
            if self.requires_purchase:
                require_payment_parent(request.user, environment=self.environment)
                require_checkout_enabled(environment=self.environment)
                if getattr(settings, environment_prefix(self.environment) + '_TERM_BILLING_ENABLED', False) is not True:
                    raise SquareDisabled()
        except (SquareDisabled, SquareConfigurationError):
            raise NotFound() from None

    def finalize_response(self, request, response, *args, **kwargs):
        response = super().finalize_response(request, response, *args, **kwargs)
        response['Cache-Control'] = 'no-store'
        return response

    def error(self, error):
        if isinstance(error, (SquareCheckoutIntent.DoesNotExist, SquareContentAgreement.DoesNotExist)):
            return Response({'detail': 'Not found.'}, status=404)
        if isinstance(error, SquareDisabled):
            return Response({'detail': 'Not found.'}, status=404)
        if isinstance(error, SquareConfigurationError):
            return Response({'detail': 'Checkout is not configured.'}, status=503)
        if isinstance(error, SquareClientError):
            return Response({'code': 'checkout_uncertain', 'detail': 'Retain this purchase intent and try its status; do not start another purchase.'}, status=503)
        if isinstance(error, (CheckoutBusy, CheckoutConflict)):
            return Response({'code': 'checkout_pending', 'detail': str(error)}, status=409)
        return Response({'detail': str(error)}, status=400)


class SquareCheckoutIntentsView(SquareCheckoutBase):
    def get(self, request):
        try:
            config = term_configuration(environment=self.environment)
            return Response(term_disclosure(verify_payment_location(configured_client(environment=self.environment), config),
                billing_period=request.query_params.get('billing_period', 'monthly'), environment=self.environment))
        except (SquareDisabled, SquareConfigurationError, SquareClientError, CheckoutRejected) as error:
            return self.error(error)

    @sensitive_variables()
    def post(self, request):
        try:
            term_configuration(environment=self.environment)
            client = configured_client(environment=self.environment)  # Missing explicit transport reserves nothing.
            serializer = TermCheckoutConsentSerializer(data=request.data)
            serializer.is_valid(raise_exception=True)
            intent = reserve_term_checkout(parent=request.user, client=client, environment=self.environment, **serializer.validated_data)
            return Response(checkout_status(intent), status=200)
        except (SquareDisabled, SquareConfigurationError, SquareClientError, CheckoutRejected) as error:
            return self.error(error)


class SquareCheckoutStatusView(SquareCheckoutBase):
    throttle_scope = 'billing_status'
    requires_purchase = False

    def get(self, request, intent_id):
        try:
            intent = SquareCheckoutIntent.objects.get(pk=intent_id, parent=request.user, environment=self.environment)
            return Response(checkout_status(intent))
        except (SquareDisabled, SquareConfigurationError, SquareCheckoutIntent.DoesNotExist) as error:
            return self.error(error)


class SquareCheckoutConfirmView(SquareCheckoutBase):
    requires_purchase = False
    @sensitive_variables()
    def post(self, request, intent_id):
        try:
            serializer = TermCheckoutCardSerializer(data=request.data)
            serializer.is_valid(raise_exception=True)
            SquareCheckoutIntent.objects.get(pk=intent_id, parent=request.user, environment=self.environment)
            if any(serializer.validated_data.get(field) is not None
                   for field in ('source_id', 'verification_token', 'charge_source_id')):
                require_payment_parent(request.user, environment=self.environment)
                require_checkout_enabled(environment=self.environment)
            intent = confirm_term_checkout(parent=request.user, intent_id=intent_id,
                client=configured_client(environment=self.environment), environment=self.environment,
                allow_card_setup=getattr(request.auth, 'purpose', None) != 'manage', **serializer.validated_data)
            return Response(checkout_status(intent))
        except (SquareDisabled, SquareConfigurationError, CheckoutRejected, SquareClientError,
                SquareCheckoutIntent.DoesNotExist) as error:
            return self.error(error)


class SquareCheckoutPrepareCardView(SquareCheckoutBase):
    @sensitive_variables()
    def post(self, request, intent_id):
        try:
            term_configuration(environment=self.environment)
            serializer = TermPrepareCardSerializer(data=request.data)
            serializer.is_valid(raise_exception=True)
            intent = confirm_term_checkout(parent=request.user, intent_id=intent_id, prepare_only=True,
                client=configured_client(environment=self.environment), environment=self.environment, **serializer.validated_data)
            return Response({**checkout_status(intent), 'buyer_verification': {
                'card_id': intent.card_id, 'amount': term_plan_for_policy(intent.policy_id).amount_display,
                'currency': 'USD', 'intent': 'CHARGE',
                'customer_initiated': True}})
        except (SquareDisabled, SquareConfigurationError, CheckoutRejected, SquareClientError,
                SquareCheckoutIntent.DoesNotExist) as error:
            return self.error(error)


class SquareCheckoutCancelView(SquareCheckoutBase):
    requires_purchase = False
    @sensitive_variables()
    def post(self, request, intent_id):
        try:
            serializer = StopRenewalSerializer(data=request.data)
            serializer.is_valid(raise_exception=True)
            agreement = cancel_agreement(parent=request.user, intent_id=intent_id, environment=self.environment, **serializer.validated_data)
            return Response({'renewals_enabled': agreement.renewals_enabled,
                             'detail': 'Future renewals are stopped; already-paid coverage keeps its original end.'})
        except (SquareDisabled, SquareConfigurationError, CheckoutRejected, SquareContentAgreement.DoesNotExist) as error:
            return self.error(error)


class SquareCheckoutRestartView(SquareCheckoutBase):
    @sensitive_variables()
    def post(self, request, intent_id):
        try:
            serializer = TermCheckoutConsentSerializer(data=request.data)
            serializer.is_valid(raise_exception=True)
            intent = restart_unpaid_checkout(parent=request.user, intent_id=intent_id,
                client=configured_client(environment=self.environment), environment=self.environment, **serializer.validated_data)
            return Response(checkout_status(intent))
        except (SquareDisabled, SquareConfigurationError, CheckoutRejected, SquareClientError,
                SquareCheckoutIntent.DoesNotExist) as error:
            return self.error(error)
