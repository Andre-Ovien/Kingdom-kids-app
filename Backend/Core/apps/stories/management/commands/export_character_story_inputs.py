"""Export published story text for the isolated local voice runtime."""

import json
import re
from pathlib import Path

from django.conf import settings
from django.core.management.base import BaseCommand, CommandError

from apps.stories.models import Story


class Command(BaseCommand):
    help = 'Export published story text to the local character narration input directory.'

    def handle(self, *args, **options):
        directory = Path(settings.MEDIA_ROOT) / 'character_narration' / 'story_inputs'
        stories = list(Story.objects.filter(is_published=True))
        if any(not re.fullmatch(r'[a-z0-9]+(?:-[a-z0-9]+)*', story.slug) for story in stories):
            raise CommandError('Voice input export requires safe lowercase story slugs.')
        directory.mkdir(parents=True, exist_ok=True)
        for story in stories:
            path = directory / f'{story.slug}.json'
            temporary = path.with_suffix('.json.tmp')
            temporary.write_text(
                json.dumps(
                    {'slug': story.slug, 'title': story.title, 'body': story.body},
                    ensure_ascii=False,
                    indent=2,
                ) + '\n',
                encoding='utf-8',
            )
            temporary.replace(path)
        self.stdout.write(self.style.SUCCESS(f'Exported {len(stories)} published stories.'))
