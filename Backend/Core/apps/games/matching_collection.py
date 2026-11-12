"""Server replay rules for the three illustrated scene-matching adventures."""

from collections import Counter
from copy import deepcopy

from .matching_studio import _integer, _object, _round_ratio, _text

SCENES = {
    'sheep_reunion': 'sheep_meadow',
    'creation_bloom': 'creation_garden',
    'esther_table': 'esther_banquet',
}
CREATION_HOMES = {'sun': 'sky', 'bird': 'sky', 'fish': 'water',
                  'tree': 'forest', 'flower': 'meadow', 'deer': 'meadow'}
FOODS = ('bread', 'grapes', 'figs', 'water', 'flowers', 'dates')


def validate_scene_matching_config(config):
    _object(config, {'mode', 'scene', 'round_number', 'targets', 'items'}, 'Scene matching config')
    mode = config['mode']
    if not isinstance(mode, str) or mode not in SCENES or config['scene'] != SCENES[mode]:
        raise ValueError('Choose a supported matching scene.')
    _integer(config['round_number'], 1, 3, 'round_number')
    targets, items = config['targets'], config['items']
    if not isinstance(targets, list) or not 3 <= len(targets) <= 6:
        raise ValueError('Scene matching needs three to six targets.')
    if not isinstance(items, list) or len(items) != 6:
        raise ValueError('Each scene has six playable pieces.')
    ids, keys, capacities = [], [], {}
    for target in targets:
        _object(target, {'id', 'match_key', 'capacity'}, 'Matching target')
        _text(target['id'], 'Target ID')
        _text(target['match_key'], 'Target match key')
        _integer(target['capacity'], 1, 6, 'Target capacity')
        ids.append(target['id'])
        keys.append(target['match_key'])
        capacities[target['match_key']] = target['capacity']
    if len(set(ids)) != len(ids) or len(set(keys)) != len(keys):
        raise ValueError('Target IDs and match keys must be unique.')
    item_ids, item_keys = [], []
    for item in items:
        _object(item, {'id', 'match_key'}, 'Matching piece')
        _text(item['id'], 'Piece ID')
        _text(item['match_key'], 'Piece match key')
        item_ids.append(item['id'])
        item_keys.append(item['match_key'])
    if len(set(item_ids)) != len(items) or Counter(item_keys) != capacities:
        raise ValueError('Every piece needs exactly one available matching place.')
    if mode == 'sheep_reunion':
        colours = {'coral', 'gold', 'teal', 'forest', 'sky', 'lilac'}
        patterns = {'dots', 'stripes', 'zigzag'}
        if len(targets) != 3 or any(t['capacity'] != 2 for t in targets):
            raise ValueError('Sheep families each welcome two lambs.')
        if any(key not in {f'{colour}_{pattern}' for colour in colours for pattern in patterns}
               for key in keys):
            raise ValueError('Sheep scarves need a supported colour and pattern.')
    elif mode == 'creation_bloom':
        if {item['id']: item['match_key'] for item in items} != CREATION_HOMES:
            raise ValueError('Each living piece must belong to its illustrated habitat.')
        if {target['id']: target['match_key'] for target in targets} != {
                key: key for key in ('sky', 'water', 'forest', 'meadow')}:
            raise ValueError('Creation needs sky, water, forest and meadow areas.')
    else:
        if set(item_ids) != set(FOODS) or any(item['id'] != item['match_key'] for item in items):
            raise ValueError('The celebration table needs six recognisable serving pieces.')
        if {target['id'] for target in targets} != {f'seat_{index}' for index in range(1, 7)}:
            raise ValueError('The celebration table has six guest places.')


def public_scene_matching_config(config):
    validate_scene_matching_config(config)
    return deepcopy(config)


