"""Hide New Testament stories without deleting content or earned activity."""
from django.db import migrations


NEW_TESTAMENT_STORY_SLUGS = ('lost-sheep', 'good-samaritan')


def unpublish_new_testament_stories(apps, schema_editor):
    Story = apps.get_model('stories', 'Story')
    Story.objects.using(schema_editor.connection.alias).filter(
        slug__in=NEW_TESTAMENT_STORY_SLUGS,
        is_published=True,
    ).update(is_published=False)


class Migration(migrations.Migration):
    dependencies = [('stories', '0010_storybook_cover_artwork')]
    # A downgrade must not silently republish editorially hidden stories.
    # All source content and historical progress remain available to editors.
    operations = [migrations.RunPython(
        unpublish_new_testament_stories, migrations.RunPython.noop,
    )]
