import json

from django.db import DatabaseError
from django.utils import timezone
from django.views.decorators.debug import sensitive_variables
from rest_framework.exceptions import NotFound, ParseError
from rest_framework.parsers import BaseParser
from rest_framework.permissions import AllowAny, IsAuthenticated
from rest_framework.response import Response
from rest_framework.throttling import AnonRateThrottle, UserRateThrottle
from rest_framework.views import APIView

from apps.accounts.authentication import VerifiedEmailJWTAuthentication
from .browser_handoff import HandoffUnavailable, issue_handoff, redeem_handoff
from .checkout_auth import CheckoutSessionAuthentication
from .handoff_models import ParentCheckoutHandoff


class SmallJSONParser(BaseParser):
    media_type = 'application/json'

    def parse(self, stream, media_type=None, parser_context=None):
        def unique_pairs(items):
            result = {}
            for key, value in items:
                if key in result:
                    raise ValueError
                result[key] = value
            return result
        try:
            raw = stream.read(2049)
            if len(raw) > 2048:
                raise ValueError
            value = json.loads(raw.decode('utf-8'), object_pairs_hook=unique_pairs)
            if not isinstance(value, dict):
                raise ValueError
            return value
        except (ValueError, UnicodeError):
            raise ParseError('A small JSON object is required.') from None


class HandoffParentThrottle(UserRateThrottle):
    scope = 'checkout_handoff_parent'
    rate = '5/minute'


class HandoffRedeemThrottle(AnonRateThrottle):
    scope = 'checkout_handoff_redeem'
    rate = '20/minute'


class HandoffBase(APIView):
    parser_classes = (SmallJSONParser,)

    def finalize_response(self, request, response, *args, **kwargs):
        response = super().finalize_response(request, response, *args, **kwargs)
        response['Cache-Control'] = 'no-store, private'
        response['Referrer-Policy'] = 'no-referrer'
        response['Pragma'] = 'no-cache'
        return response

    def unavailable(self):
        return Response({'detail': 'Checkout link is unavailable or expired.'}, status=400)


class CheckoutHandoffIssueView(HandoffBase):
    authentication_classes = (VerifiedEmailJWTAuthentication,)
    permission_classes = (IsAuthenticated,)
    throttle_classes = (HandoffParentThrottle,)

    @sensitive_variables()
    def post(self, request):
        from django.conf import settings
        if getattr(settings, 'PARENT_CHECKOUT_HANDOFF_ENABLED', False) is not True:
            raise NotFound()
        value = request.data
        if set(value) not in ({'purpose'}, {'purpose', 'billing_period'}):
            return self.unavailable()
        try:
            result = issue_handoff(parent=request.user, access_expiry=request.auth.get('exp'),
                purpose=value.get('purpose'), billing_period=value.get('billing_period'), request=request)
            return Response(result, status=201)
        except (HandoffUnavailable, DatabaseError, AttributeError):
            return self.unavailable()


class CheckoutHandoffRedeemView(HandoffBase):
    authentication_classes = ()
    permission_classes = (AllowAny,)
    throttle_classes = (HandoffRedeemThrottle,)

    @sensitive_variables()
    def post(self, request):
        from django.conf import settings
        if getattr(settings, 'PARENT_CHECKOUT_HANDOFF_ENABLED', False) is not True:
            raise NotFound()
        if set(request.data) != {'code'}:
            return self.unavailable()
        try:
            return Response(redeem_handoff(code=request.data['code'], request=request))
        except (HandoffUnavailable, DatabaseError):
            return self.unavailable()


class CheckoutHandoffRevokeView(HandoffBase):
    authentication_classes = (CheckoutSessionAuthentication,)
    permission_classes = (IsAuthenticated,)
    throttle_classes = (HandoffParentThrottle,)

    @sensitive_variables()
    def post(self, request):
        if not isinstance(request.auth, ParentCheckoutHandoff) or request.data:
            return self.unavailable()
        ParentCheckoutHandoff.objects.filter(pk=request.auth.pk, parent=request.user,
                                             revoked_at__isnull=True).update(revoked_at=timezone.now())
        return Response(status=204)
