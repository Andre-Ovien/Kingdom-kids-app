from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [
        ('accounts', '0002_email_verification'),
    ]

    operations = [
        migrations.AddField(
            model_name='user',
            name='email_verification_failed_attempts',
            field=models.PositiveIntegerField(default=0),
        ),
        migrations.AddField(
            model_name='user',
            name='email_verification_failure_window_started_at',
            field=models.DateTimeField(blank=True, null=True),
        ),
        migrations.AddField(
            model_name='user',
            name='email_verification_locked_until',
            field=models.DateTimeField(blank=True, null=True),
        ),
    ]
