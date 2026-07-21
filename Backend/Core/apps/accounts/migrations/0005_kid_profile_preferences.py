from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):
    dependencies = [
        ('accounts', '0004_kid_profile_creation_operation_id'),
    ]

    operations = [
        migrations.CreateModel(
            name='KidProfilePreferences',
            fields=[
                (
                    'id',
                    models.BigAutoField(
                        auto_created=True,
                        primary_key=True,
                        serialize=False,
                        verbose_name='ID',
                    ),
                ),
                (
                    'story_text_scale',
                    models.CharField(
                        choices=[
                            ('comfortable', 'Comfortable'),
                            ('large', 'Large'),
                            ('extra_large', 'Extra large'),
                        ],
                        default='comfortable',
                        max_length=16,
                    ),
                ),
                ('narration_enabled', models.BooleanField(default=True)),
                ('updated_at', models.DateTimeField(auto_now=True)),
                (
                    'profile',
                    models.OneToOneField(
                        on_delete=django.db.models.deletion.CASCADE,
                        related_name='preferences',
                        to='accounts.kidprofile',
                    ),
                ),
            ],
            options={
                'verbose_name': 'kid profile preferences',
                'verbose_name_plural': 'kid profile preferences',
            },
        ),
    ]
