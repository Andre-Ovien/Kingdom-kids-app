"""A living Creation world: fixed Bible days, many valid landscapes."""
from __future__ import annotations

import copy
from collections import deque


KINDS = {'light', 'cloud', 'water', 'land', 'forest', 'sun', 'moon', 'fish', 'bird', 'goat', 'rabbit'}
FLOORS = {'water', 'land', 'forest'}
SKY = {'light', 'cloud', 'sun', 'moon'}
DAY_FOR_KIND = {'light': 1, 'cloud': 2, 'water': 3, 'land': 3, 'forest': 3,
                'sun': 4, 'moon': 4, 'fish': 5, 'bird': 5, 'goat': 6, 'rabbit': 6}
DAY_LABELS = ['Light', 'Sky', 'Land, seas and plants', 'Sun, moon and stars',
              'Fish and birds', 'Animals and people', 'A day of rest']


def _int(value, low, high, field):
    if type(value) is not int or not low <= value <= high:
        raise ValueError(f'{field} must be an integer from {low} to {high}.')


def _obj(value, fields, field):
    if not isinstance(value, dict) or set(value) != set(fields):
        raise ValueError(f'{field} has missing or unknown fields.')


def _neighbors(cell, rows, columns):
    row, column = divmod(cell, columns)
    return [r * columns + c for r, c in ((row - 1, column), (row + 1, column),
                                           (row, column - 1), (row, column + 1))
            if 0 <= r < rows and 0 <= c < columns]


def _connected(start, allowed, rows, columns):
    if start not in allowed:
        return set()
    seen, queue = {start}, deque([start])
    while queue:
        for cell in _neighbors(queue.popleft(), rows, columns):
            if cell in allowed and cell not in seen:
                seen.add(cell)
                queue.append(cell)
    return seen


def validate_creation_world_config(config):
    if not isinstance(config, dict) or config.get('mode') != 'living_world':
        raise ValueError('Creation config requires mode living_world.')
    world = config.get('world')
    _obj(world, {'rows', 'columns', 'days', 'river_start', 'river_end', 'pieces', 'target_moves'}, 'world')
    _int(world['rows'], 2, 6, 'rows')
    _int(world['columns'], 3, 6, 'columns')
    count = world['rows'] * world['columns']
    for field in ('river_start', 'river_end'):
        _int(world[field], 0, count - 1, field)
    if world['river_start'] == world['river_end']:
        raise ValueError('The river needs different source and outlet cells.')
    days = world['days']
    if not isinstance(days, list) or any(type(day) is not int for day in days) or days not in (list(range(1, 4)), list(range(1, 6)), list(range(1, 8))):
        raise ValueError('Creation rounds use the first three, five, or seven Bible days.')
    pieces = world['pieces']
    if not isinstance(pieces, list) or not 6 <= len(pieces) <= 50:
        raise ValueError('The world needs a bounded collection of pieces.')
    ids = set()
    for piece in pieces:
        _obj(piece, {'id', 'kind', 'day', 'label'}, 'piece')
        if not isinstance(piece['id'], str) or not 1 <= len(piece['id']) <= 64 or piece['id'] in ids:
            raise ValueError('Piece IDs must be unique short text.')
        ids.add(piece['id'])
        if not isinstance(piece['kind'], str) or piece['kind'] not in KINDS:
            raise ValueError('Unknown world piece kind.')
        if type(piece['day']) is not int or piece['day'] != DAY_FOR_KIND[piece['kind']] or piece['day'] not in days:
            raise ValueError('World pieces must belong to their Bible day.')
        if not isinstance(piece['label'], str) or not 1 <= len(piece['label']) <= 80:
            raise ValueError('World pieces need short labels.')
    kinds = [piece['kind'] for piece in pieces]
    if any(kind not in kinds for kind in ('light', 'cloud', 'water', 'land', 'forest')):
        raise ValueError('Creation worlds need light, sky, water, land and plants.')
    if sum(kind in FLOORS for kind in kinds) > count:
        raise ValueError('There are more ground pieces than board cells.')
    if sum(kind in SKY for kind in kinds) > world['columns']:
        raise ValueError('There are too many sky pieces for the top row.')
    distance = abs(world['river_start'] // world['columns'] - world['river_end'] // world['columns']) + abs(
        world['river_start'] % world['columns'] - world['river_end'] % world['columns']) + 1
    if kinds.count('water') < distance or kinds.count('land') < 4:
        raise ValueError('The world needs enough water to connect its river and four meadow tiles.')
    _int(world['target_moves'], len(pieces), 300, 'target_moves')


