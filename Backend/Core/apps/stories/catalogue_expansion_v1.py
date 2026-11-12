"""Frozen, additive 2026 story/picture-puzzle catalogue.

Migration 0009 consumes this versioned payload. Do not edit released text in
place: narration checksums and existing reading progress bind to story IDs.
The English retellings below are original Kingdom Kids prose, not translation
quotations. Scripture references are editorial provenance, not API fields.
"""

STORIES = (
    {
        'slug': 'lost-sheep', 'title': 'The Lost Sheep', 'category': 'Love',
        'summary': 'A shepherd keeps searching until his missing sheep is safely home.',
        'scripture': 'Luke 15:1–7',
        'body': (
            'Jesus welcomed people who wanted to listen and learn. Some people wondered why '
            'he cared about those who had made mistakes. Jesus told them a story about a '
            'shepherd and his one hundred sheep.\n\n'
            'The shepherd knew his flock. As he watched the sheep, he noticed that one was '
            'missing. Ninety-nine sheep were still together, but the missing sheep mattered '
            'too. The shepherd went to look for it.\n\n'
            'He did not decide that one small sheep was unimportant. He kept searching until '
            'he found it. Imagine the relief of hearing a familiar voice after feeling lost '
            'and alone. The sheep had been found!\n\n'
            'With joy, the shepherd lifted the sheep onto his shoulders and carried it home. '
            'He called his friends and neighbors to celebrate with him. His happiness was '
            'too big to keep to himself.\n\n'
            'Jesus explained that heaven rejoices when someone turns back to God. We can '
            'always ask for help, tell the truth about our mistakes, and begin again. God '
            'cares for each person. When someone feels left out, we can welcome them with '
            'the same patient kindness.'
        ),
        'cover_asset_key': 'assets/images/stories/lost-sheep-blender-v1.webp',
        'sort_order': 9,
    },
    {
        'slug': 'joseph-colorful-coat', 'title': 'Joseph and His Colorful Coat',
        'category': 'Forgiveness',
        'summary': 'Joseph discovers that kindness and forgiveness can outlast jealousy.',
        'scripture': 'Genesis 37; 39–45; 50:15–21',
        'body': (
            'Joseph belonged to a large family. His father, Jacob, gave him a special '
            'colorful coat. Joseph also had dreams that surprised his brothers. Instead '
            'of sharing his happiness, his brothers grew jealous.\n\n'
            'Their jealousy led them to make a terrible choice. They took Joseph away from '
            'home and sold him to travelers going to Egypt. Joseph lost his coat and the '
            'comfort of his family, but God did not leave him.\n\n'
            'Life in Egypt was difficult. Joseph worked faithfully, even when others treated '
            'him unfairly. Over time, God helped him understand dreams. When the ruler of '
            'Egypt needed help, Joseph explained that years of plenty would be followed '
            'by years when food was scarce.\n\n'
            'Joseph helped store grain so people would have food later. When the hungry '
            'years arrived, his brothers came to Egypt for grain. They did not recognize '
            'the brother they had hurt so long ago.\n\n'
            'At last, Joseph told them who he was. He cried, welcomed them, and helped '
            'his family. Their wrong choice was still wrong, but Joseph chose forgiveness '
            'instead of revenge. His story reminds us to notice jealousy, ask for help, '
            'and choose kindness. God can bring hope even after a painful beginning.'
        ),
        'cover_asset_key': 'assets/images/stories/joseph-colorful-coat-blender-v1.webp',
        'sort_order': 10,
    },
    {
        'slug': 'good-samaritan', 'title': 'The Good Samaritan', 'category': 'Kindness',
        'summary': 'A traveler shows that being a neighbor means stopping to care.',
        'scripture': 'Luke 10:25–37',
        'body': (
            'Someone asked Jesus who counted as a neighbor. Jesus answered with a story '
            'about a man traveling from Jerusalem to Jericho. Along the road, robbers hurt '
            'the man and left him needing help.\n\n'
            'A priest came down the road. He saw the man, but walked past on the other side. '
            'Later, a Levite came along. He also saw the man and passed by. The traveler '
            'was still alone.\n\n'
            'Then a Samaritan arrived. Many people in those days did not get along with '
            'Samaritans. Yet this traveler did not let differences stop him from caring. '
            'He saw someone in trouble and chose to help.\n\n'
            'The Samaritan gently cleaned and bandaged the man’s wounds. He helped him onto '
            'his own animal and brought him to an inn, where he could rest. The next day, '
            'he paid the innkeeper to continue caring for him.\n\n'
            'Jesus asked which traveler had acted like a neighbor. The answer was the one '
            'who showed mercy. We can practice that kindness too. When someone is hurt or '
            'lonely, we can find a trusted grown-up, offer gentle help, and include them. '
            'A caring neighbor does more than notice. A caring neighbor takes a helpful step.'
        ),
        'cover_asset_key': 'assets/images/stories/good-samaritan-blender-v1.webp',
        'sort_order': 11,
    },
    {
        'slug': 'walls-of-jericho', 'title': 'The Walls of Jericho', 'category': 'Trust',
        'summary': 'Joshua and the people learn to listen, wait, and follow God together.',
        'scripture': 'Joshua 6',
        'body': (
            'Joshua led God’s people toward Jericho, a city with strong walls and tightly '
            'closed gates. The people could not simply walk through. God gave Joshua '
            'instructions that required trust, patience, and careful listening.\n\n'
            'For six days, the people marched around the city once each day. Priests '
            'carried the ark of the covenant, a reminder of God’s presence, and seven '
            'priests carried trumpets. The people waited quietly for Joshua’s signal.\n\n'
            'Each day, they returned to camp. They had followed the instructions, but '
            'the walls were still standing. Waiting can feel difficult when we want '
            'something to happen right away. The people kept taking the next faithful step.\n\n'
            'On the seventh day, they marched around Jericho seven times. Then the '
            'trumpets sounded and Joshua gave the signal. The people shouted, and the '
            'walls fell. God had opened the way as he had promised.\n\n'
            'Rahab and her family were brought to safety, just as the spies had promised '
            'when she helped them. This story reminds us that trust includes listening '
            'and keeping our promises. We can practice patience, work together, and ask '
            'God for courage while we wait. One obedient step can prepare us for the next.'
        ),
        'cover_asset_key': 'assets/images/stories/walls-of-jericho-blender-v1.webp',
        'sort_order': 12,
    },
    {
        'slug': 'ruth-and-naomi', 'title': 'Ruth and Naomi', 'category': 'Loyalty',
        'summary': 'Ruth gathers grain and brings hope home to Naomi through steady care.',
        'scripture': 'Ruth 1–2',
        'body': (
            'Naomi had lost people she loved and was returning to Bethlehem. Her '
            'daughter-in-law Ruth could have stayed in her own country, Moab. Instead, '
            'Ruth chose to stay beside Naomi and share her journey.\n\n'
            'Ruth promised to make Naomi’s people her people and to trust Naomi’s God. '
            'Together, they reached Bethlehem at the beginning of the barley harvest. '
            'They needed food, so Ruth looked for a way to help.\n\n'
            'She went into the fields to gather grain that the harvesters left behind. '
            'This was called gleaning. Ruth bent down, picked up the grain, and kept '
            'working. Little handfuls slowly became enough to take home.\n\n'
            'The field belonged to Boaz, a relative of Naomi’s family. He heard about '
            'Ruth’s faithful care. Boaz made sure she could work safely, offered water '
            'and food, and asked the workers to leave extra grain for her.\n\n'
            'That evening, Ruth brought grain and leftover food back to Naomi. Naomi '
            'was encouraged by the kindness they had received. Ruth continued gathering '
            'through the harvest. Her love was more than a promise: it became patient, '
            'useful work. We can care for our families through small helpful actions, '
            'and welcome people who are starting again in a new place.'
        ),
        'cover_asset_key': 'assets/images/stories/ruth-and-naomi-blender-v1.webp',
        'sort_order': 13,
    },
)


