import apps.stories.models
import django.core.validators
from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [
        ('stories', '0005_narratorvoice_sample_audio'),
    ]

    operations = [
        migrations.AlterField(
            model_name='narratorvoice',
            name='sample_audio',
            field=models.FileField(
                blank=True,
                max_length=255,
                upload_to='voice_auditions/',
                validators=[
                    django.core.validators.FileExtensionValidator(
                        allowed_extensions=('mp3', 'm4a', 'aac', 'wav'),
                    ),
                    apps.stories.models.validate_audio_upload,
                ],
            ),
        ),
        migrations.AlterField(
            model_name='narratorvoice',
            name='sample_url',
            field=models.URLField(
                blank=True,
                null=True,
                validators=[
                    apps.stories.models.validate_owned_https_media_url,
                ],
            ),
        ),
        migrations.AlterField(
            model_name='story',
            name='cover_image_url',
            field=models.URLField(
                blank=True,
                null=True,
                validators=[
                    apps.stories.models.validate_owned_https_media_url,
                ],
            ),
        ),
        migrations.AlterField(
            model_name='storynarration',
            name='audio_url',
            field=models.URLField(
                blank=True,
                null=True,
                validators=[
                    apps.stories.models.validate_owned_https_media_url,
                ],
            ),
        ),
    ]
