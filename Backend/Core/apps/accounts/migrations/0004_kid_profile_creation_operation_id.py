from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [
        ('accounts', '0003_user_email_verification_lockout'),
    ]

    operations = [
        migrations.AddField(
            model_name='kidprofile',
            name='creation_operation_id',
            field=models.UUIDField(blank=True, editable=False, null=True),
        ),
        migrations.AddConstraint(
            model_name='kidprofile',
            constraint=models.UniqueConstraint(
                fields=('parent', 'creation_operation_id'),
                name='unique_kid_profile_creation_op',
            ),
        ),
    ]
