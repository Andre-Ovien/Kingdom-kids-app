import uuid
import django.db.models.deletion
import django.utils.timezone
from django.conf import settings
from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [('billing', '0010_billing_job_state'), migrations.swappable_dependency(settings.AUTH_USER_MODEL)]
    operations = [migrations.CreateModel(
        name='ParentCheckoutHandoff',
        fields=[
            ('id', models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False, serialize=False)),
            ('environment', models.CharField(max_length=16, default='sandbox')),
            ('purpose', models.CharField(max_length=16)),
            ('billing_period', models.CharField(max_length=16, blank=True)),
            ('origin', models.URLField(max_length=512)),
            ('code_digest', models.CharField(max_length=64, unique=True)),
            ('parent_auth_fingerprint', models.CharField(max_length=64)),
            ('created_at', models.DateTimeField(default=django.utils.timezone.now)),
            ('expires_at', models.DateTimeField()),
            ('origin_access_expires_at', models.DateTimeField()),
            ('consumed_at', models.DateTimeField(null=True, blank=True)),
            ('session_expires_at', models.DateTimeField(null=True, blank=True)),
            ('revoked_at', models.DateTimeField(null=True, blank=True)),
            ('parent', models.ForeignKey(to=settings.AUTH_USER_MODEL, on_delete=django.db.models.deletion.CASCADE,
                                         related_name='checkout_handoffs')),
        ],
        options={
            'indexes': [models.Index(fields=('expires_at',), name='checkout_handoff_expiry'),
                        models.Index(fields=('parent', 'environment', 'created_at'), name='checkout_handoff_parent')],
            'constraints': [
                models.CheckConstraint(condition=models.Q(environment__in=('sandbox', 'production')),
                                       name='checkout_handoff_environment'),
                models.CheckConstraint(condition=(models.Q(purpose='purchase', billing_period__in=('monthly', 'yearly'))
                    | models.Q(purpose='manage', billing_period='')), name='checkout_handoff_purpose'),
                models.CheckConstraint(condition=models.Q(expires_at__gt=models.F('created_at')),
                                       name='checkout_handoff_positive_ttl'),
                models.CheckConstraint(condition=(models.Q(session_expires_at__isnull=True)
                    | models.Q(session_expires_at__lte=models.F('origin_access_expires_at'))),
                                       name='checkout_session_origin_bound'),
            ],
        },
    )]