PUZZLE_THEMES = (
    ('esther', 'Esther', 'assets/images/stories/esther-speaks-up-v2.webp',
     'Dark-skinned Queen Esther in a colorful palace scene.', '#9568D4'),
    ('noah', 'Noah’s Ark', 'assets/images/stories/noah-builds-the-ark-v2.webp',
     'Noah’s ark with friendly animals and a rainbow.', '#3F8EFC'),
    ('david', 'David', 'assets/images/stories/david-and-goliath-v2.webp',
     'Dark-skinned David in a brave Bible adventure scene.', '#E09C3E'),
    ('red-sea', 'The Red Sea', 'assets/images/stories/crossing-the-red-sea-v2.webp',
     'Dark-skinned Moses and travelers crossing between the parted sea.', '#1E9CBB'),
    ('jonah', 'Jonah', 'assets/images/stories/jonah-and-the-big-fish-v2.webp',
     'Dark-skinned Jonah in a colorful ocean scene with the great fish.', '#4B8CD7'),
    ('lost-sheep', 'The Lost Sheep', 'assets/images/stories/lost-sheep-blender-v1.webp',
     'A dark-skinned shepherd carrying an ivory sheep home through green hills.', '#519443'),
    ('joseph-colorful-coat', 'Joseph’s Coat', 'assets/images/stories/joseph-colorful-coat-blender-v1.webp',
     'Dark-skinned Joseph wearing a colorful woven coat beside his father.', '#DA795C'),
    ('good-samaritan', 'The Good Samaritan', 'assets/images/stories/good-samaritan-blender-v1.webp',
     'A dark-skinned Samaritan gently helping a dark-skinned traveler by the road.', '#C9944A'),
    ('walls-of-jericho', 'Jericho', 'assets/images/stories/walls-of-jericho-blender-v1.webp',
     'Dark-skinned people and priests marching peacefully beside Jericho’s walls.', '#C47E43'),
    ('ruth-and-naomi', 'Ruth and Naomi', 'assets/images/stories/ruth-and-naomi-blender-v1.webp',
     'Dark-skinned Ruth gathering golden grain to care for dark-skinned Naomi.', '#BB8F3D'),
)


