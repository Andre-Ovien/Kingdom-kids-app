from django.db import migrations


STORIES = (
    {
        'slug': 'david-and-goliath',
        'title': 'David & Goliath',
        'category': 'Courage',
        'summary': 'A young shepherd discovers that faith can be bigger than fear.',
        'body': (
            'David was a young shepherd who trusted God with his whole heart. '
            'When the giant Goliath frightened the army, David remembered how '
            'God had helped him protect his sheep before.\n\n'
            'With a sling, five smooth stones, and brave faith, David stepped '
            'forward. This story reminds kids that courage grows when we '
            'remember God is with us.\n\n'
            'David did not need heavy armor to do what was right. Children can '
            'learn that a faithful heart, a listening spirit, and trust in God '
            'are stronger than fear.\n\n'
            'When the battle was over, everyone saw that the victory belonged '
            'to God. David’s story helps kids remember that small hands can do '
            'brave things with God’s help.'
        ),
        'cover_asset_key': 'assets/images/david_and_goliath.png',
        'cover_focus_x': 0.2,
        'cover_focus_y': 0.1,
        'rating': 4.8,
        'review_count': 2000,
        'reading_time_minutes': 4,
        'is_featured': True,
        'sort_order': 1,
    },
    {
        'slug': 'jonah-and-the-big-fish',
        'title': 'Jonah and the Big Fish',
        'category': 'Mercy',
        'summary': 'Jonah learns that God’s mercy reaches farther than fear.',
        'body': (
            'Jonah tried to run away from what God asked him to do. A storm, a '
            'great fish, and three quiet days helped Jonah learn that God’s '
            'mercy is bigger than fear.\n\n'
            'This story helps kids talk about second chances, listening to God, '
            'and choosing kindness even when it is hard.\n\n'
            'Jonah learned that God cares for people we may not understand. '
            'Children can see that mercy is wide, patient, and full of hope.\n\n'
            'By the end, Jonah had to learn that God’s love reaches farther '
            'than his own plans. That lesson is still good for every heart.'
        ),
        'cover_asset_key': 'assets/images/jonah.jpg',
        'rating': 4.6,
        'review_count': 1500,
        'reading_time_minutes': 4,
        'is_featured': True,
        'sort_order': 2,
    },
    {
        'slug': 'crossing-the-red-sea',
        'title': 'Crossing the Red Sea',
        'category': 'Miracle',
        'summary': 'God makes a path when His people cannot see a way forward.',
        'body': (
            'The Israelites stood at the edge of the sea with danger behind '
            'them and no road ahead. God told Moses to lift his staff, and the '
            'water opened into a dry path.\n\n'
            'Kids will see that God can make a way when things feel impossible '
            'and that trusting Him can move us forward.\n\n'
            'Step by step, the people crossed safely. This story reminds kids '
            'that faith can begin with one small step on the path God opens.\n\n'
            'When they reached the other side, the people sang and celebrated. '
            'They remembered that God had rescued them with mighty love.'
        ),
        'cover_asset_key': 'assets/images/crossing_red_sea.webp',
        'cover_focus_x': -0.38,
        'rating': 4.9,
        'review_count': 3000,
        'reading_time_minutes': 4,
        'is_featured': True,
        'sort_order': 3,
    },
    {
        'slug': 'noah-builds-the-ark',
        'title': 'Noah Builds the Ark',
        'category': 'Faith',
        'summary': 'Noah listens to God and builds the ark one faithful step at a time.',
        'body': (
            'Noah loved God and listened carefully, even when the job seemed '
            'too big. God told Noah to build an ark because a great flood was '
            'coming, and Noah obeyed one step at a time.\n\n'
            'This story helps kids see that obedience matters. Noah trusted '
            'God, cared for his family, and welcomed the animals safely into '
            'the ark.\n\n'
            'After the rain, God placed a rainbow in the sky as a promise. Kids '
            'can remember that God keeps His word and watches over every family '
            'that trusts Him.\n\n'
            'At the end, Noah and his family stepped into a fresh new world. '
            'They praised God together and began again with thankful hearts.'
        ),
        'cover_asset_key': 'assets/images/noahs_ark.png',
        'cover_focus_x': -0.4,
        'rating': 4.7,
        'review_count': 1800,
        'reading_time_minutes': 5,
        'sort_order': 4,
    },
    {
        'slug': 'creation-week',
        'title': 'Creation Week',
        'category': 'Wonder',
        'summary': 'Seven days invite children to notice God’s good world with wonder.',
        'body': (
            'In the beginning, God made the heavens and the earth. Day by day, '
            'He filled the world with light, sky, land, seas, plants, stars, '
            'animals, and people.\n\n'
            'Creation Week invites kids to slow down and notice God’s good '
            'world with wonder, gratitude, and joy.\n\n'
            'Every flower, ocean, animal, and star points back to God’s care. '
            'Children can learn to thank Him for the beautiful things they see '
            'each day.\n\n'
            'The story ends with rest, showing that God’s work was good. It '
            'gives kids a gentle rhythm for wonder, work, worship, and peace.'
        ),
        'cover_asset_key': 'assets/images/creation_week.jpg',
        'rating': 4.9,
        'review_count': 2400,
        'reading_time_minutes': 5,
        'sort_order': 5,
    },
    {
        'slug': 'daniel-in-the-lions-den',
        'title': 'Daniel',
        'category': 'Courage',
        'summary': 'Daniel’s quiet trust stays strong in a dangerous place.',
        'body': (
            'Daniel kept praying to God even when it became dangerous. When he '
            'was thrown into the lions’ den, God protected him through the '
            'night.\n\n'
            'This story shows kids that faith can stay strong in hard places, '
            'and that God is near when we choose what is right.\n\n'
            'Daniel did not have to be loud to be brave. His quiet trust '
            'teaches children that prayer can give courage even when everyone '
            'else is afraid.\n\n'
            'When morning came, Daniel was safe. The king saw that Daniel’s God '
            'was powerful, faithful, and worthy of praise.'
        ),
        'cover_asset_key': 'assets/images/daniel.jpeg',
        'cover_focus_y': -0.12,
        'rating': 4.8,
        'review_count': 2100,
        'reading_time_minutes': 4,
        'sort_order': 6,
    },
    {
        'slug': 'moses-follows-god',
        'title': 'Moses',
        'category': 'Adventure',
        'summary': 'Moses learns that God can use ordinary people for brave work.',
        'body': (
            'Moses learned that God can use ordinary people for brave work. '
            'From the burning bush to leading God’s people, Moses had to trust '
            'God one step at a time.\n\n'
            'Kids will follow Moses as he listens, obeys, and discovers that '
            'God gives courage for the journey.\n\n'
            'Moses did not always feel ready, but God stayed with him. This '
            'helps children see that they can ask for help and still take the '
            'next brave step.\n\n'
            'Through each challenge, Moses learned to listen for God’s voice. '
            'His story reminds kids that leadership starts with obedience.'
        ),
        'cover_asset_key': 'assets/images/moses2.jpeg',
        'rating': 4.7,
        'review_count': 1700,
        'reading_time_minutes': 5,
        'sort_order': 7,
    },
    {
        'slug': 'esther-speaks-up',
        'title': 'Esther',
        'category': 'Bravery',
        'summary': 'Esther discovers that kindness and courage can work together.',
        'body': (
            'Esther became queen at a time when her people needed help. With '
            'wisdom and courage, she spoke up even though it was scary.\n\n'
            'Her story reminds kids that God can place us right where we are '
            'needed, and bravery can begin with one honest choice.\n\n'
            'Esther listened, waited, and chose the right moment to speak. Kids '
            'can learn that courage and wisdom often work together.\n\n'
            'Because Esther cared for others, her brave choice helped save many '
            'lives. Her story makes kindness feel strong.'
        ),
        'cover_asset_key': 'assets/images/esther.jpeg',
        'rating': 4.8,
        'review_count': 1900,
        'reading_time_minutes': 4,
        'sort_order': 8,
    },
)