def public_creation_world_config(config):
    validate_creation_world_config(config)
    return {'mode': 'living_world', 'world': copy.deepcopy(config['world']),
            'items': [{key: item[key] for key in ('id', 'label', 'asset_key') if key in item}
                      for item in config.get('items', [])]}


def world_requirements(world, placements, day):
    """Return live habitat facts; forests occupy ground and interrupt meadow routes."""
    pieces = {piece['id']: piece for piece in world['pieces']}
    floors = {cell: pieces[piece_id]['kind'] for piece_id, cell in placements.items()
              if pieces[piece_id]['kind'] in FLOORS}
    water = {cell for cell, kind in floors.items() if kind == 'water'}
    land = {cell for cell, kind in floors.items() if kind == 'land'}
    river = _connected(world['river_start'], water, world['rows'], world['columns'])
    meadow = _connected(min(land), land, world['rows'], world['columns']) if land else set()
    facts = {
        'all_day_pieces': all(piece['id'] in placements for piece in world['pieces'] if piece['day'] <= day),
        'river_connected': world['river_end'] in river,
        'meadow_connected': len(land) >= 4 and len(meadow) == len(land),
        'fish_safe': True, 'birds_safe': True, 'animals_safe': True,
    }
    for piece_id, cell in placements.items():
        kind = pieces[piece_id]['kind']
        if kind == 'fish' and cell not in river:
            facts['fish_safe'] = False
        elif kind == 'bird' and floors.get(cell) != 'forest':
            facts['birds_safe'] = False
        elif kind in ('goat', 'rabbit') and cell not in meadow:
            facts['animals_safe'] = False
    ready = facts['all_day_pieces'] and (day < 3 or (facts['river_connected'] and facts['meadow_connected']))
    if day >= 5:
        ready = ready and facts['fish_safe'] and facts['birds_safe']
    if day >= 6:
        ready = ready and facts['animals_safe']
    return {**facts, 'ready': ready, 'river_cells': sorted(river), 'meadow_cells': sorted(meadow)}


