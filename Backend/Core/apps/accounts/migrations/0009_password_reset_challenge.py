import uuid

import django.db.models.deletion
from django.conf import settings
from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [
        ('accounts', '0008_kid_profile_streak_timezone'),
    ]

    operations = [
        migrations.CreateModel(
            name='PasswordResetChallenge',
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
                ('attempt_count', models.PositiveSmallIntegerField(default=0)),
                ('max_attempts', models.PositiveSmallIntegerField(default=5)),
                ('consumed_at', models.DateTimeField(blank=True, null=True)),
                ('invalidated_at', models.DateTimeField(blank=True, null=True)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                (
                    'user',
                    models.ForeignKey(
                        on_delete=django.db.models.deletion.CASCADE,
                        related_name='password_reset_challenges',
                        to=settings.AUTH_USER_MODEL,
                    ),
                ),
            ],
            options={
                'ordering': ('-created_at',),
                'indexes': [
                    models.Index(
                        fields=['user', '-created_at'],
                        name='pwd_reset_user_created',
                    ),
                    models.Index(
                        fields=['expires_at'],
                        name='pwd_reset_expires',
                    ),
                ],
                'constraints': [
                    models.CheckConstraint(
                        condition=(
                            models.Q(max_attempts__gt=0)
                            & models.Q(
                                attempt_count__lte=models.F('max_attempts')
                            )
                        ),
                        name='pwd_reset_attempts_valid',
                    ),
                    models.UniqueConstraint(
                        fields=('user',),
                        condition=(
                            models.Q(consumed_at__isnull=True)
                            & models.Q(invalidated_at__isnull=True)
                        ),
                        name='unique_active_password_reset',
                    ),
                ],
            },
        ),
    ]