VOICES = (
    {
        'avatar_key': 'lion',
        'voice_key': 'kai',
        'display_name': 'Kai',
        'voice_description': 'Warm, brave, and adventurous',
        'locale': 'en-GB',
        'speech_rate': 0.42,
        'pitch': 0.92,
    },
    {
        'avatar_key': 'dove',
        'voice_key': 'nia',
        'display_name': 'Nia',
        'voice_description': 'Gentle, calm, and comforting',
        'locale': 'en-NG',
        'speech_rate': 0.40,
        'pitch': 1.04,
    },
    {
        'avatar_key': 'rainbow',
        'voice_key': 'zuri',
        'display_name': 'Zuri',
        'voice_description': 'Bright, joyful, and energetic',
        'locale': 'en-US',
        'speech_rate': 0.48,
        'pitch': 1.12,
    },
)


def seed_catalogue(apps, schema_editor):
    Story = apps.get_model('stories', 'Story')
    NarratorVoice = apps.get_model('stories', 'NarratorVoice')
    StoryNarration = apps.get_model('stories', 'StoryNarration')

    stories = [Story.objects.create(**story) for story in STORIES]
    voices = [NarratorVoice.objects.create(**voice) for voice in VOICES]
    StoryNarration.objects.bulk_create(
        StoryNarration(story=story, narrator=voice, status='device_tts')
        for story in stories
        for voice in voices
    )


def unseed_catalogue(apps, schema_editor):
    Story = apps.get_model('stories', 'Story')
    NarratorVoice = apps.get_model('stories', 'NarratorVoice')
    Story.objects.filter(slug__in=[story['slug'] for story in STORIES]).delete()
    NarratorVoice.objects.filter(
        avatar_key__in=[voice['avatar_key'] for voice in VOICES]
    ).delete()


class Migration(migrations.Migration):
    dependencies = [('stories', '0001_initial')]

    operations = [migrations.RunPython(seed_catalogue, unseed_catalogue)]