def replay_creation_world(config, result):
    validate_creation_world_config(config)
    _obj(result, {'commands', 'elapsed_seconds'}, 'result')
    _int(result['elapsed_seconds'], 0, 1800, 'elapsed_seconds')
    commands = result['commands']
    if not isinstance(commands, list) or len(commands) > 300:
        raise ValueError('Creation permits at most 300 commands.')
    world = config['world']
    pieces = {piece['id']: piece for piece in world['pieces']}
    placements, completed_days, moves = {}, 0, 0
    for command in commands:
        if not isinstance(command, dict):
            raise ValueError('World commands must be objects.')
        op = command.get('op')
        if op == 'advance':
            _obj(command, {'op', 'day'}, 'advance command')
            _int(command['day'], 1, len(world['days']), 'day')
            if command['day'] != completed_days + 1:
                raise ValueError('Creation days must advance in Bible order.')
            if not world_requirements(world, placements, command['day'])['ready']:
                raise ValueError('This day needs its pieces and a connected, safe world.')
            completed_days += 1
            continue
        if op not in ('place', 'remove'):
            raise ValueError('Unknown world command.')
        _obj(command, {'op', 'piece_id', 'cell'} if op == 'place' else {'op', 'piece_id'}, 'piece command')
        piece_id = command['piece_id']
        if not isinstance(piece_id, str) or piece_id not in pieces:
            raise ValueError('World command refers to an unknown piece.')
        piece = pieces[piece_id]
        if piece['day'] > min(completed_days + 1, len(world['days'])):
            raise ValueError('That piece belongs to a later Creation day.')
        if op == 'remove':
            if piece_id not in placements:
                raise ValueError('Only placed pieces can be removed.')
            del placements[piece_id]
        else:
            cell = command['cell']
            _int(cell, 0, world['rows'] * world['columns'] - 1, 'cell')
            if piece['kind'] in SKY and cell >= world['columns']:
                raise ValueError('Sky pieces belong in the top row.')
            layer = 'ground' if piece['kind'] in FLOORS else 'sky' if piece['kind'] in SKY else 'life'
            for other_id, other_cell in placements.items():
                other_kind = pieces[other_id]['kind']
                other_layer = 'ground' if other_kind in FLOORS else 'sky' if other_kind in SKY else 'life'
                if other_id != piece_id and cell == other_cell and layer == other_layer:
                    raise ValueError('Move the existing piece before using this space.')
            placements[piece_id] = cell
        moves += 1
    facts = world_requirements(world, placements, len(world['days']))
    completed = completed_days == len(world['days']) and facts['ready']
    if completed:
        score = max(80, 100 - max(0, moves - world['target_moves']) * .5)
    else:
        score = 60 * len(placements) / len(pieces) + 20 * completed_days / len(world['days'])
    return {'completed': completed, 'score': score, 'placements': placements,
            'completed_days': completed_days, 'total_days': len(world['days']), 'moves': moves,
            'elapsed_seconds': result['elapsed_seconds'], 'habitats': facts}


def evaluate_creation_world(level, result):
    from .services import GameResultError
    try:
        details = replay_creation_world(level.config, result)
    except ValueError as exc:
        raise GameResultError(str(exc)) from exc
    completed, score = details.pop('completed'), details.pop('score')
    feedback = ('Your world is alive! Tap the creatures and explore what you made.' if completed else
                'Keep building: connect the river, leave a meadow route, and give each creature a home.')
    return completed, score, feedback, details


def build_creation_world_config(level_number, legacy_config=None):
    if level_number not in (1, 2, 3):
        raise ValueError('Creation has three living world rounds.')
    days = list(range(1, (3, 5, 7)[level_number - 1] + 1))
    groups = [('light', 1), ('cloud', 1), ('water', 6), ('land', 8), ('forest', 2)]
    if level_number >= 2:
        groups += [('sun', 1), ('moon', 1), ('fish', 1), ('bird', 1)]
    if level_number == 3:
        groups += [('goat', 1), ('rabbit', 1)]
    pieces = [{'id': f'{kind}-{i + 1}', 'kind': kind, 'day': DAY_FOR_KIND[kind],
               'label': f'{kind.title()} {i + 1}' if count > 1 else kind.title()}
              for kind, count in groups for i in range(count)]
    config = copy.deepcopy(legacy_config or {})
    config.update({'mode': 'living_world', 'world': {
        'rows': 4, 'columns': 5, 'days': days, 'river_start': 0, 'river_end': 15,
        'pieces': pieces, 'target_moves': len(pieces) + 8,
    }})
    validate_creation_world_config(config)
    return config


def example_creation_result(config):
    """One legal landscape for smoke tests; none of these cells are private answers."""
    commands = []
    cells = {'light': [0], 'cloud': [1], 'water': [0, 5, 10, 15, 1, 2],
             'land': [3, 4, 8, 9, 13, 14, 18, 19], 'forest': [6, 11],
             'sun': [2], 'moon': [3], 'fish': [5], 'bird': [6], 'goat': [3], 'rabbit': [19]}
    for day in config['world']['days']:
        for piece in config['world']['pieces']:
            if piece['day'] == day:
                index = int(piece['id'].rsplit('-', 1)[1]) - 1
                commands.append({'op': 'place', 'piece_id': piece['id'], 'cell': cells[piece['kind']][index]})
        commands.append({'op': 'advance', 'day': day})
    return {'commands': commands, 'elapsed_seconds': 120}
