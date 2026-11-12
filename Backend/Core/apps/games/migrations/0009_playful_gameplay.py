from django.db import migrations


ANIMALS = (
    ('lion', 'Lion'), ('elephant', 'Elephant'), ('giraffe', 'Giraffe'),
    ('zebra', 'Zebra'), ('sheep', 'Sheep'), ('monkey', 'Monkey'),
    ('rabbit', 'Rabbit'), ('panda', 'Panda'), ('tiger', 'Tiger'),
    ('penguin', 'Penguin'), ('hippo', 'Hippo'), ('bear', 'Bear'),
)


def ark_config(pair_count, time_limit, goal):
    animals = ANIMALS[:pair_count]
    return {
        'mode': 'ark_boarding',
        'time_limit_seconds': time_limit,
        'goal_pairs': goal,
        'left_items': [
            {'id': f'{species}-1', 'label': label, 'asset_key': f'animal:{species}'}
            for species, label in animals
        ],
        'right_items': [
            {'id': f'{species}-2', 'label': label, 'asset_key': f'animal:{species}'}
            for species, label in reversed(animals)
        ],
        'expected_pairs': {f'{species}-1': f'{species}-2' for species, _ in animals},
    }


INSTRUCTIONS = {
    'david-sling-shot': (
        'Pull back the stone pouch, aim at Goliath, and release. You have three stones.',
        'Pull, aim, and release your stone toward Goliath. Find a clear shot past the shields.',
        'Pull back and line up a careful shot at Goliath. Make your two stones count!',
    ),
    'jonah-ocean-maze': (
        'Touch the boat and trace a safe route to the calm shore. Avoid the rocky water.',
        'Trace a route from the boat through the storm to the calm shore.',
        'Trace a safe route to the big fish. Slide back along your trail if you need to turn.',
    ),
    'red-sea-path': (
        'Touch the family and trace the dry route across the sea to the far shore.',
        'Trace the safe sandy route between the waves. Turn back along your trail to change direction.',
        'Draw a safe route for everyone to cross the sea and reach the far shore.',
    ),
    'daniel-memory': (
        'Take a quick peek at the story cards, then tap to find the matching pairs.',
        'Remember the quick peek! Turn over two cards at a time to find four story pairs.',
        'Study the story cards during the peek, then find all five pairs with clever flips.',
    ),
    'creation-order': (
        'Build the first three days: drag each creation moment into its place.',
        'Arrange the first five creation moments. Drag to move a day into order.',
        'Build a wonderful creation week by placing all seven days in order.',
    ),
    'esther-quiz': (
        'Discover Esther’s story. Choose an answer, then move to the next question.',
        'Think about Esther’s brave choice. Pick your answer for each story question.',
        'Choose courage and kindness. Pick the answer that best fits Esther’s story.',
    ),
}


def refresh_gameplay(apps, schema_editor):
    Game = apps.get_model('games', 'Game')
    GameLevel = apps.get_model('games', 'GameLevel')
    alias = schema_editor.connection.alias
    games = Game.objects.using(alias)
    levels = GameLevel.objects.using(alias)
    ark = games.filter(slug='ark-animal-match').first()
    if ark:
        games.filter(pk=ark.pk).update(
            title='Noah’s Ark Rescue',
            subtitle='Two by two. Ready, set, aboard!',
            description=(
                'Help Noah bring matching animal friends aboard the ark. '
                'Drag each animal to its waiting partner and rescue as many pairs '
                'as you can before the round ends.'
            ),
        )
        for number, title, count, seconds, goal in (
            (1, 'All Aboard!', 8, 45, 5),
            (2, 'Animal Rush', 10, 60, 7),
            (3, 'The Grand Rescue', 12, 60, 9),
        ):
            # Update the authored content in place: attempts, best scores,
            # level UUIDs, and each child's existing unlocks stay intact.
            levels.filter(game=ark, level_number=number).update(
                title=title,
                instructions=(
                    f'Drag animals to their matching partners aboard the ark. '
                    f'Rescue at least {goal} pairs in {seconds} seconds!'
                ),
                config=ark_config(count, seconds, goal),
            )
    for slug, instructions in INSTRUCTIONS.items():
        for number, text in enumerate(instructions, start=1):
            levels.filter(game__slug=slug, level_number=number).update(instructions=text)


class Migration(migrations.Migration):
    dependencies = [('games', '0008_puzzle_quest')]
    operations = [migrations.RunPython(refresh_gameplay, migrations.RunPython.noop)]
