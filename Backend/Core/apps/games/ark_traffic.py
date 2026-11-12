"""Authoring and deterministic, bounded replay for Noah's Ark traffic rounds.

Coordinates are normalized board units. A tick moves across at most one edge;
unused distance at a junction is discarded. Commands run before movement, and
animals move in authored order. Keep this contract in sync with the mobile model.
"""

from __future__ import annotations

import copy
import math
import re
from typing import Any


TICK_MS = 100
MAX_COMMANDS = 240
MAX_ROUTE_NODES = 24
EPSILON = 1e-9
SPECIES = {
    'tortoise': {'speed': .0028, 'radius': .022},
    'elephant': {'speed': .0046, 'radius': .038},
    'goat': {'speed': .0072, 'radius': .024},
    'rabbit': {'speed': .0105, 'radius': .018},
}
_ID = re.compile(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$')


def _object(value, allowed, required, name):
    if not isinstance(value, dict):
        raise ValueError(f'{name} must be an object.')
    if set(value) - set(allowed) or not set(required) <= set(value):
        raise ValueError(f'{name} has missing or unknown fields.')


def _integer(value, minimum, maximum, name):
    if type(value) is not int or not minimum <= value <= maximum:
        raise ValueError(f'{name} must be an integer from {minimum} to {maximum}.')


def _number(value, minimum, maximum, name):
    # Bounds first avoid float conversion overflowing for enormous JSON ints.
    if type(value) not in (int, float) or not minimum <= value <= maximum or not math.isfinite(value):
        raise ValueError(f'{name} must be a finite number from {minimum} to {maximum}.')


def _identifier(value, name):
    if not isinstance(value, str) or not _ID.fullmatch(value):
        raise ValueError(f'{name} must be a short identifier.')


def _array(value, minimum, maximum, name):
    if not isinstance(value, list) or not minimum <= len(value) <= maximum:
        raise ValueError(f'{name} must contain from {minimum} to {maximum} items.')


def _edge_key(a, b):
    return tuple(sorted((a, b)))


def _usable(edge, species):
    return edge['width'] + EPSILON >= 2 * SPECIES[species]['radius'] and (
        edge['terrain'] != 'rocky' or species == 'goat'
    )


def _validate_route(route, anchor, species, nodes, edges, ark_node, name):
    _array(route, 1, MAX_ROUTE_NODES, name)
    for node in route:
        _identifier(node, f'{name} node')
        if node not in nodes:
            raise ValueError(f'{name} contains an unknown node.')
    if route[0] != anchor:
        raise ValueError(f'{name} must begin at the current or upcoming junction.')
    if ark_node in route[:-1]:
        raise ValueError(f'{name} cannot leave the ark.')
    for a, b in zip(route, route[1:]):
        edge = edges.get(_edge_key(a, b))
        if edge is None or not _usable(edge, species):
            raise ValueError(f'{name} contains a disconnected or unsuitable trail.')


def validate_ark_traffic_config(config: dict[str, Any]) -> None:
    """Raise ValueError for unsafe or impossible authored traffic geometry."""
    if not isinstance(config, dict) or config.get('mode') != 'ark_traffic':
        raise ValueError('Ark traffic config must have mode ark_traffic.')
    traffic = config.get('traffic')
    fields = {
        'tick_ms', 'time_limit_ticks', 'nodes', 'edges', 'animals', 'ark_node',
        'gates', 'target_jam_ticks', 'replay_challenges',
    }
    _object(traffic, fields, fields - {'replay_challenges'}, 'traffic')
    if type(traffic['tick_ms']) is not int or traffic['tick_ms'] != TICK_MS:
        raise ValueError('traffic.tick_ms must be 100.')
    _integer(traffic['time_limit_ticks'], 1, 1800, 'time_limit_ticks')
    _integer(traffic['target_jam_ticks'], 1, 3600, 'target_jam_ticks')
    _array(traffic['nodes'], 2, 40, 'nodes')
    nodes = {}
    for node in traffic['nodes']:
        _object(node, {'id', 'x', 'y'}, {'id', 'x', 'y'}, 'node')
        _identifier(node['id'], 'node.id')
        _number(node['x'], 0, 1, 'node.x')
        _number(node['y'], 0, 1, 'node.y')
        if node['id'] in nodes:
            raise ValueError('Node IDs must be unique.')
        nodes[node['id']] = node
    _identifier(traffic['ark_node'], 'ark_node')
    if traffic['ark_node'] not in nodes:
        raise ValueError('ark_node must identify an authored node.')
    _array(traffic['gates'], 0, 8, 'gates')
    gates = set()
    for gate in traffic['gates']:
        _object(gate, {'id', 'open'}, {'id', 'open'}, 'gate')
        _identifier(gate['id'], 'gate.id')
        if gate['id'] in gates or type(gate['open']) is not bool:
            raise ValueError('Gates require unique IDs and a boolean open state.')
        gates.add(gate['id'])
    _array(traffic['edges'], 1, 72, 'edges')
    edges, edge_ids = {}, set()
    for edge in traffic['edges']:
        _object(edge, {'id', 'a', 'b', 'width', 'terrain', 'gate', 'route_group'},
                {'id', 'a', 'b', 'width', 'terrain', 'gate'}, 'edge')
        for field in ('id', 'a', 'b'):
            _identifier(edge[field], f'edge.{field}')
        if edge['a'] not in nodes or edge['b'] not in nodes or edge['a'] == edge['b']:
            raise ValueError('Edges require two different known endpoints.')
        a, b = nodes[edge['a']], nodes[edge['b']]
        if math.hypot(a['x'] - b['x'], a['y'] - b['y']) < .02:
            raise ValueError('Trail edges must be at least .02 board units long.')
        _number(edge['width'], .03, .30, 'edge.width')
        if edge['terrain'] not in ('trail', 'rocky', 'mud'):
            raise ValueError('Unknown trail terrain.')
        if edge['gate'] is not None:
            _identifier(edge['gate'], 'edge.gate')
            if edge['gate'] not in gates:
                raise ValueError('Edge refers to an unknown gate.')
        if 'route_group' in edge and edge['route_group'] not in ('bridge', 'rocks', 'east'):
            raise ValueError('Unknown river route group.')
        key = _edge_key(edge['a'], edge['b'])
        if key in edges or edge['id'] in edge_ids:
            raise ValueError('Edge IDs and endpoint pairs must be unique.')
        edges[key], edge_ids = edge, edge_ids | {edge['id']}
    _array(traffic['animals'], 1, 20, 'animals')
    animal_ids = set()
    for animal in traffic['animals']:
        _object(animal, {'id', 'species', 'start_node', 'route', 'start_progress'},
                {'id', 'species', 'start_node'}, 'animal')
        _identifier(animal['id'], 'animal.id')
        _identifier(animal['start_node'], 'animal.start_node')
        if animal['id'] in animal_ids or not isinstance(animal['species'], str) or animal['species'] not in SPECIES:
            raise ValueError('Animals require unique IDs and a supported species.')
        animal_ids.add(animal['id'])
        if animal['start_node'] not in nodes or animal['start_node'] == traffic['ark_node']:
            raise ValueError('Animals must start at a known node outside the ark.')
        route = animal.get('route', [animal['start_node']])
        _validate_route(route, animal['start_node'], animal['species'], nodes, edges,
                        traffic['ark_node'], 'animal.route')
        progress = animal.get('start_progress', 0)
        _number(progress, 0, 1, 'animal.start_progress')
        if progress >= 1 or (progress > 0 and len(route) < 2):
            raise ValueError('start_progress requires an active edge and must be below one.')
        # Every species must have a possible trail to the ark, even if a gate
        # initially closes it. This catches unwinnable authored rounds.
        seen, pending = {animal['start_node']}, [animal['start_node']]
        while pending:
            current = pending.pop()
            for (a, b), edge in edges.items():
                if not _usable(edge, animal['species']):
                    continue
                next_node = b if current == a else a if current == b else None
                if next_node is not None and next_node not in seen:
                    seen.add(next_node)
                    pending.append(next_node)
        if traffic['ark_node'] not in seen:
            raise ValueError('Every animal needs a usable route to the ark.')
    challenges = traffic.get('replay_challenges', [])
    _array(challenges, 0, 4, 'replay_challenges')
    challenge_ids = set()
    for challenge in challenges:
        _object(challenge, {'id', 'label', 'kind'}, {'id', 'label', 'kind'}, 'challenge')
        _identifier(challenge['id'], 'challenge.id')
        if challenge['id'] in challenge_ids or challenge['kind'] not in ('no_jam', 'different_routes'):
            raise ValueError('Replay challenges require unique IDs and known kinds.')
        if not isinstance(challenge['label'], str) or not 1 <= len(challenge['label']) <= 100:
            raise ValueError('Challenge labels must be short text.')
        challenge_ids.add(challenge['id'])


def public_ark_traffic_config(config: dict[str, Any]) -> dict[str, Any]:
    """Expose the complete map and legacy portraits without the pair answer key."""
    validate_ark_traffic_config(config)
    return {
        'mode': 'ark_traffic',
        'traffic': copy.deepcopy(config['traffic']),
        'left_items': [
            {'id': item['id'], 'label': item['label'], 'asset_key': item.get('asset_key', '')}
            for item in config.get('left_items', [])
        ],
        'right_items': [
            {'id': item['id'], 'label': item['label'], 'asset_key': item.get('asset_key', '')}
            for item in config.get('right_items', [])
        ],
    }


def _position(state, nodes):
    route, segment, progress = state['route'], state['segment'], state['progress']
    a = nodes[route[segment]]
    if segment + 1 >= len(route):
        return a['x'], a['y']
    b = nodes[route[segment + 1]]
    return a['x'] + (b['x'] - a['x']) * progress, a['y'] + (b['y'] - a['y']) * progress


def replay_ark_traffic(config: dict[str, Any], result: dict[str, Any]) -> dict[str, Any]:
    """Pure Python replay; invalid submissions raise ValueError, without Django."""
    validate_ark_traffic_config(config)
    traffic = config['traffic']
    _object(result, {'commands', 'elapsed_ticks'}, {'commands', 'elapsed_ticks'}, 'result')
    _integer(result['elapsed_ticks'], 0, traffic['time_limit_ticks'], 'elapsed_ticks')
    commands = result['commands']
    _array(commands, 0, MAX_COMMANDS, 'commands')
    nodes = {node['id']: node for node in traffic['nodes']}
    edges = {_edge_key(edge['a'], edge['b']): edge for edge in traffic['edges']}
    gates = {gate['id']: gate['open'] for gate in traffic['gates']}
    states = {}
    for animal in traffic['animals']:
        states[animal['id']] = {
            'species': animal['species'], 'route': list(animal.get('route', [animal['start_node']])),
            'segment': 0, 'progress': animal.get('start_progress', 0),
            'waiting': False, 'boarded': False, 'route_groups': set(),
        }
    prior_tick = -1
    schedule = {}
    for command in commands:
        if not isinstance(command, dict):
            raise ValueError('Every command must be an object.')
        op = command.get('op')
        fields = {'tick', 'op', 'gate_id'} if op == 'gate' else {'tick', 'op', 'animal_id'}
        if op == 'route':
            fields.add('nodes')
        if op not in ('route', 'wait', 'resume', 'gate'):
            raise ValueError('Unknown traffic command.')
        _object(command, fields, fields, 'command')
        _integer(command['tick'], 0, result['elapsed_ticks'], 'command.tick')
        if command['tick'] < prior_tick:
            raise ValueError('Commands must be in chronological order.')
        prior_tick = command['tick']
        if op == 'gate':
            _identifier(command['gate_id'], 'command.gate_id')
            if command['gate_id'] not in gates:
                raise ValueError('Command refers to an unknown gate.')
        else:
            _identifier(command['animal_id'], 'command.animal_id')
            if command['animal_id'] not in states:
                raise ValueError('Command refers to an unknown animal.')
            if op == 'route':
                route = command['nodes']
                # Validate the complete path before simulation, including late
                # commands. The live anchor is validated when it is applied.
                if not isinstance(route, list) or not route:
                    raise ValueError('Route commands require a node list.')
                _validate_route(route, route[0], states[command['animal_id']]['species'],
                                nodes, edges, traffic['ark_node'], 'command.nodes')
        schedule.setdefault(command['tick'], []).append(command)
    jam_ticks = 0
    per_animal_jams = dict.fromkeys(states, 0)
    for tick in range(result['elapsed_ticks'] + 1):
        for command in schedule.get(tick, []):
            if command['op'] == 'gate':
                gates[command['gate_id']] = not gates[command['gate_id']]
                continue
            state = states[command['animal_id']]
            if state['boarded']:
                raise ValueError('Boarded animals cannot receive commands.')
            if command['op'] == 'route':
                at_edge = state['progress'] > EPSILON
                anchor_index = state['segment'] + (1 if at_edge else 0)
                anchor = state['route'][anchor_index]
                _validate_route(command['nodes'], anchor, state['species'], nodes, edges,
                                traffic['ark_node'], 'command.nodes')
                if at_edge:
                    state['route'] = [state['route'][state['segment']], *command['nodes']]
                else:
                    state['route'] = list(command['nodes'])
                    state['progress'] = 0
                state['segment'] = 0
            elif command['op'] == 'wait':
                state['waiting'] = True
            else:
                state['waiting'] = False
        if tick == result['elapsed_ticks']:
            break
        for animal_id, state in states.items():
            segment = state['segment']
            route = state['route']
            if state['boarded'] or state['waiting'] or segment + 1 >= len(route):
                continue
            edge = edges[_edge_key(route[segment], route[segment + 1])]
            blocked = edge['gate'] is not None and not gates[edge['gate']]
            candidate = dict(state)
            if not blocked:
                a, b = nodes[route[segment]], nodes[route[segment + 1]]
                length = math.hypot(a['x'] - b['x'], a['y'] - b['y'])
                speed = SPECIES[state['species']]['speed']
                if edge['terrain'] == 'mud':
                    speed *= .75 if state['species'] == 'goat' else .45
                candidate['progress'] = min(1., state['progress'] + speed / length)
                if candidate['progress'] >= 1. - EPSILON:
                    candidate['segment'] = segment + 1
                    candidate['progress'] = 0
                old_position, new_position = _position(state, nodes), _position(candidate, nodes)
                for other_id, other in states.items():
                    # Wait is a deliberate yield to the trail shoulder. It
                    # preserves route progress while letting traffic pass.
                    if other_id == animal_id or other['boarded'] or other['waiting']:
                        continue
                    other_position = _position(other, nodes)
                    old_distance = math.dist(old_position, other_position)
                    new_distance = math.dist(new_position, other_position)
                    separation = (SPECIES[state['species']]['radius'] + SPECIES[other['species']]['radius']) * .90
                    if new_distance < separation - EPSILON and new_distance <= old_distance + EPSILON:
                        blocked = True
                        break
            if blocked:
                jam_ticks += 1
                per_animal_jams[animal_id] += 1
                continue
            state['segment'], state['progress'] = candidate['segment'], candidate['progress']
            if edge.get('route_group'):
                state['route_groups'].add(edge['route_group'])
            if state['route'][state['segment']] == traffic['ark_node']:
                state['boarded'] = True
    boarded_ids = [animal_id for animal_id, state in states.items() if state['boarded']]
    route_groups = sorted({group for state in states.values() if state['boarded'] for group in state['route_groups']})
    completed = len(boarded_ids) == len(states)
    jam_efficiency = max(0., 1. - jam_ticks / traffic['target_jam_ticks'])
    no_jam_bonus = 20. * jam_efficiency
    different_routes_bonus = 10 if len(route_groups) >= 2 else 0
    score = 70. * len(boarded_ids) / len(states) + no_jam_bonus + different_routes_bonus
    achieved = []
    for challenge in traffic.get('replay_challenges', []):
        if completed and ((challenge['kind'] == 'no_jam' and jam_ticks == 0) or (
            challenge['kind'] == 'different_routes' and len(route_groups) >= 2
        )):
            achieved.append(challenge['id'])
    return {
        'completed': completed, 'score': score, 'animals_boarded': len(boarded_ids),
        'total_animals': len(states), 'boarded_ids': boarded_ids,
        'elapsed_ticks': result['elapsed_ticks'], 'elapsed_seconds': result['elapsed_ticks'] / 10,
        'jam_ticks': jam_ticks, 'animal_jam_ticks': per_animal_jams,
        'no_jam_bonus': no_jam_bonus, 'different_routes_bonus': different_routes_bonus,
        'route_groups_used': route_groups, 'challenges_achieved': achieved,
        'positions': {animal_id: list(_position(state, nodes)) for animal_id, state in states.items()},
    }


def evaluate_ark_traffic(level, result):
    """Return the service evaluator tuple and use its public submission error."""
    from .services import GameResultError

    try:
        details = replay_ark_traffic(level.config, result)
    except ValueError as exc:
        raise GameResultError(str(exc)) from exc
    completed, score = details.pop('completed'), details.pop('score')
    if completed:
        feedback = 'Every animal is safely aboard! Try a smooth rescue or another river route.'
    else:
        feedback = f"{details['animals_boarded']} of {details['total_animals']} animals aboard. Try another rescue!"
    return completed, score, feedback, details


def build_ark_traffic_config(level_number: int, legacy_config=None):
    """The three authored portrait maps, retaining the old matching fields."""
    if level_number not in (1, 2, 3):
        raise ValueError('Ark traffic has three authored rounds.')
    points = {
        'bridge-in': (.47, .58), 'bridge-out': (.47, .41),
        'lower-hub': (.47, .73), 'west-hub': (.25, .65),
        'rock-in': (.18, .45), 'upper-west': (.33, .29),
        'upper-hub': (.70, .29), 'east-in': (.78, .65), 'east-out': (.78, .36),
        'ark': (.80, .16), 'home-elephant-1': (.39, .82),
        'home-elephant-2': (.60, .91), 'home-tortoise-2': (.65, .73),
        'home-goat-1': (.13, .83), 'home-goat-2': (.12, .69),
        'home-rabbit-1': (.84, .85), 'home-rabbit-2': (.87, .73),
    }
    links = [
        ('elephant-1-trail', 'home-elephant-1', 'lower-hub', .13, 'trail', None, None),
        ('elephant-2-trail', 'home-elephant-2', 'lower-hub', .13, 'trail', None, None),
        ('tortoise-2-trail', 'home-tortoise-2', 'lower-hub', .12, 'trail', None, None),
        ('goat-1-trail', 'home-goat-1', 'west-hub', .09, 'trail', None, None),
        ('goat-2-trail', 'home-goat-2', 'west-hub', .09, 'trail', None, None),
        ('rabbit-1-trail', 'home-rabbit-1', 'east-in', .10, 'trail', None, None),
        ('rabbit-2-trail', 'home-rabbit-2', 'east-in', .10, 'trail', None, None),
        ('bridge-approach', 'lower-hub', 'bridge-in', .12, 'trail', None, None),
        ('west-link', 'lower-hub', 'west-hub', .12, 'trail', None, None),
        ('east-link', 'lower-hub', 'east-in', .12, 'mud' if level_number == 3 else 'trail', None, None),
        ('bridge', 'bridge-in', 'bridge-out', .082, 'trail', None, 'bridge'),
        ('bridge-exit', 'bridge-out', 'upper-hub', .13, 'trail', None, None),
        ('ark-approach', 'upper-hub', 'ark', .14, 'trail', None, None),
        ('rock-crossing', 'west-hub', 'rock-in', .062, 'rocky', None, 'rocks'),
        ('rock-climb', 'rock-in', 'upper-west', .062, 'rocky', None, None),
        ('upper-west-link', 'upper-west', 'upper-hub', .12, 'trail', None, None),
        ('east-crossing', 'east-in', 'east-out', .13, 'mud' if level_number == 3 else 'trail', 'gate-a' if level_number >= 2 else None, 'east'),
        ('east-exit', 'east-out', 'upper-hub', .13, 'trail', 'gate-b' if level_number == 3 else None, None),
    ]
    animals = [
        {'id': 'tortoise-1', 'species': 'tortoise', 'start_node': 'bridge-in',
         'route': ['bridge-in', 'bridge-out'], 'start_progress': .5},
        *[
            {'id': f'elephant-{i}', 'species': 'elephant', 'start_node': 'lower-hub',
             'route': ['lower-hub', 'bridge-in'], 'start_progress': .65 if i == 1 else .05}
            for i in (1, 2)
        ],
        {'id': 'tortoise-2', 'species': 'tortoise', 'start_node': 'home-tortoise-2'},
        *[{'id': f'{species}-{i}', 'species': species, 'start_node': f'home-{species}-{i}'}
          for species in ('goat', 'rabbit') for i in (1, 2)],
    ]
    # Later rounds keep paired species, adding lower starting trails instead of
    # stacking portraits on the same physical node.
    for index in range(level_number - 1):
        species = ('goat', 'rabbit')[index]
        for offset, point in enumerate(((.12 + index * .73, .57), (.12 + index * .73, .94)), 3):
            animal_id = f'{species}-{offset}'
            home = f'home-{animal_id}'
            points[home] = point
            hub = 'west-hub' if species == 'goat' else 'east-in'
            links.append((f'{animal_id}-trail', home, hub, .10, 'trail', None, None))
            animals.append({'id': animal_id, 'species': species, 'start_node': home})
    traffic = {
        'tick_ms': TICK_MS, 'time_limit_ticks': (1200, 1500, 1800)[level_number - 1],
        'nodes': [{'id': node_id, 'x': point[0], 'y': point[1]} for node_id, point in points.items()],
        'edges': [
            {'id': edge_id, 'a': a, 'b': b, 'width': width, 'terrain': terrain, 'gate': gate,
             **({'route_group': group} if group else {})}
            for edge_id, a, b, width, terrain, gate, group in links
        ],
        'animals': animals, 'ark_node': 'ark',
        'gates': ([{'id': 'gate-a', 'open': False}] if level_number >= 2 else []) + (
            [{'id': 'gate-b', 'open': True}] if level_number == 3 else []
        ),
        'target_jam_ticks': (120, 180, 240)[level_number - 1],
        'replay_challenges': [
            {'id': 'no-jams', 'label': 'A smooth rescue', 'kind': 'no_jam'},
            {'id': 'different-routes', 'label': 'Try another river route', 'kind': 'different_routes'},
        ],
    }
    config = copy.deepcopy(legacy_config or {})
    config.update({'mode': 'ark_traffic', 'traffic': traffic})
    validate_ark_traffic_config(config)
    return config