def puzzle_levels(theme):
    """Use the established 4/6/9-piece engine and a distinct ID per theme/tier."""
    key, title, asset, alt_text, _ = theme
    levels = []
    for number, (tier, rows, columns, seconds, preview) in enumerate(
        [('Easy', 2, 2, 60, 7), ('Medium', 2, 3, 100, 7), ('Hard', 3, 3, 150, 8)],
        start=1,
    ):
        pieces = [
            {'id': f'{key}-{number}-piece-{row+1}-{column+1}',
             'label': f'{title}: picture row {row+1}, column {column+1}',
             'source_row': row, 'source_column': column}
            for row in range(rows) for column in range(columns)
        ]
        # A deliberate rotation prevents authored tray order from being solved;
        # the existing Flutter engine also reshuffles every new play.
        pieces = pieces[1:] + pieces[:1]
        slots = [{'id': f'slot-{row+1}-{column+1}', 'row': row, 'column': column}
                 for row in range(rows) for column in range(columns)]
        levels.append({
            'level_number': number, 'title': f'{title} · {tier}',
            'instructions': f'Study {title}, then rebuild the picture with {rows*columns} pieces.',
            'max_score': 100, 'star_thresholds': [60, 80, 95],
            'config': {
                'artwork': {'asset_key': asset, 'title': title,
                            'alt_text': alt_text, 'aspect_ratio': 1},
                'grid': {'rows': rows, 'columns': columns},
                'pieces': pieces, 'slots': slots,
                'solution': {piece['id']: f"slot-{piece['source_row']+1}-{piece['source_column']+1}"
                             for piece in pieces},
                'preview_seconds': preview, 'target_moves': rows*columns,
                'target_seconds': seconds,
            },
        })
    return levels


def puzzle_games():
    return [
        {'slug': f'puzzle-{theme[0]}', 'title': f'{theme[1]} Picture Puzzle',
         'subtitle': 'Choose easy, medium, or hard and build the picture.',
         'description': f'Explore the {theme[1]} picture in three puzzle sizes. A fresh piece arrangement starts every play.',
         'game_type': 'puzzle', 'difficulty': 'Easy',
         'estimated_duration_seconds': 310, 'cover_asset_key': theme[2],
         'accent_color': theme[4], 'icon_key': 'extension',
         'is_featured': False, 'is_published': True, 'sort_order': 20+index,
         'levels': puzzle_levels(theme)}
        for index, theme in enumerate(PUZZLE_THEMES)
    ]
