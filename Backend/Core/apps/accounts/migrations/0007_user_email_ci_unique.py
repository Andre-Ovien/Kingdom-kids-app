from django.db import migrations, models
from django.db.models.functions import Lower


def normalize_existing_emails(apps, schema_editor):
    User = apps.get_model('accounts', 'User')
    normalized_by_id = {}
    owner_by_email = {}

    for user_id, email in User.objects.values_list('pk', 'email').iterator():
        normalized = (email or '').strip().lower()
        existing_owner = owner_by_email.get(normalized)
        if existing_owner is not None and existing_owner != user_id:
            raise RuntimeError(
                'Cannot add case-insensitive email uniqueness: duplicate '
                f'accounts exist for {normalized!r}.'
            )
        owner_by_email[normalized] = user_id
        normalized_by_id[user_id] = normalized

    for user_id, normalized in normalized_by_id.items():
        User.objects.filter(pk=user_id).update(email=normalized)


class Migration(migrations.Migration):
    dependencies = [
        ('accounts', '0006_waitlistsubscriber'),
    ]

    operations = [
        migrations.RunPython(
            normalize_existing_emails,
            migrations.RunPython.noop,
        ),
        migrations.AddConstraint(
            model_name='user',
            constraint=models.UniqueConstraint(
                Lower('email'),
                name='user_email_ci_unique',
            ),
        ),
    ]
