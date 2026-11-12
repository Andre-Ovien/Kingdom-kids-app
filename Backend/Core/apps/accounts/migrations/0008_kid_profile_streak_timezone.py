from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [
        ('accounts', '0007_user_email_ci_unique'),
    ]

    operations = [
        migrations.AddField(
            model_name='kidprofilepreferences',
            name='streak_timezone_offset_minutes',
            field=models.SmallIntegerField(blank=True, null=True),
        ),
        migrations.AddConstraint(
            model_name='kidprofilepreferences',
            constraint=models.CheckConstraint(
                condition=(
                    models.Q(streak_timezone_offset_minutes__isnull=True)
                    | models.Q(
                        streak_timezone_offset_minutes__gte=-840,
                        streak_timezone_offset_minutes__lte=840,
                    )
                ),
                name='kid_preferences_streak_timezone_valid',
            ),
        ),
    ]
