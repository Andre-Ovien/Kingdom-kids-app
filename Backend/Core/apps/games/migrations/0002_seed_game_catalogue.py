from django.db import migrations


GAME_SLUGS = (
    'ark-animal-match',
    'creation-order',
    'david-sling-shot',
    'jonah-ocean-maze',
    'red-sea-path',
    'daniel-memory',
    'esther-quiz',
    'moses-match',
)


def item(item_id, label, emoji):
    return {'id': item_id, 'label': label, 'asset_key': emoji}


def question(question_id, prompt, options, correct):
    return {
        'id': question_id,
        'prompt': prompt,
        'options': [
            {'id': option_id, 'text': text}
            for option_id, text in options
        ],
        'correct_option_id': correct,
    }


def memory_cards(pairs):
    cards = []
    for match_key, first, second, emoji in pairs:
        cards.extend(
            (
                {'id': f'{match_key}-a', 'label': first, 'asset_key': emoji, 'match_key': match_key},
                {'id': f'{match_key}-b', 'label': second, 'asset_key': emoji, 'match_key': match_key},
            )
        )
    return cards


GAMES = (
    {
        'slug': 'ark-animal-match',
        'title': 'Match the Ark Animals',
        'subtitle': 'Bring every animal to its partner!',
        'description': 'Pair the animals that entered Noah\'s ark two by two and fill the boat with happy creatures.',
        'game_type': 'matching',
        'cover_asset_key': 'assets/images/noahs_ark.png',
        'accent_color': '#3F8EFC',
        'icon_key': 'pets',
        'sort_order': 1,
        'levels': (
            {
                'title': 'Little Paws',
                'instructions': 'Connect each animal to its matching friend.',
                'config': {
                    'left_items': [item('lion-1', 'Lion', '🦁'), item('elephant-1', 'Elephant', '🐘'), item('giraffe-1', 'Giraffe', '🦒')],
                    'right_items': [item('giraffe-2', 'Giraffe', '🦒'), item('lion-2', 'Lion', '🦁'), item('elephant-2', 'Elephant', '🐘')],
                    'expected_pairs': {'lion-1': 'lion-2', 'elephant-1': 'elephant-2', 'giraffe-1': 'giraffe-2'},
                },
            },
            {
                'title': 'Feathers and Fur',
                'instructions': 'Find four more animal partners for the ark.',
                'config': {
                    'left_items': [item('dove-1', 'Dove', '🕊️'), item('monkey-1', 'Monkey', '🐒'), item('zebra-1', 'Zebra', '🦓'), item('sheep-1', 'Sheep', '🐑')],
                    'right_items': [item('sheep-2', 'Sheep', '🐑'), item('zebra-2', 'Zebra', '🦓'), item('dove-2', 'Dove', '🕊️'), item('monkey-2', 'Monkey', '🐒')],
                    'expected_pairs': {'dove-1': 'dove-2', 'monkey-1': 'monkey-2', 'zebra-1': 'zebra-2', 'sheep-1': 'sheep-2'},
                },
            },
            {
                'title': 'The Grand Parade',
                'instructions': 'Complete the biggest animal parade yet!',
                'config': {
                    'left_items': [item('panda-1', 'Panda', '🐼'), item('tiger-1', 'Tiger', '🐯'), item('hippo-1', 'Hippo', '🦛'), item('penguin-1', 'Penguin', '🐧'), item('camel-1', 'Camel', '🐫')],
                    'right_items': [item('camel-2', 'Camel', '🐫'), item('hippo-2', 'Hippo', '🦛'), item('panda-2', 'Panda', '🐼'), item('penguin-2', 'Penguin', '🐧'), item('tiger-2', 'Tiger', '🐯')],
                    'expected_pairs': {'panda-1': 'panda-2', 'tiger-1': 'tiger-2', 'hippo-1': 'hippo-2', 'penguin-1': 'penguin-2', 'camel-1': 'camel-2'},
                },
            },
        ),
    },
    {
        'slug': 'creation-order',
        'title': 'Creation Order',
        'subtitle': 'Put the seven wonderful days in order.',
        'description': 'Build the creation story one beautiful moment at a time, from light to a day of rest.',
        'game_type': 'ordering',
        'cover_asset_key': 'assets/images/creation_week.jpg',
        'accent_color': '#FFB423',
        'icon_key': 'auto_awesome',
        'sort_order': 2,
        'levels': (
            {
                'title': 'Let There Be Light',
                'instructions': 'Place the first three days in the right order.',
                'config': {
                    'items': [item('day-3', 'Land and plants', '🌱'), item('day-1', 'Light and darkness', '💡'), item('day-2', 'Sky and waters', '☁️')],
                    'answer_sequence': ['day-1', 'day-2', 'day-3'],
                },
            },
            {
                'title': 'Fill the Sky and Sea',
                'instructions': 'Order the first five days of creation.',
                'config': {
                    'items': [item('day-4', 'Sun, moon, and stars', '🌞'), item('day-2', 'Sky and waters', '☁️'), item('day-5', 'Birds and sea creatures', '🐋'), item('day-1', 'Light and darkness', '💡'), item('day-3', 'Land and plants', '🌱')],
                    'answer_sequence': ['day-1', 'day-2', 'day-3', 'day-4', 'day-5'],
                },
            },
            {
                'title': 'A Wonderful Week',
                'instructions': 'Arrange all seven days and complete creation week.',
                'config': {
                    'items': [item('day-6', 'Animals and people', '🧑🏾‍🤝‍🧑🏾'), item('day-3', 'Land and plants', '🌱'), item('day-7', 'God rested', '😌'), item('day-1', 'Light and darkness', '💡'), item('day-5', 'Birds and sea creatures', '🐋'), item('day-2', 'Sky and waters', '☁️'), item('day-4', 'Sun, moon, and stars', '🌞')],
                    'answer_sequence': ['day-1', 'day-2', 'day-3', 'day-4', 'day-5', 'day-6', 'day-7'],
                },
            },
        ),
    },
    {
        'slug': 'david-sling-shot',
        'title': 'David\'s Sling Aim',
        'subtitle': 'Courage, focus, and one careful shot!',
        'description': 'Help David aim at the target while remembering that his courage came from trusting God.',
        'game_type': 'aim',
        'cover_asset_key': 'assets/images/david_and_goliath.png',
        'accent_color': '#FF6B6B',
        'icon_key': 'track_changes',
        'sort_order': 3,
        'levels': (
            {
                'title': 'Practice by the Stream',
                'instructions': 'Tap inside the big glowing target. You have three stones.',
                'config': {'canvas': {'width': 320, 'height': 420}, 'target': {'x': 160, 'y': 180, 'radius': 58}, 'max_shots': 3, 'obstacles': []},
            },
            {
                'title': 'Steady Hands',
                'instructions': 'Aim carefully between the shields.',
                'config': {'canvas': {'width': 320, 'height': 420}, 'target': {'x': 225, 'y': 145, 'radius': 42}, 'max_shots': 3, 'obstacles': [{'shape': 'circle', 'x': 100, 'y': 220, 'radius': 30, 'asset_key': '🛡️'}]},
            },
            {
                'title': 'Giant Courage',
                'instructions': 'Find the small golden target and make your bravest shot.',
                'config': {'canvas': {'width': 320, 'height': 420}, 'target': {'x': 148, 'y': 92, 'radius': 28}, 'max_shots': 2, 'obstacles': [{'shape': 'circle', 'x': 70, 'y': 185, 'radius': 24, 'asset_key': '🛡️'}, {'shape': 'circle', 'x': 255, 'y': 220, 'radius': 24, 'asset_key': '🛡️'}]},
            },
        ),
    },
    {
        'slug': 'jonah-ocean-maze',
        'title': 'Jonah Ocean Maze',
        'subtitle': 'Swim through a sea of second chances.',
        'description': 'Guide Jonah safely through ocean mazes and discover that it is never too late to listen to God.',
        'game_type': 'maze',
        'cover_asset_key': 'assets/images/jonah.jpg',
        'accent_color': '#00B8D9',
        'icon_key': 'waves',
        'sort_order': 4,
        'levels': (
            {
                'title': 'Down to the Harbor',
                'instructions': 'Trace a path from Jonah to the little boat.',
                'config': {'grid': {'rows': 5, 'columns': 5, 'start': [0, 0], 'end': [4, 4], 'walls': [[0, 2], [1, 2], [3, 1], [3, 2], [3, 3]], 'decorations': [{'position': [0, 0], 'asset_key': '🧔🏾'}, {'position': [4, 4], 'asset_key': '⛵'}]}},
            },
            {
                'title': 'Across the Stormy Sea',
                'instructions': 'Navigate around the waves to reach calm water.',
                'config': {'grid': {'rows': 6, 'columns': 6, 'start': [5, 0], 'end': [0, 5], 'walls': [[4, 1], [4, 2], [2, 0], [2, 1], [2, 2], [2, 4], [2, 5], [0, 3], [1, 3]], 'decorations': [{'position': [5, 0], 'asset_key': '⛵'}, {'position': [0, 5], 'asset_key': '🌤️'}]}},
            },
            {
                'title': 'The Big Fish Rescue',
                'instructions': 'Find the winding route to the big fish and a fresh start.',
                'config': {'grid': {'rows': 7, 'columns': 7, 'start': [0, 0], 'end': [6, 6], 'walls': [[0, 3], [1, 1], [1, 3], [1, 5], [2, 1], [2, 5], [3, 1], [3, 2], [3, 3], [3, 5], [4, 3], [5, 0], [5, 1], [5, 3], [5, 5], [6, 5]], 'decorations': [{'position': [0, 0], 'asset_key': '⛵'}, {'position': [6, 6], 'asset_key': '🐋'}]}},
            },
        ),
    },
    {
        'slug': 'red-sea-path',
        'title': 'Red Sea Path',
        'subtitle': 'Follow the bright road through the waves.',
        'description': 'Lead the people along the safe path God opened through the Red Sea and learn to keep trusting.',
        'game_type': 'path',
        'cover_asset_key': 'assets/images/crossing_red_sea.webp',
        'accent_color': '#7868E6',
        'icon_key': 'route',
        'sort_order': 5,
        'levels': (
            {
                'title': 'The First Step',
                'instructions': 'Guide the family from the shore to the safe side.',
                'config': {'grid': {'rows': 5, 'columns': 5, 'start': [2, 0], 'end': [2, 4], 'walls': [[0, 1], [0, 2], [0, 3], [4, 1], [4, 2], [4, 3], [1, 2], [3, 2]], 'decorations': [{'position': [2, 0], 'asset_key': '👨‍👩‍👧'}, {'position': [2, 4], 'asset_key': '🏝️'}]}},
            },
            {
                'title': 'Between the Waves',
                'instructions': 'Stay on the dry path and wind around the deep water.',
                'config': {'grid': {'rows': 6, 'columns': 6, 'start': [0, 0], 'end': [5, 5], 'walls': [[0, 2], [1, 2], [1, 4], [2, 0], [2, 4], [3, 2], [3, 3], [3, 4], [4, 2], [5, 2]], 'decorations': [{'position': [0, 0], 'asset_key': '👣'}, {'position': [5, 5], 'asset_key': '✨'}]}},
            },
            {
                'title': 'Everyone Crosses',
                'instructions': 'Take the long safe road and bring everyone home.',
                'config': {'grid': {'rows': 7, 'columns': 7, 'start': [6, 0], 'end': [0, 6], 'walls': [[5, 1], [5, 2], [5, 3], [3, 0], [3, 1], [3, 3], [3, 4], [3, 5], [1, 1], [1, 2], [1, 3], [1, 5], [2, 5], [4, 3]], 'decorations': [{'position': [6, 0], 'asset_key': '👨‍👩‍👧‍👦'}, {'position': [0, 6], 'asset_key': '🎉'}]}},
            },
        ),
    },
    {
        'slug': 'daniel-memory',
        'title': 'Daniel Memory Match',
        'subtitle': 'Flip, remember, and find every brave pair.',
        'description': 'Match symbols from Daniel\'s story—prayer, courage, lions, and God\'s loving protection.',
        'game_type': 'memory',
        'cover_asset_key': 'assets/images/daniel.jpeg',
        'accent_color': '#FF8A5B',
        'icon_key': 'grid_view',
        'sort_order': 6,
        'levels': (
            {
                'title': 'Daniel\'s Day',
                'instructions': 'Flip the six cards and find three matching pairs.',
                'config': {'cards': memory_cards([('prayer', 'Prayer', 'Prayer', '🙏🏾'), ('window', 'Window', 'Window', '🪟'), ('scroll', 'Scroll', 'Scroll', '📜')]), 'preview_seconds': 4, 'target_seconds': 40},
            },
            {
                'title': 'The Lions\' Den',
                'instructions': 'Remember where four story pairs are hiding.',
                'config': {'cards': memory_cards([('lion', 'Lion', 'Lion', '🦁'), ('angel', 'Angel', 'Angel', '😇'), ('king', 'King', 'King', '👑'), ('stone', 'Stone', 'Stone', '🪨')]), 'preview_seconds': 3, 'target_seconds': 55},
            },
            {
                'title': 'Courage Remembered',
                'instructions': 'Find all five pairs in Daniel\'s biggest memory challenge.',
                'config': {'cards': memory_cards([('prayer', 'Prayer', 'Prayer', '🙏🏾'), ('lion', 'Lion', 'Lion', '🦁'), ('angel', 'Angel', 'Angel', '😇'), ('king', 'King', 'King', '👑'), ('sunrise', 'Morning', 'Morning', '🌅')]), 'preview_seconds': 3, 'target_seconds': 70},
            },
        ),
    },
    {
        'slug': 'esther-quiz',
        'title': 'Esther Brave Quiz',
        'subtitle': 'Choose courage, kindness, and wisdom.',
        'description': 'Answer joyful questions about Esther\'s brave choice and how one person can help many people.',
        'game_type': 'quiz',
        'cover_asset_key': 'assets/images/esther.jpeg',
        'accent_color': '#D65DB1',
        'icon_key': 'quiz',
        'sort_order': 7,
        'levels': (
            {
                'title': 'Meet Queen Esther',
                'instructions': 'Choose the best answer for each question.',
                'config': {'pass_score': 60, 'questions': [
                    question('q1', 'Who raised Esther with love?', [('a', 'Mordecai'), ('b', 'Goliath'), ('c', 'Jonah')], 'a'),
                    question('q2', 'Where did Esther live as queen?', [('a', 'In an ark'), ('b', 'In a palace'), ('c', 'In a tent by the sea')], 'b'),
                    question('q3', 'What made Esther special?', [('a', 'Only her crown'), ('b', 'Her courage and kindness'), ('c', 'A giant boat')], 'b'),
                ]},
            },
            {
                'title': 'A Brave Choice',
                'instructions': 'Remember how Esther chose to help her people.',
                'config': {'pass_score': 60, 'questions': [
                    question('q1', 'Why did Esther go to the king?', [('a', 'To ask for a party'), ('b', 'To help save her people'), ('c', 'To find a lion')], 'b'),
                    question('q2', 'How did Esther prepare?', [('a', 'She prayed and fasted'), ('b', 'She hid forever'), ('c', 'She built a tower')], 'a'),
                    question('q3', 'Was speaking to the king easy for Esther?', [('a', 'No, it took courage'), ('b', 'Yes, there was no risk'), ('c', 'She never spoke')], 'a'),
                ]},
            },
            {
                'title': 'For Such a Time',
                'instructions': 'Use Esther\'s story to choose brave and kind actions.',
                'config': {'pass_score': 60, 'questions': [
                    question('q1', 'What can courage look like today?', [('a', 'Helping someone who is treated unfairly'), ('b', 'Ignoring someone in need'), ('c', 'Being unkind first')], 'a'),
                    question('q2', 'Who reminded Esther she could make a difference?', [('a', 'Mordecai'), ('b', 'Pharaoh'), ('c', 'Nebuchadnezzar')], 'a'),
                    question('q3', 'What happened after Esther spoke bravely?', [('a', 'Her people were helped'), ('b', 'The ark sank'), ('c', 'The sun disappeared')], 'a'),
                ]},
            },
        ),
    },
    {
        'slug': 'moses-match',
        'title': 'Moses Mission Match',
        'subtitle': 'Connect every clue to Moses\' adventure.',
        'description': 'Match people, places, and objects from Moses\' story while learning how God leads His people.',
        'game_type': 'matching',
        'cover_asset_key': 'assets/images/moses2.jpeg',
        'accent_color': '#00C9A7',
        'icon_key': 'link',
        'sort_order': 8,
        'levels': (
            {
                'title': 'Baby Moses',
                'instructions': 'Connect each story clue to the place or person it belongs with.',
                'config': {
                    'left_items': [item('basket', 'Basket', '🧺'), item('river', 'River', '🌊'), item('miriam', 'Miriam', '👧🏾')],
                    'right_items': [item('watched', 'Watched nearby', '👀'), item('floated', 'Floated safely', '🛟'), item('nile', 'The Nile', '🏞️')],
                    'expected_pairs': {'basket': 'floated', 'river': 'nile', 'miriam': 'watched'},
                },
            },
            {
                'title': 'The Burning Bush',
                'instructions': 'Match each sign to what Moses learned or did.',
                'config': {
                    'left_items': [item('bush', 'Burning bush', '🔥'), item('sandals', 'Sandals', '🩴'), item('staff', 'Staff', '🦯'), item('egypt', 'Egypt', '🏜️')],
                    'right_items': [item('holy', 'Holy ground', '✨'), item('mission', 'A rescue mission', '🗺️'), item('sign', 'God gave a sign', '⭐'), item('removed', 'Moses took them off', '🦶🏾')],
                    'expected_pairs': {'bush': 'holy', 'sandals': 'removed', 'staff': 'sign', 'egypt': 'mission'},
                },
            },
            {
                'title': 'Freedom Journey',
                'instructions': 'Finish Moses\' mission by connecting five final clues.',
                'config': {
                    'left_items': [item('passover', 'Passover', '🕯️'), item('sea', 'Red Sea', '🌊'), item('manna', 'Manna', '🍞'), item('tablets', 'Stone tablets', '🪨'), item('cloud', 'Cloud', '☁️')],
                    'right_items': [item('food', 'Food in the wilderness', '😋'), item('commandments', 'God\'s commandments', '🔟'), item('opened', 'A path opened', '🛤️'), item('guided', 'Guided the people', '🧭'), item('remember', 'A rescue remembered', '💛')],
                    'expected_pairs': {'passover': 'remember', 'sea': 'opened', 'manna': 'food', 'tablets': 'commandments', 'cloud': 'guided'},
                },
            },
        ),
    },
)


