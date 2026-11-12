"""Deterministic, patient boarding for the version-two Ark garden course."""

import math

from .ark_garden_path import GardenPath

GAP = .06
STEP = .05
EPSILON = 1e-9


def _rectangle(frame, animal):
    heading = frame['heading']
    forward = (math.cos(heading), math.sin(heading))
    side = (-forward[1], forward[0])
    position = frame['position']
    front = animal['body_length_units'] - animal['body_rear_units'] + GAP
    rear = animal['body_rear_units'] + GAP
    half_width = animal['body_width_units'] / 2 + GAP
    corners = [(position['x'] + a * forward[0] + b * side[0] * half_width,
                position['y'] + a * forward[1] + b * side[1] * half_width)
               for a in (-rear, front) for b in (-1, 1)]
    return {'axes': (forward, side), 'corners': corners}


def _overlaps(a, b):
    for axis in (*a['axes'], *b['axes']):
        first = [x * axis[0] + y * axis[1] for x, y in a['corners']]
        second = [x * axis[0] + y * axis[1] for x, y in b['corners']]
        if max(first) <= min(second) + EPSILON or max(second) <= min(first) + EPSILON:
            return False
    return True


def replay_curved_garden(animals, first_taps, elapsed):
    """Mirror ArkGardenRun's queue without accepting any submitted positions.

    One animal owns the stairs until its tail is fully inside. The others wait
    with their own footprint clear of waiting/idle bodies, then resume without
    another tap. Movement uses 5 cm substeps to avoid skipping a small animal.
    This is a simple boarding rule, not a claim of rigid-body contact physics.
    """
    states = []
    for order, animal in enumerate(animals):
        path = GardenPath(animal['route'], animal['approach_curves'])
        states.append({'animal': animal, 'path': path, 'order': order,
                       'distance': 0.0, 'arrival': None,
                       'tap': first_taps.get(animal['id']),
                       'gate': animal['queue_gate_distance_units'],
                       'frame': path.sample(0)})
        states[-1]['rectangle'] = _rectangle(states[-1]['frame'], animal)
    owner = None
    priority = sorted(states, key=lambda state: (state['tap'] if state['tap'] is not None else elapsed + 1,
                                                 state['order']))
    for tick in range(1, elapsed + 1):
        if owner is not None and owner['arrival'] is not None:
            owner = None
        rectangles = {state['animal']['id']: state['rectangle']
                      for state in states if state['arrival'] is None}
        for state in priority:
            if state['tap'] is None or state['tap'] >= tick or state['arrival'] is not None:
                continue
            animal, path = state['animal'], state['path']
            desired = min(path.length, state['distance'] + animal['speed_units_per_second'] * .1)
            if owner is not None and owner is not state:
                desired = min(desired, state['gate'])
            # Ordered short substeps and the same rectangle maths are shared
            # with Dart. A rejected step leaves the animal naturally waiting.
            while desired - state['distance'] > EPSILON:
                next_distance = min(desired, state['distance'] + STEP)
                frame = path.sample(next_distance)
                rectangle = _rectangle(frame, animal)
                if any(_overlaps(rectangle, other) for identifier, other in rectangles.items()
                       if identifier != animal['id']):
                    break
                if next_distance > state['gate'] + EPSILON:
                    if owner is not None and owner is not state:
                        break
                    owner = state
                state['distance'], state['frame'] = next_distance, frame
                state['rectangle'] = rectangle
                rectangles[animal['id']] = rectangle
            if state['distance'] + EPSILON >= path.length:
                state['distance'] = path.length
                state['frame'] = path.sample(path.length)
                state['arrival'] = tick
                rectangles.pop(animal['id'], None)
                if owner is state:
                    owner = None
        if all(state['arrival'] is not None for state in states):
            break
    return states
