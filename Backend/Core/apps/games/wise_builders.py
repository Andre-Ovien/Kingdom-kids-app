"""Two houses and a storm: authoritative construction and foundation replay."""
import copy


PARTS = ('back-wall', 'left-wall', 'right-wall', 'front-wall', 'roof', 'brace')


def _int(value, low, high, field):
    if type(value) is not int or not low <= value <= high:
        raise ValueError(f'{field} must be an integer from {low} to {high}.')


def _obj(value, fields, field):
    if not isinstance(value, dict) or set(value) != set(fields):
        raise ValueError(f'{field} has missing or unknown fields.')


def validate_wise_builders_config(config):
    if not isinstance(config, dict) or config.get('mode') != 'wise_builders':
        raise ValueError('Builders config requires mode wise_builders.')
    builders = config.get('builders')
    _obj(builders, {'houses', 'parts', 'storm', 'target_moves'}, 'builders')
    houses = builders['houses']
    if not isinstance(houses, list) or len(houses) != 2:
        raise ValueError('Builders rounds compare exactly two houses.')
    ids = set()
    for house in houses:
        _obj(house, {'id', 'label'}, 'house')
        if not isinstance(house['id'], str) or not 1 <= len(house['id']) <= 64 or house['id'] in ids:
            raise ValueError('House IDs must be unique short text.')
        if not isinstance(house['label'], str) or not 1 <= len(house['label']) <= 60:
            raise ValueError('Houses need short labels.')
        ids.add(house['id'])
    parts = builders['parts']
    if not isinstance(parts, list) or parts not in (list(PARTS[:-1]), list(PARTS)):
        raise ValueError('Build four walls and a roof, with an optional storm brace.')
    if builders['storm'] not in ('rain', 'wind', 'rain_and_wind'):
        raise ValueError('Unknown builders storm.')
    _int(builders['target_moves'], len(parts) * 2 + 2, 120, 'target_moves')


def public_wise_builders_config(config):
    validate_wise_builders_config(config)
    return {'mode': 'wise_builders', 'builders': copy.deepcopy(config['builders']), 'items': []}


def replay_wise_builders(config, result):
    validate_wise_builders_config(config)
    _obj(result, {'commands', 'elapsed_seconds'}, 'result')
    _int(result['elapsed_seconds'], 0, 1800, 'elapsed_seconds')
    commands = result['commands']
    if not isinstance(commands, list) or len(commands) > 120:
        raise ValueError('Builders permits at most 120 commands.')
    authored = config['builders']
    houses = {h['id']: {'foundation': None, 'parts': [], 'collapsed': False} for h in authored['houses']}
    storms, moves, outcomes = 0, 0, {}
    for command in commands:
        if not isinstance(command, dict):
            raise ValueError('Builders commands must be objects.')
        op = command.get('op')
        if op == 'storm':
            _obj(command, {'op'}, 'storm command')
            if any(set(h['parts']) != set(authored['parts']) or h['foundation'] is None or h['collapsed'] for h in houses.values()):
                raise ValueError('Finish both houses before testing the storm.')
            storms += 1
            outcomes = {house_id: h['foundation'] == 'rock' for house_id, h in houses.items()}
            for house_id, stood in outcomes.items(): houses[house_id]['collapsed'] = not stood
            continue
        fields = {'op', 'house_id'} | ({'material'} if op == 'foundation' else {'part'} if op in ('place', 'remove') else set())
        if op not in ('foundation', 'place', 'remove', 'reset'):
            raise ValueError('Unknown builders command.')
        _obj(command, fields, 'builders command')
        house_id = command['house_id']
        if not isinstance(house_id, str) or house_id not in houses:
            raise ValueError('Unknown house.')
        house = houses[house_id]
        if op == 'reset':
            house.update(foundation=None, parts=[], collapsed=False)
            outcomes = {}
        elif op == 'foundation':
            if command['material'] not in ('rock', 'sand') or house['parts'] or house['collapsed']:
                raise ValueError('Choose rock or sand before adding house pieces.')
            house['foundation'] = command['material']
            outcomes = {}
        else:
            part = command['part']
            if not isinstance(part, str) or part not in authored['parts'] or house['foundation'] is None or house['collapsed']:
                raise ValueError('Choose a foundation and a known house piece.')
            if op == 'place':
                if part in house['parts']:
                    raise ValueError('Each house piece can be placed once.')
                if part in ('roof', 'brace') and not set(PARTS[:4]) <= set(house['parts']):
                    raise ValueError('The four walls support the roof and storm brace.')
                house['parts'].append(part)
            else:
                if part not in house['parts']:
                    raise ValueError('Only placed house pieces can be removed.')
                if part in PARTS[:4] and set(house['parts']) & {'roof', 'brace'}:
                    raise ValueError('Remove the roof and brace before a supporting wall.')
                house['parts'].remove(part)
            outcomes = {}
        moves += 1
    foundations = {h['foundation'] for h in houses.values()}
    completed = bool(outcomes) and foundations == {'rock', 'sand'} and any(outcomes.values()) and not all(outcomes.values())
    placed = sum(len(h['parts']) + (h['foundation'] is not None) for h in houses.values())
    score = max(80, 100 - max(0, moves - authored['target_moves']) * 2) if completed else 70 * placed / (2 * (len(authored['parts']) + 1))
    return {'completed': completed, 'score': score, 'houses': houses, 'storm_tests': storms,
            'storm': authored['storm'], 'stood': outcomes, 'moves': moves, 'elapsed_seconds': result['elapsed_seconds']}


def evaluate_wise_builders(level, result):
    from .services import GameResultError
    try: details = replay_wise_builders(level.config, result)
    except ValueError as exc: raise GameResultError(str(exc)) from exc
    completed, score = details.pop('completed'), details.pop('score')
    return completed, score, ('The rock foundation stayed strong! Jesus teaches us to hear his words and do them.' if completed else
                              'Build both houses and compare rock with sand in the storm.'), details


def build_wise_builders_config(level_number):
    if level_number not in (1, 2, 3): raise ValueError('Builders has three rounds.')
    parts = list(PARTS if level_number >= 2 else PARTS[:-1])
    config = {'mode': 'wise_builders', 'builders': {
        'houses': [{'id': 'house-a', 'label': 'Little house'}, {'id': 'house-b', 'label': 'Garden house'}],
        'parts': parts, 'storm': ('rain', 'wind', 'rain_and_wind')[level_number - 1],
        'target_moves': len(parts) * 2 + 4,
    }}
    validate_wise_builders_config(config)
    return config


def example_builders_result(config):
    commands = []
    for house, material in zip(config['builders']['houses'], ('rock', 'sand')):
        commands.append({'op': 'foundation', 'house_id': house['id'], 'material': material})
        commands.extend({'op': 'place', 'house_id': house['id'], 'part': part} for part in config['builders']['parts'])
    commands.append({'op': 'storm'})
    return {'commands': commands, 'elapsed_seconds': 90}
