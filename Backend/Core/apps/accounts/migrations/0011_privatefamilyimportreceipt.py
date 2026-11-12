from django.conf import settings
from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):
    dependencies = [('accounts', '0010_account_deletion_challenge')]
    operations = [migrations.CreateModel(
        name='PrivateFamilyImportReceipt',
        fields=[
            ('id', models.UUIDField(editable=False, primary_key=True, serialize=False)),
            ('digest', models.CharField(max_length=64)),
            ('completed_at', models.DateTimeField(auto_now_add=True)),
            ('parent', models.ForeignKey(null=True, on_delete=django.db.models.deletion.SET_NULL,
                related_name='private_family_import_receipts', to=settings.AUTH_USER_MODEL)),
        ],
    )]
