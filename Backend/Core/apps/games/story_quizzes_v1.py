"""Frozen story-quiz catalogue consumed by migration 0017.

These original questions follow the app's canonical story text, including its
everyday lessons. Source excerpts are private editorial provenance; the quiz
serializer exposes only prompts and choices. Do not edit released rounds in
place: saved submissions reference their stable question and option IDs.
"""


ROUND_TITLES = ('Meet the Story', 'Follow the Adventure', 'Try It Today')
ROUND_INSTRUCTIONS = (
    'Think back to the story and choose one answer for each question.',
    'Follow the story clues. Choose one answer for each question.',
    'Choose the helpful action that matches the story’s lesson.',
)


def _question(question_id, prompt, answer, others, source_excerpt, position):
    choices = list(others)
    choices.insert(position, answer)
    option_ids = ('a', 'b', 'c')
    return {
        'id': question_id,
        'prompt': prompt,
        'options': [{'id': key, 'text': text} for key, text in zip(option_ids, choices)],
        'correct_option_id': option_ids[position],
        'source_excerpt': source_excerpt,
    }


# Each question contains: prompt, correct choice, two alternatives, and the
# exact story excerpt supporting the fact or the named everyday lesson.
QUIZ_STORIES = (
    {
        'slug': 'noah-quiz', 'story_slug': 'noah-builds-the-ark',
        'title': 'Noah’s Ark Quiz', 'accent_color': '#3F8EFC',
        'cover_asset_key': 'assets/images/stories/noah-builds-the-ark-v2.webp',
        'subtitle': 'Discover listening, care, and a rainbow promise.',
        'questions': (
            ('What did God ask Noah to build?', 'An ark', ('A tower', 'A palace'),
             'God told Noah to build an ark'),
            ('Why was Noah building the ark?', 'A great flood was coming',
             ('A harvest was beginning', 'A king was visiting'), 'a great flood was coming'),
            ('Who did Noah welcome safely into the ark?', 'The animals',
             ('A marching army', 'A group of builders'), 'welcomed the animals safely into the ark'),
            ('How did Noah obey when the job seemed big?', 'One step at a time',
             ('By giving up straight away', 'By ignoring the instructions'), 'Noah obeyed one step at a time'),
            ('What appeared in the sky as God’s promise?', 'A rainbow',
             ('A new moon', 'A flock of birds'), 'God placed a rainbow in the sky as a promise'),
            ('What did Noah and his family do in the fresh new world?', 'Praised God with thankful hearts',
             ('Forgot to say thank you', 'Refused to begin again'),
             'They praised God together and began again with thankful hearts'),
            ('A helpful job feels very big. What can you learn from Noah?', 'Start with one small step',
             ('Leave before trying', 'Rush without listening'), 'Noah obeyed one step at a time'),
            ('A trusted grown-up explains a safe task. What shows careful listening?', 'Listen, then follow the steps',
             ('Talk over the instructions', 'Guess without listening'), 'listened carefully'),
            ('What is a caring way to help an animal, like Noah did?', 'Ask a grown-up to help meet its needs',
             ('Ignore it when it needs care', 'Keep its food away'), 'welcomed the animals safely into the ark'),
        ),
    },
    {
        'slug': 'david-quiz', 'story_slug': 'david-and-goliath',
        'title': 'David and Goliath Quiz', 'accent_color': '#E09C3E',
        'cover_asset_key': 'assets/images/stories/david-and-goliath-v2.webp',
        'subtitle': 'Remember David’s brave and trusting heart.',
        'questions': (
            ('What did young David care for?', 'Sheep', ('Fish', 'Lions'), 'David was a young shepherd'),
            ('Who frightened the army?', 'Goliath', ('Noah', 'Jonah'), 'the giant Goliath frightened the army'),
            ('How many smooth stones did David take?', 'Five', ('Two', 'Ten'), 'five smooth stones'),
            ('What did David remember before stepping forward?', 'God had helped him protect his sheep',
             ('He had built a large ark', 'He had crossed a stormy sea'),
             'God had helped him protect his sheep before'),
            ('What did David carry along with his stones?', 'A sling', ('A trumpet', 'A fishing net'), 'With a sling'),
            ('Who did everyone see the victory belonged to?', 'God', ('David’s armor', 'The stones alone'),
             'the victory belonged to God'),
            ('You feel nervous about doing something right. What matches David’s story?', 'Ask for help and take a brave step',
             ('Let fear make every choice', 'Give up before asking for help'),
             'small hands can do brave things with God’s help'),
            ('A younger child wants to help. What can David’s story remind you?', 'Small hands can do brave things too',
             ('Only the biggest people can help', 'Young children never have good ideas'),
             'small hands can do brave things with God’s help'),
            ('Which attitude fits the lesson about a listening spirit?', 'Listen carefully before acting',
             ('Ignore helpful advice', 'Interrupt every instruction'), 'a faithful heart, a listening spirit'),
        ),
    },
    {
        'slug': 'jonah-quiz', 'story_slug': 'jonah-and-the-big-fish',
        'title': 'Jonah and the Big Fish Quiz', 'accent_color': '#4B8CD7',
        'cover_asset_key': 'assets/images/stories/jonah-and-the-big-fish-v2.webp',
        'subtitle': 'Explore mercy, kindness, and second chances.',
        'questions': (
            ('What did Jonah first try to do?', 'Run away from what God asked',
             ('Build an ark', 'Gather grain in a field'), 'Jonah tried to run away from what God asked him to do'),
            ('Which animal appears in Jonah’s story?', 'A great fish', ('A little sheep', 'A lion'), 'a great fish'),
            ('How many quiet days helped Jonah learn?', 'Three', ('One', 'Seven'), 'three quiet days'),
            ('What kind of weather appears in the story?', 'A storm', ('A snow shower', 'A gentle morning breeze'), 'A storm'),
            ('What does the story say is bigger than fear?', 'God’s mercy',
             ('Jonah’s plans', 'The waves alone'), 'God’s mercy is bigger than fear'),
            ('Who did Jonah learn God cares for?', 'People we may not understand',
             ('Only people who think like us', 'Only people we already know'),
             'God cares for people we may not understand'),
            ('You made a mistake. What matches the story’s lesson about second chances?', 'Listen, learn, and try again',
             ('Decide you can never improve', 'Keep making the same choice on purpose'), 'second chances, listening to God'),
            ('Someone is different from you. Which choice matches Jonah’s lesson?', 'Choose kindness toward them',
             ('Leave them out because they are different', 'Refuse to learn about them'),
             'God cares for people we may not understand'),
            ('Being kind feels difficult today. What does Jonah’s story encourage?', 'Keep choosing kindness',
             ('Be kind only when it is easy', 'Let fear choose for you'), 'choosing kindness even when it is hard'),
        ),
    },
    {
        'slug': 'creation-quiz', 'story_slug': 'creation-week',
        'title': 'Creation Week Quiz', 'accent_color': '#58A66B',
        'cover_asset_key': 'assets/images/stories/creation-week-v2.webp',
        'subtitle': 'Notice the wonders of God’s good world.',
        'questions': (
            ('Who made the heavens and the earth in this story?', 'God', ('Joseph', 'Joshua'),
             'God made the heavens and the earth'),
            ('Which living things are named in the story?', 'Animals and people',
             ('Castles and roads', 'Boats and houses'), 'animals, and people'),
            ('How does Creation Week end?', 'With rest', ('With a race', 'With a battle'), 'The story ends with rest'),
            ('Which pair of things did God fill the world with?', 'Light and sky',
             ('Towers and gates', 'Coats and baskets'), 'light, sky'),
            ('What does every flower, ocean, animal, and star point to?', 'God’s care',
             ('A city’s strong walls', 'A traveler’s long road'), 'Every flower, ocean, animal, and star points back to God’s care'),
            ('How does the story describe God’s work?', 'Good', ('Forgotten', 'Unfinished'), 'God’s work was good'),
            ('You see a beautiful flower. What fits Creation Week’s lesson?', 'Pause, notice it, and give thanks',
             ('Walk past without noticing', 'Pick it only to throw it away'),
             'slow down and notice God’s good world with wonder, gratitude, and joy'),
            ('After doing useful work, what else belongs in a good rhythm?', 'Time to rest',
             ('More work without a break', 'A race to stay busy'), 'a gentle rhythm for wonder, work, worship, and peace'),
            ('Which words fit how Creation Week invites us to see the world?', 'Wonder, gratitude, and joy',
             ('Hurry, worry, and noise', 'Jealousy, fear, and anger'), 'wonder, gratitude, and joy'),
        ),
    },
    {
        'slug': 'lost-sheep-quiz', 'story_slug': 'lost-sheep',
        'title': 'The Lost Sheep Quiz', 'accent_color': '#519443',
        'cover_asset_key': 'assets/images/stories/lost-sheep-storybook-v1.webp',
        'subtitle': 'Every sheep matters, and every person does too.',
        'questions': (
            ('Who told the story about the lost sheep?', 'Jesus', ('Jacob', 'Boaz'), 'Jesus told them a story'),
            ('How many sheep did the shepherd have?', 'One hundred', ('Ten', 'Twenty'), 'his one hundred sheep'),
            ('How many sheep were missing?', 'One', ('Five', 'All of them'), 'he noticed that one was missing'),
            ('How long did the shepherd keep searching?', 'Until he found the sheep',
             ('Only until he became bored', 'Only until someone called him'), 'He kept searching until he found it'),
            ('How did the shepherd carry the sheep home?', 'On his shoulders',
             ('In a boat', 'In a basket of grain'), 'lifted the sheep onto his shoulders and carried it home'),
            ('Who did he call to celebrate?', 'His friends and neighbors',
             ('Only the other sheep', 'No one at all'), 'He called his friends and neighbors to celebrate'),
            ('Someone feels left out. What matches the story’s lesson?', 'Welcome them with patient kindness',
             ('Tell them to stay away', 'Pretend not to notice them'),
             'When someone feels left out, we can welcome them with the same patient kindness'),
            ('You made a mistake and need help. What can you do?', 'Tell the truth and ask for help',
             ('Hide it so no one can help', 'Blame someone else'), 'ask for help, tell the truth about our mistakes, and begin again'),
            ('One person in a group needs care. What can the shepherd teach us?', 'That one person matters too',
             ('Only the biggest group matters', 'One person is easy to forget'), 'the missing sheep mattered too'),
        ),
    },
    {
        'slug': 'joseph-colorful-coat-quiz', 'story_slug': 'joseph-colorful-coat',
        'title': 'Joseph’s Colorful Coat Quiz', 'accent_color': '#DA795C',
        'cover_asset_key': 'assets/images/stories/joseph-colorful-coat-storybook-v1.webp',
        'subtitle': 'Discover hope, helpful planning, and forgiveness.',
        'questions': (
            ('Who gave Joseph his special colorful coat?', 'His father, Jacob',
             ('Boaz', 'Joshua'), 'His father, Jacob, gave him a special colorful coat'),
            ('How did Joseph’s brothers feel about his happiness?', 'Jealous',
             ('Thankful for his help', 'Pleased to share his joy'), 'his brothers grew jealous'),
            ('Where did the travelers take Joseph?', 'Egypt', ('Bethlehem', 'Jericho'), 'travelers going to Egypt'),
            ('What did God help Joseph understand?', 'Dreams', ('Animal routes', 'River maps'), 'God helped him understand dreams'),
            ('What did Joseph help store for the hungry years?', 'Grain',
             ('Colorful coats', 'Building stones'), 'Joseph helped store grain so people would have food later'),
            ('What did Joseph choose when he met his brothers again?', 'Forgiveness instead of revenge',
             ('Revenge instead of kindness', 'Turning his hungry family away'), 'Joseph chose forgiveness instead of revenge'),
            ('A friend receives something special and you feel jealous. What fits this story?', 'Notice the feeling and ask for help choosing kindness',
             ('Hurt the friend’s feelings', 'Take the gift from them'), 'notice jealousy, ask for help, and choose kindness'),
            ('You know a harder time may be coming. Which action is like Joseph’s planning?', 'Prepare what people may need later',
             ('Use everything without planning', 'Refuse to think ahead'), 'Joseph helped store grain so people would have food later'),
            ('Someone has hurt you. Which choice matches Joseph’s lesson?', 'Ask for help and choose kindness rather than revenge',
             ('Hurt them back on purpose', 'Decide kindness no longer matters'), 'Joseph chose forgiveness instead of revenge'),
        ),
    },
    {
        'slug': 'good-samaritan-quiz', 'story_slug': 'good-samaritan',
        'title': 'The Good Samaritan Quiz', 'accent_color': '#C9944A',
        'cover_asset_key': 'assets/images/stories/good-samaritan-storybook-v1.webp',
        'subtitle': 'Learn how a caring neighbor takes a helpful step.',
        'questions': (
            ('Where was the man traveling?', 'From Jerusalem to Jericho',
             ('From Moab to Bethlehem', 'From Egypt to a field'), 'traveling from Jerusalem to Jericho'),
            ('Who stopped to help the traveler?', 'A Samaritan', ('The priest', 'The Levite'),
             'a Samaritan arrived'),
            ('Where did the Samaritan bring the man to rest?', 'An inn',
             ('An ark', 'A grain field'), 'brought him to an inn, where he could rest'),
            ('What did the priest and the Levite do when they saw the man?', 'Passed by without helping',
             ('Brought him food together', 'Paid the innkeeper together'), 'He also saw the man and passed by'),
            ('How did the Samaritan care for the man’s wounds?', 'Gently cleaned and bandaged them',
             ('Left them without care', 'Asked the man to keep walking'), 'gently cleaned and bandaged the man’s wounds'),
            ('What did the Samaritan do the next day?', 'Paid the innkeeper to keep caring for the man',
             ('Told the innkeeper to send the man away', 'Asked the man to leave before resting'),
             'he paid the innkeeper to continue caring for him'),
            ('You see someone hurt. What is a safe, caring first step?', 'Find a trusted grown-up to help',
             ('Walk away without telling anyone', 'Try to do everything alone'), 'we can find a trusted grown-up'),
            ('Someone is different from you and needs kindness. What fits this story?', 'Do not let differences stop you from caring',
             ('Help only people exactly like you', 'Leave them alone because they are different'),
             'did not let differences stop him from caring'),
            ('A child is lonely at playtime. What can a caring neighbor do?', 'Invite them to join in',
             ('Notice them but do nothing', 'Tell others to leave them out'), 'offer gentle help, and include them'),
        ),
    },
    {
        'slug': 'walls-of-jericho-quiz', 'story_slug': 'walls-of-jericho',
        'title': 'The Walls of Jericho Quiz', 'accent_color': '#C47E43',
        'cover_asset_key': 'assets/images/stories/walls-of-jericho-storybook-v1.webp',
        'subtitle': 'Follow the clues about trust and patient teamwork.',
        'questions': (
            ('Who led God’s people toward Jericho?', 'Joshua', ('Joseph', 'Noah'), 'Joshua led God’s people toward Jericho'),
            ('What stopped the people from simply walking into the city?', 'Strong walls and closed gates',
             ('A field of barley', 'A sleeping flock of sheep'), 'strong walls and tightly closed gates'),
            ('For the first six days, how often did they march around the city?', 'Once each day',
             ('Seven times each day', 'Only on the last day'), 'For six days, the people marched around the city once each day'),
            ('How many times did they march on the seventh day?', 'Seven times',
             ('Once', 'Three times'), 'On the seventh day, they marched around Jericho seven times'),
            ('What happened after the trumpets and Joshua’s signal?', 'The people shouted and the walls fell',
             ('The people quietly returned to camp again', 'The gates grew taller'), 'The people shouted, and the walls fell'),
            ('Who was brought to safety as promised?', 'Rahab and her family',
             ('Jacob and Joseph', 'Ruth and Naomi'), 'Rahab and her family were brought to safety'),
            ('You are waiting for something good. What fits this story?', 'Practice patience and take the next helpful step',
             ('Give up because it has not happened yet', 'Refuse to work with anyone'), 'practice patience, work together'),
            ('Your group has a task with instructions. What helps you work like the people in this story?', 'Listen carefully and work together',
             ('Everyone ignores the plan', 'Everyone talks over the instructions'), 'trust, patience, and careful listening'),
            ('You made a promise to help. What does Jericho’s story remind you to do?', 'Keep your promise',
             ('Forget it when it becomes inconvenient', 'Make someone else keep it for you'), 'trust includes listening and keeping our promises'),
        ),
    },
    {
        'slug': 'ruth-and-naomi-quiz', 'story_slug': 'ruth-and-naomi',
        'title': 'Ruth and Naomi Quiz', 'accent_color': '#BB8F3D',
        'cover_asset_key': 'assets/images/stories/ruth-and-naomi-storybook-v1.webp',
        'subtitle': 'Small helpful actions can bring hope home.',
        'questions': (
            ('Who chose to stay beside Naomi on her journey?', 'Ruth', ('Esther', 'Rahab'), 'Ruth chose to stay beside Naomi'),
            ('Where did Ruth and Naomi arrive together?', 'Bethlehem', ('Egypt', 'Jericho'), 'Together, they reached Bethlehem'),
            ('What harvest was beginning when they arrived?', 'The barley harvest',
             ('The apple harvest', 'The grape harvest'), 'the beginning of the barley harvest'),
            ('What does gleaning mean in Ruth’s story?', 'Gathering grain the harvesters left behind',
             ('Building a house in a field', 'Buying a colorful coat'), 'gather grain that the harvesters left behind'),
            ('Whose field did Ruth gather grain in?', 'Boaz’s field',
             ('Joshua’s field', 'Jonah’s field'), 'The field belonged to Boaz'),
            ('What did Ruth bring back to Naomi that evening?', 'Grain and leftover food',
             ('A trumpet and a shield', 'A coat and a crown'), 'Ruth brought grain and leftover food back to Naomi'),
            ('Which small action can show care for your family, like Ruth did?', 'Help with a useful task',
             ('Leave every task for someone else', 'Promise to help but never begin'), 'care for our families through small helpful actions'),
            ('Someone is new in your class. What matches this story’s lesson?', 'Welcome them as they start in a new place',
             ('Tell them they cannot join', 'Ignore them because they are new'), 'welcome people who are starting again in a new place'),
            ('A helpful job takes time. Which choice is like Ruth’s steady care?', 'Keep working patiently, a little at a time',
             ('Stop after the first small handful', 'Leave without telling anyone'), 'Her love was more than a promise: it became patient, useful work'),
        ),
    },
)


