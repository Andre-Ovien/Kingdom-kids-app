from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [('accounts', '0011_privatefamilyimportreceipt')]
    operations = [
        migrations.AddField(model_name='waitlistsubscriber', name=name, field=field)
        for name, field in (
            ('confirmation_sent_at', models.DateTimeField(blank=True, editable=False, null=True)),
            ('confirmation_claim_id', models.UUIDField(blank=True, editable=False, null=True)),
            ('confirmation_lease_until', models.DateTimeField(blank=True, editable=False, null=True)),
            ('confirmation_first_attempt_at', models.DateTimeField(blank=True, editable=False, null=True)),
        )
    ]
