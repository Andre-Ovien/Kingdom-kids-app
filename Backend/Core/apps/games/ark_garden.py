"""Deterministic tap-to-board contract for the unpublished landscape Ark game.

World x/y/z are scene units, with z measuring height above the garden. Taps are
timestamped on 100 ms ticks. The first tap starts an animal, distance carries
through waypoint joins, and the last waypoint is far enough behind the door
to contain the complete animal. No device-supplied positions or scores count.
"""

from __future__ import annotations

import copy
import math
import re

from .ark_garden_path import validate_curves
from .ark_garden_movement import replay_curved_garden


TICK_MS = 100
MAX_TAPS = 100
MAX_ROUTE_POINTS = 32
EPSILON = 1e-9
SPECIES = (
    'elephant', 'lion', 'giraffe', 'zebra', 'dove',
    'sheep', 'camel', 'donkey', 'deer', 'rabbit',
)
PHASES = ('garden', 'stairs', 'door', 'interior')
_ID = re.compile(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$')


def _object(value, fields, name):
    if not isinstance(value, dict) or set(value) != set(fields):
        raise ValueError(f'{name} has missing or unknown fields.')


def _integer(value, minimum, maximum, name):
    if type(value) is not int or not minimum <= value <= maximum:
        raise ValueError(f'{name} must be an integer from {minimum} to {maximum}.')


def _number(value, minimum, maximum, name):
    if (type(value) not in (int, float) or not minimum <= value <= maximum
            or not math.isfinite(value)):
        raise ValueError(f'{name} must be a finite number from {minimum} to {maximum}.')


def _identifier(value, name):
    if not isinstance(value, str) or not _ID.fullmatch(value):
        raise ValueError(f'{name} must be a short identifier.')


def _distance(a, b):
    return math.sqrt(sum((b[axis] - a[axis]) ** 2 for axis in ('x', 'y', 'z')))


def _route_length(route):
    return sum(_distance(a, b) for a, b in zip(route, route[1:]))


def validate_ark_garden_config(config):
    """Validate a complete, bounded ten-species course without publishing it."""
    _object(config, {'mode', 'garden'}, 'Ark garden config')
    if config['mode'] != 'ark_garden':
        raise ValueError('Ark garden config must have mode ark_garden.')
    garden = config['garden']
    _object(garden, {'version', 'tick_ms', 'time_limit_ticks', 'world',
                     'projection', 'animals'}, 'garden')
    if type(garden['version']) is not int or garden['version'] not in (1, 2):
        raise ValueError('garden.version must be 1 or 2.')
    if type(garden['tick_ms']) is not int or garden['tick_ms'] != TICK_MS:
        raise ValueError('garden.tick_ms must be 100.')
    _integer(garden['time_limit_ticks'], 100, 1800 if garden['version'] == 1 else 6000,
             'time_limit_ticks')
    _object(garden['world'], {'width', 'height'}, 'world')
    for axis in ('width', 'height'):
        _number(garden['world'][axis], 1, 100, f'world.{axis}')
    _object(garden['projection'], {'ground_y_scale', 'elevation_y_scale'}, 'projection')
    for axis in ('ground_y_scale', 'elevation_y_scale'):
        _number(garden['projection'][axis], .01, 4, f'projection.{axis}')
    animals = garden['animals']
    if not isinstance(animals, list) or len(animals) != len(SPECIES):
        raise ValueError('The Ark garden needs exactly ten animals.')
    animal_ids, species_seen = set(), set()
    for animal in animals:
        fields = {'id', 'species', 'label', 'speed_units_per_second',
                  'body_length_units', 'route'}
        if garden['version'] == 2:
            fields.add('approach_curves')
            fields.add('body_width_units')
            fields.add('body_rear_units')
            fields.add('queue_gate_distance_units')
        _object(animal, fields, 'animal')
        _identifier(animal['id'], 'animal.id')
        species = animal['species']
        if not isinstance(species, str) or species not in SPECIES or species in species_seen:
            raise ValueError('The ten authored species must each appear exactly once.')
        if animal['id'] in animal_ids:
            raise ValueError('Animal IDs must be unique.')
        animal_ids.add(animal['id'])
        species_seen.add(species)
        if (not isinstance(animal['label'], str) or not 1 <= len(animal['label']) <= 80
                or not animal['label'].strip()):
            raise ValueError('Animal labels must be short text.')
        _number(animal['speed_units_per_second'], .05, 10, 'animal.speed_units_per_second')
        _number(animal['body_length_units'], .1, 10, 'animal.body_length_units')
        if garden['version'] == 2:
            _number(animal['body_width_units'], .1, 10, 'animal.body_width_units')
            _number(animal['body_rear_units'], 0, animal['body_length_units'], 'animal.body_rear_units')
        route = animal['route']
        if not isinstance(route, list) or not 5 <= len(route) <= MAX_ROUTE_POINTS:
            raise ValueError('Animal routes must contain five to 32 points.')
        phases = []
        for point in route:
            _object(point, {'x', 'y', 'z', 'phase'}, 'route point')
            _number(point['x'], 0, garden['world']['width'], 'route.x')
            _number(point['y'], 0, garden['world']['height'], 'route.y')
            _number(point['z'], 0, 20, 'route.z')
            if not isinstance(point['phase'], str) or point['phase'] not in PHASES:
                raise ValueError('Unknown route phase.')
            phases.append(point['phase'])
        if (phases[0] != 'garden' or phases[-1] != 'interior'
                or phases.count('stairs') < 2 or phases.count('door') != 1
                or phases.count('interior') != 1
                or [PHASES.index(phase) for phase in phases] != sorted(PHASES.index(phase) for phase in phases)):
            raise ValueError('Routes must pass through garden, rising stairs, door, and interior in order.')
        if route[0]['z'] != 0:
            raise ValueError('Animals must start on the garden floor.')
        for a, b in zip(route, route[1:]):
            if _distance(a, b) < .001:
                raise ValueError('Consecutive route points must be separate.')
        stairs = [point for point in route if point['phase'] == 'stairs']
        if any(b['z'] <= a['z'] for a, b in zip(stairs, stairs[1:])):
            raise ValueError('Stair points must rise toward the door.')
        door, interior = route[-2:]
        if abs(stairs[-1]['z'] - door['z']) > EPSILON or abs(door['z'] - interior['z']) > EPSILON:
            raise ValueError('The upper stair, door, and interior must share deck height.')
        inside_clearance = (animal['body_rear_units'] + .08 if garden['version'] == 2
                            else animal['body_length_units'])
        if _distance(door, interior) + EPSILON < inside_clearance:
            raise ValueError('Interior clearance must contain the whole animal behind the door.')
        distance_per_tick = animal['speed_units_per_second'] * TICK_MS / 1000
        path = (validate_curves(animal['approach_curves'], route,
                                garden['world']['width'], garden['world']['height'])
                if garden['version'] == 2 else None)
        route_length = path.length if path is not None else _route_length(route)
        if path is not None:
            gate_maximum = max(0.0, path.approach_length -
                               (animal['body_length_units'] - animal['body_rear_units']) - .06)
            _number(animal['queue_gate_distance_units'], 0, gate_maximum,
                    'animal.queue_gate_distance_units')
        if math.ceil(route_length / distance_per_tick - EPSILON) > garden['time_limit_ticks']:
            raise ValueError('Every animal must be able to board within the time limit.')


def public_ark_garden_config(config):
    validate_ark_garden_config(config)
    return copy.deepcopy(config)


def _position_at_distance(route, distance):
    """Interpolate continuously; carry unused movement through route joins."""
    for a, b in zip(route, route[1:]):
        length = _distance(a, b)
        if distance + EPSILON < length:
            ratio = max(0, distance / length)
            position = [a[axis] + (b[axis] - a[axis]) * ratio for axis in ('x', 'y', 'z')]
            return position, b['phase']
        distance = max(0, distance - length)
    return [route[-1][axis] for axis in ('x', 'y', 'z')], 'interior'


def replay_ark_garden(config, result):
    """Recompute each arrival from the first tap and authored three-dimensional route."""
    validate_ark_garden_config(config)
    garden = config['garden']
    _object(result, {'taps', 'elapsed_ticks'}, 'result')
    elapsed = result['elapsed_ticks']
    _integer(elapsed, 0, garden['time_limit_ticks'], 'elapsed_ticks')
    taps = result['taps']
    if not isinstance(taps, list) or not 0 <= len(taps) <= MAX_TAPS:
        raise ValueError('taps must contain at most 100 entries.')
    animals = {animal['id']: animal for animal in garden['animals']}
    first_taps, prior_tick = {}, -1
    for tap in taps:
        _object(tap, {'tick', 'animal_id'}, 'tap')
        _integer(tap['tick'], 0, elapsed, 'tap.tick')
        if tap['tick'] == garden['time_limit_ticks']:
            raise ValueError('A tap must occur before the round deadline.')
        _identifier(tap['animal_id'], 'tap.animal_id')
        if tap['animal_id'] not in animals:
            raise ValueError('A tap refers to an unknown animal.')
        if tap['tick'] < prior_tick:
            raise ValueError('Taps must be in chronological order.')
        prior_tick = tap['tick']
        first_taps.setdefault(tap['animal_id'], tap['tick'])
    positions, phases, arrival_ticks = {}, {}, {}
    curved_states = ({state['animal']['id']: state for state in replay_curved_garden(
        garden['animals'], first_taps, elapsed)} if garden['version'] == 2 else {})
    for animal_id, animal in animals.items():
        first = first_taps.get(animal_id)
        if first is None:
            positions[animal_id] = [animal['route'][0][axis] for axis in ('x', 'y', 'z')]
            phases[animal_id] = 'idle'
            continue
        if garden['version'] == 2:
            state = curved_states[animal_id]
            frame = state['frame']
            positions[animal_id] = [frame['position'][axis] for axis in ('x', 'y', 'z')]
            phases[animal_id] = frame['phase']
            if state['arrival'] is not None:
                arrival_ticks[animal_id] = state['arrival']
                phases[animal_id] = 'boarded'
            continue
        distance_per_tick = animal['speed_units_per_second'] * TICK_MS / 1000
        route_length = _route_length(animal['route'])
        travel_ticks = math.ceil(route_length / distance_per_tick - EPSILON)
        arrival = first + travel_ticks
        distance = max(0, elapsed - first) * distance_per_tick
        positions[animal_id], phases[animal_id] = _position_at_distance(animal['route'], distance)
        if arrival <= elapsed:
            arrival_ticks[animal_id] = arrival
            phases[animal_id] = 'boarded'
    count = len(arrival_ticks)
    completed = count == len(animals)
    return {
        'completed': completed,
        'score': count * 10,
        'animals_boarded': count,
        'animal_count': len(animals),
        'elapsed_ticks': elapsed,
        'remaining_ticks': garden['time_limit_ticks'] - elapsed,
        'first_tap_ticks': first_taps,
        'arrival_ticks': arrival_ticks,
        'positions': positions,
        'phases': phases,
    }


def evaluate_ark_garden(level, result):
    from .services import GameResultError

    try:
        details = replay_ark_garden(level.config, result)
    except (ValueError, TypeError, KeyError) as exc:
        raise GameResultError(str(exc)) from exc
    score = round(level.max_score * details['animals_boarded'] / details['animal_count'])
    feedback = ('All aboard! You helped every animal reach the Ark.' if details['completed']
                else 'Keep exploring the garden and help every animal get inside the Ark.')
    return details['completed'], score, feedback, details


def build_ark_garden_config(*, time_limit_seconds=60):
    """Draft course for integration tests; it does not create or publish a game.

    World coordinates/projection must be aligned to the reviewed Blender scene
    before release. This is the shared client/server version-one rule fixture.
    """
    _integer(time_limit_seconds, 10, 180, 'time_limit_seconds')
    starts = [(3, 3), (6, 9), (10, 4), (12, 11), (15, 3),
              (17, 10), (20, 4), (22, 11), (24, 2), (25, 6)]
    speeds = [1.4, 2, 1.8, 2.2, 2.6, 1.6, 1.5, 1.7, 2.1, 2.4]
    lengths = [3, 2, 2.5, 2, .4, 1.3, 2.6, 1.8, 1.6, .5]
    animals = []
    for species, (x, y), speed, body_length in zip(SPECIES, starts, speeds, lengths):
        animals.append({
            'id': species, 'species': species, 'label': species.title(),
            'speed_units_per_second': speed, 'body_length_units': body_length,
            'route': [
                {'x': x, 'y': y, 'z': 0, 'phase': 'garden'},
                {'x': 28, 'y': 2.3, 'z': 0, 'phase': 'garden'},
                {'x': 28, 'y': 3, 'z': 0, 'phase': 'stairs'},
                {'x': 28, 'y': 8, 'z': 4.3, 'phase': 'stairs'},
                {'x': 28, 'y': 9, 'z': 4.3, 'phase': 'door'},
                {'x': 28, 'y': 13, 'z': 4.3, 'phase': 'interior'},
            ],
        })
    config = {'mode': 'ark_garden', 'garden': {
        'version': 1, 'tick_ms': TICK_MS, 'time_limit_ticks': time_limit_seconds * 10,
        'world': {'width': 32, 'height': 14},
        'projection': {'ground_y_scale': .45, 'elevation_y_scale': .8},
        'animals': animals,
    }}
    validate_ark_garden_config(config)
    return config