def replay_scene_matching(config, result):
    validate_scene_matching_config(config)
    _object(result, {'actions'}, 'Scene matching result')
    actions = result['actions']
    if not isinstance(actions, list) or len(actions) > 120:
        raise ValueError('A scene permits at most 120 placement attempts.')
    targets = {target['id']: target for target in config['targets']}
    items = {item['id']: item for item in config['items']}
    placed, occupied, mistakes = {}, Counter(), 0
    for action in actions:
        _object(action, {'item_id', 'target_id'}, 'Scene placement')
        item_id, target_id = action['item_id'], action['target_id']
        if not isinstance(item_id, str) or item_id not in items:
            raise ValueError('A placement names an unknown piece.')
        if not isinstance(target_id, str) or target_id not in targets:
            raise ValueError('A placement names an unknown target.')
        if item_id in placed:
            raise ValueError('A placed piece cannot be used again.')
        target, item = targets[target_id], items[item_id]
        if item['match_key'] != target['match_key']:
            mistakes += 1
            continue
        if occupied[target_id] >= target['capacity']:
            raise ValueError('This matching place is already full.')
        placed[item_id] = target_id
        occupied[target_id] += 1
    completed = len(placed) == len(items)
    score = (70 + _round_ratio(30 * len(items), len(actions)) if completed
             else _round_ratio(50 * len(placed), len(items)))
    return {'completed': completed, 'score': score, 'placements': placed,
            'correct_placements': len(placed), 'item_count': len(items),
            'attempts': len(actions), 'mistakes': mistakes}


def example_scene_matching_result(config):
    return {'actions': [{'item_id': item['id'], 'target_id': next(
        target['id'] for target in config['targets'] if target['match_key'] == item['match_key'])}
        for item in config['items']]}


def build_sheep_reunion_config(round_number):
    _integer(round_number, 1, 3, 'round_number')
    keys = (('coral_dots', 'teal_stripes', 'gold_zigzag'),
            ('coral_dots', 'coral_stripes', 'teal_zigzag'),
            ('teal_dots', 'teal_stripes', 'teal_zigzag'))[round_number - 1]
    config = {'mode': 'sheep_reunion', 'scene': 'sheep_meadow', 'round_number': round_number,
              'targets': [{'id': f'family_{index + 1}', 'match_key': key, 'capacity': 2}
                          for index, key in enumerate(keys)],
              'items': [{'id': f'lamb_{index + 1}', 'match_key': keys[source]}
                        for index, source in enumerate((1, 0, 2, 0, 2, 1))]}
    validate_scene_matching_config(config)
    return config


def build_creation_bloom_config(round_number):
    _integer(round_number, 1, 3, 'round_number')
    order = (('sun', 'fish', 'tree', 'bird', 'flower', 'deer'),
             ('deer', 'bird', 'flower', 'tree', 'fish', 'sun'),
             ('fish', 'flower', 'sun', 'deer', 'bird', 'tree'))[round_number - 1]
    config = {'mode': 'creation_bloom', 'scene': 'creation_garden', 'round_number': round_number,
              'targets': [{'id': key, 'match_key': key, 'capacity': capacity}
                          for key, capacity in (('sky', 2), ('water', 1), ('forest', 1), ('meadow', 2))],
              'items': [{'id': key, 'match_key': CREATION_HOMES[key]} for key in order]}
    validate_scene_matching_config(config)
    return config


def build_esther_table_config(round_number):
    _integer(round_number, 1, 3, 'round_number')
    order = (FOODS, ('flowers', 'bread', 'water', 'dates', 'grapes', 'figs'),
             ('figs', 'water', 'dates', 'grapes', 'bread', 'flowers'))[round_number - 1]
    config = {'mode': 'esther_table', 'scene': 'esther_banquet', 'round_number': round_number,
              'targets': [{'id': f'seat_{index + 1}', 'match_key': key, 'capacity': 1}
                          for index, key in enumerate(order)],
              'items': [{'id': key, 'match_key': key} for key in reversed(FOODS)]}
    validate_scene_matching_config(config)
    return config


def evaluate_scene_matching(level, result):
    from .services import GameResultError
    try:
        details = replay_scene_matching(level.config, result)
    except ValueError as exc:
        raise GameResultError(str(exc)) from exc
    completed, score = details.pop('completed'), details.pop('score')
    celebrations = {'sheep_reunion': 'Every lamb is home with its family!',
                    'creation_bloom': 'Your beautiful garden is alive!',
                    'esther_table': 'A welcoming table, ready to share!'}
    feedback = celebrations[level.config['mode']] if completed else 'Keep exploring! Every piece has a home.'
    return completed, level.max_score * score / 100, feedback, details
