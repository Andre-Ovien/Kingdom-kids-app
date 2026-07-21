# Generated for the Kingdom Kids game engine.

import django.db.models.deletion
import uuid
from django.db import migrations, models


class Migration(migrations.Migration):

    initial = True

    dependencies = [
        ('accounts', '0004_kid_profile_creation_operation_id'),
    ]

    operations = [
        migrations.CreateModel(
            name='Game',
            fields=[
                ('id', models.UUIDField(default=uuid.uuid4, editable=False, primary_key=True, serialize=False)),
                ('slug', models.SlugField(max_length=120, unique=True)),
                ('title', models.CharField(max_length=120)),
                ('subtitle', models.CharField(max_length=180)),
                ('description', models.TextField()),
                ('game_type', models.CharField(choices=[('quiz', 'Quiz'), ('memory', 'Memory cards'), ('ordering', 'Ordering'), ('matching', 'Matching'), ('maze', 'Maze'), ('path', 'Path finding'), ('aim', 'Aim')], max_length=16)),
                ('cover_asset_key', models.CharField(max_length=200)),
                ('accent_color', models.CharField(default='#6C5CE7', max_length=9)),
                ('icon_key', models.CharField(default='sparkles', max_length=40)),
                ('is_published', models.BooleanField(default=True)),
                ('sort_order', models.PositiveSmallIntegerField(default=0)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('updated_at', models.DateTimeField(auto_now=True)),
            ],
            options={'ordering': ('sort_order', 'title')},
        ),
        migrations.CreateModel(
            name='GameLevel',
            fields=[
                ('id', models.UUIDField(default=uuid.uuid4, editable=False, primary_key=True, serialize=False)),
                ('level_number', models.PositiveSmallIntegerField()),
                ('title', models.CharField(max_length=120)),
                ('instructions', models.CharField(max_length=240)),
                ('config', models.JSONField(default=dict)),
                ('max_score', models.PositiveSmallIntegerField(default=100)),
                ('star_thresholds', models.JSONField(default=list)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('updated_at', models.DateTimeField(auto_now=True)),
                ('game', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='levels', to='games.game')),
            ],
            options={
                'ordering': ('level_number',),
                'constraints': [models.UniqueConstraint(fields=('game', 'level_number'), name='unique_game_level_number')],
            },
        ),
        migrations.CreateModel(
            name='KidGameProgress',
            fields=[
                ('id', models.UUIDField(default=uuid.uuid4, editable=False, primary_key=True, serialize=False)),
                ('highest_completed_level', models.PositiveSmallIntegerField(default=0)),
                ('total_stars', models.PositiveSmallIntegerField(default=0)),
                ('level_progress', models.JSONField(default=dict)),
                ('last_played_at', models.DateTimeField(blank=True, null=True)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('updated_at', models.DateTimeField(auto_now=True)),
                ('game', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='kid_progress', to='games.game')),
                ('profile', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='game_progress', to='accounts.kidprofile')),
            ],
            options={
                'ordering': ('game__sort_order',),
                'constraints': [models.UniqueConstraint(fields=('profile', 'game'), name='unique_kid_game_progress')],
            },
        ),
        migrations.CreateModel(
            name='GameAttempt',
            fields=[
                ('id', models.UUIDField(default=uuid.uuid4, editable=False, primary_key=True, serialize=False)),
                ('operation_id', models.UUIDField()),
                ('submitted_result', models.JSONField(default=dict)),
                ('completed', models.BooleanField(default=False)),
                ('score', models.PositiveSmallIntegerField(default=0)),
                ('stars', models.PositiveSmallIntegerField(default=0)),
                ('feedback', models.CharField(max_length=240)),
                ('evaluation', models.JSONField(default=dict)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('game', models.ForeignKey(on_delete=django.db.models.deletion.PROTECT, related_name='attempts', to='games.game')),
                ('level', models.ForeignKey(on_delete=django.db.models.deletion.PROTECT, related_name='attempts', to='games.gamelevel')),
                ('profile', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='game_attempts', to='accounts.kidprofile')),
            ],
            options={
                'ordering': ('-created_at',),
                'indexes': [models.Index(fields=['profile', 'game', '-created_at'], name='game_attempt_profile_game')],
                'constraints': [models.UniqueConstraint(fields=('profile', 'operation_id'), name='unique_kid_game_operation')],
            },
        ),
    ]