def seed_games(apps, schema_editor):
    Game = apps.get_model('games', 'Game')
    GameLevel = apps.get_model('games', 'GameLevel')
    for game_data in GAMES:
        levels = game_data['levels']
        defaults = {key: value for key, value in game_data.items() if key not in {'slug', 'levels'}}
        game, _ = Game.objects.update_or_create(
            slug=game_data['slug'],
            defaults={**defaults, 'is_published': True},
        )
        active_numbers = []
        for level_number, level_data in enumerate(levels, start=1):
            active_numbers.append(level_number)
            GameLevel.objects.update_or_create(
                game=game,
                level_number=level_number,
                defaults={
                    **level_data,
                    'max_score': 100,
                    'star_thresholds': [60, 80, 95],
                },
            )
        GameLevel.objects.filter(game=game).exclude(level_number__in=active_numbers).delete()


def remove_seeded_games(apps, schema_editor):
    Game = apps.get_model('games', 'Game')
    GameAttempt = apps.get_model('games', 'GameAttempt')
    GameAttempt.objects.filter(game__slug__in=GAME_SLUGS).delete()
    Game.objects.filter(slug__in=GAME_SLUGS).delete()


class Migration(migrations.Migration):

    dependencies = [
        ('games', '0001_initial'),
    ]

    operations = [
        migrations.RunPython(seed_games, remove_seeded_games),
    ]
