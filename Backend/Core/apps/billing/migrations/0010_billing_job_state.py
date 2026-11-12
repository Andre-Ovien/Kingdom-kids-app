from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [('billing', '0009_payment_environment_isolation')]

    operations = [migrations.CreateModel(
        name='SquareBillingJobState',
        fields=[
            ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
            ('environment', models.CharField(max_length=16)),
            ('merchant_sha256', models.CharField(max_length=64)),
            ('lane', models.CharField(max_length=16)),
            ('cursor', models.CharField(blank=True, max_length=64)),
            ('started_at', models.DateTimeField(blank=True, null=True)),
            ('heartbeat_at', models.DateTimeField(blank=True, null=True)),
            ('finished_at', models.DateTimeField(blank=True, null=True)),
            ('last_completed_at', models.DateTimeField(blank=True, null=True)),
            ('last_finished_outcome', models.CharField(blank=True, max_length=32)),
            ('last_full_scan_at', models.DateTimeField(blank=True, null=True)),
            ('outcome', models.CharField(blank=True, max_length=32)),
            ('counts', models.JSONField(default=dict)),
        ],
        options={'constraints': [
            models.UniqueConstraint(fields=('environment', 'merchant_sha256', 'lane'), name='square_job_scope_lane'),
            models.CheckConstraint(condition=models.Q(environment__in=('sandbox', 'production')),
                name='square_job_environment'),
            models.CheckConstraint(condition=models.Q(lane__in=('receipts', 'terms', 'renewals')),
                name='square_job_known_lane'),
        ]},
    )]
