"""Bounded public contact form: one operator inbox, never a public mail relay."""
from django.conf import settings
from django.core.mail import EmailMultiAlternatives
from django.utils.crypto import salted_hmac
from django.utils.html import format_html
from django.views.decorators.debug import sensitive_variables
from rest_framework import serializers, status
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from rest_framework.throttling import ScopedRateThrottle
from rest_framework.views import APIView

from Core.email_capability import require_email_delivery


class ContactSerializer(serializers.Serializer):
    title = serializers.CharField(min_length=2, max_length=120)
    email = serializers.EmailField(max_length=254)
    message = serializers.CharField(min_length=10, max_length=5000)
    website = serializers.CharField(required=False, allow_blank=True, max_length=200, write_only=True)
    request_id = serializers.UUIDField(required=False, write_only=True)

    def validate_title(self, value):
        if any(ord(c) < 32 or ord(c) == 127 for c in value):
            raise serializers.ValidationError('Enter a single-line subject.')
        return value


class ContactView(APIView):
    permission_classes = (AllowAny,)
    throttle_classes = (ScopedRateThrottle,)
    throttle_scope = 'contact'

    def finalize_response(self, request, response, *args, **kwargs):
        response = super().finalize_response(request, response, *args, **kwargs)
        response['Cache-Control'] = 'no-store'
        return response

    @sensitive_variables()
    def post(self, request):
        serializer = ContactSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        data = serializer.validated_data
        accepted = {'detail': 'Thanks. Your message has been received.'}
        if data.get('website'):
            return Response(accepted, status=status.HTTP_202_ACCEPTED)
        require_email_delivery()
        recipient = getattr(settings, 'CONTACT_RECIPIENT_EMAIL', '')
        if not recipient:
            return self.unavailable()
        # Fixed recipient; a visitor may only supply the validated Reply-To.
        # Stable content/request key deduplicates an uncertain identical retry
        # within Resend's documented 24-hour idempotency window.
        operation = salted_hmac('website-contact', '\0'.join([
            str(data.get('request_id', '')), data['title'], data['email'].lower(), data['message'], recipient,
        ])).hexdigest()
        message = EmailMultiAlternatives(
            subject='Website contact: ' + data['title'],
            body=f"Subject: {data['title']}\nFrom: {data['email']}\n\n{data['message']}",
            from_email=settings.DEFAULT_FROM_EMAIL, to=[recipient], reply_to=[data['email']],
            headers={'Resend-Idempotency-Key': 'website-contact/' + operation},
        )
        message.attach_alternative(format_html(
            '<h2>{}</h2><p>Reply to: {}</p><p style="white-space:pre-wrap">{}</p>',
            data['title'], data['email'], data['message'],
        ), 'text/html')
        try:
            if message.send(fail_silently=False) != 1:
                return self.unavailable()
        except Exception:
            return self.unavailable()
        return Response(accepted, status=status.HTTP_202_ACCEPTED)

    @staticmethod
    def unavailable():
        return Response({'code': 'contact_unavailable',
                         'detail': 'We could not send your message. Please try again later.'},
                        status=status.HTTP_503_SERVICE_UNAVAILABLE)
