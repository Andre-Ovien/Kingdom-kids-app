import uuid

import django.db.models.deletion
from django.conf import settings
from django.db import migrations, models
from django.utils import timezone


def mark_existing_users_verified(apps, schema_editor):
    User = apps.get_model('accounts', 'User')
    User.objects.filter(email_verified_at__isnull=True).update(
        email_verified_at=timezone.now()
    )


class Migration(migrations.Migration):
    dependencies = [
        ('accounts', '0001_initial'),
    ]

    operations = [
        migrations.AddField(
            model_name='user',
            name='email_verified_at',
            field=models.DateTimeField(blank=True, null=True),
        ),
        migrations.RunPython(mark_existing_users_verified, migrations.RunPython.noop),
        migrations.CreateModel(
            name='EmailVerificationChallenge',
            fields=[
                (
                    'id',
                    models.UUIDField(
                        default=uuid.uuid4,
                        editable=False,
                        primary_key=True,
                        serialize=False,
                    ),
                ),
                ('code_digest', models.CharField(max_length=64)),
                ('expires_at', models.DateTimeField()),
                ('resend_available_at', models.DateTimeField()),
                ('attempt_count', models.PositiveSmallIntegerField(default=0)),
                ('max_attempts', models.PositiveSmallIntegerField(default=5)),
                ('consumed_at', models.DateTimeField(blank=True, null=True)),
                ('invalidated_at', models.DateTimeField(blank=True, null=True)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                (
                    'user',
                    models.ForeignKey(
                        on_delete=django.db.models.deletion.CASCADE,
                        related_name='email_verification_challenges',
                        to=settings.AUTH_USER_MODEL,
                    ),
                ),
            ],
            options={
                'ordering': ('-created_at',),
                'indexes': [
                    models.Index(
                        fields=['user', '-created_at'],
                        name='email_verify_user_created',
                    ),
                    models.Index(
                        fields=['expires_at'],
                        name='email_verify_expires',
                    ),
                ],
            },
        ),
    ]