def quiz_games():
    """Expand frozen questions into the established backend-owned quiz format."""
    positions = (0, 2, 1, 2, 0, 1, 1, 2, 0)
    games = []
    for index, story in enumerate(QUIZ_STORIES):
        levels = []
        for round_index, title in enumerate(ROUND_TITLES):
            questions = []
            for offset in range(3):
                number = round_index * 3 + offset
                prompt, answer, others, excerpt = story['questions'][number]
                questions.append(_question(
                    f"{story['slug']}-q{number + 1}", prompt, answer, others, excerpt,
                    (positions[number] + index) % 3,
                ))
            levels.append({
                'level_number': round_index + 1, 'title': title,
                'instructions': ROUND_INSTRUCTIONS[round_index],
                'max_score': 100, 'star_thresholds': [60, 80, 95],
                'config': {'questions': questions, 'pass_score': 60, 'story_slug': story['story_slug']},
            })
        games.append({
            'slug': story['slug'], 'title': story['title'], 'subtitle': story['subtitle'],
            'description': (
                f"Explore {story['title'].removesuffix(' Quiz')} in three short rounds. "
                'Remember the story, follow its clues, and choose kind everyday actions.'
            ),
            'game_type': 'quiz', 'difficulty': 'Easy', 'estimated_duration_seconds': 180,
            'cover_asset_key': story['cover_asset_key'], 'accent_color': story['accent_color'],
            'icon_key': 'quiz', 'is_featured': False, 'is_published': True,
            'sort_order': 40 + index, 'levels': levels,
        })
    return games
