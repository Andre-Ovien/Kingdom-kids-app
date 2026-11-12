"""Bounded Bezier/arc-length contract shared with the native Ark game.

This does not author models or approve scenery. Version two courses carry the
reviewed planner's curves explicitly; client and server use the same 256-point
distance table instead of replacing a turn with a straight shortcut.
"""

import math

SAMPLES = 256
EPSILON = 1e-9
AXES = ('x', 'y', 'z')


def distance(a, b):
    return math.sqrt(sum((b[axis] - a[axis]) ** 2 for axis in AXES))


def lerp(a, b, amount):
    return {axis: a[axis] + (b[axis] - a[axis]) * amount for axis in AXES}


def bezier(points, amount):
    row = points
    while len(row) > 1:
        row = [lerp(a, b, amount) for a, b in zip(row, row[1:])]
    return row[0]


def derivative(points):
    degree = len(points) - 1
    return [{axis: degree * (b[axis] - a[axis]) for axis in AXES}
            for a, b in zip(points, points[1:])]


def angle_delta(a, b):
    return math.atan2(math.sin(a - b), math.cos(a - b))


class GardenPath:
    def __init__(self, route, curves=None):
        self.curves, self.lines = [], []
        length = 0.0
        previous = route[0]
        if curves:
            for controls in curves:
                first = derivative(controls)
                second = derivative(first)
                record = {'points': controls, 'first': first, 'second': second,
                          'start': length, 'length': 0.0, 'table': [(0.0, 0.0)]}
                previous = controls[0]
                for i in range(1, SAMPLES + 1):
                    amount = i / SAMPLES
                    point = bezier(controls, amount)
                    record['length'] += distance(previous, point)
                    record['table'].append((amount, record['length']))
                    previous = point
                self.curves.append(record)
                length += record['length']
            tail = route[2:]
        else:
            tail = route[1:]
        self.approach_length = length
        for point in tail:
            span = distance(previous, point)
            self.lines.append({'from': previous, 'to': point, 'start': length,
                               'length': span, 'phase': point['phase']})
            length += span
            previous = point
        self.length = length

    def curve_at(self, index, amount):
        curve = self.curves[index]
        tangent = bezier(curve['first'], amount)
        second = bezier(curve['second'], amount)
        speed = math.hypot(tangent['x'], tangent['y'])
        if speed <= 1e-8:
            raise ValueError('Garden curves need nonzero planar tangents.')
        return {'position': bezier(curve['points'], amount),
                'heading': math.atan2(tangent['y'], tangent['x']),
                'curvature': (tangent['x'] * second['y'] - tangent['y'] * second['x']) / speed ** 3,
                'phase': 'garden'}

    def sample(self, travelled):
        at = min(self.length, max(0.0, travelled))
        if at < self.approach_length:
            index = next(i for i, record in enumerate(self.curves)
                         if at < record['start'] + record['length'])
            curve = self.curves[index]
            local = at - curve['start']
            table = curve['table']
            low, high = 0, len(table) - 1
            while high - low > 1:
                middle = (low + high) // 2
                if table[middle][1] <= local:
                    low = middle
                else:
                    high = middle
            a, b = table[low], table[high]
            ratio = (local - a[1]) / (b[1] - a[1])
            return self.curve_at(index, a[0] + (b[0] - a[0]) * ratio)
        line = next((value for value in self.lines
                     if at + EPSILON < value['start'] + value['length']), self.lines[-1])
        return {'position': lerp(line['from'], line['to'],
                                 min(1.0, max(0.0, (at - line['start']) / line['length']))),
                'heading': math.atan2(line['to']['y'] - line['from']['y'],
                                      line['to']['x'] - line['from']['x']),
                'curvature': 0.0, 'phase': line['phase']}


def validate_curves(curves, route, width, height):
    if not isinstance(curves, list) or not 1 <= len(curves) <= 4:
        raise ValueError('Garden approaches need one to four bounded curves.')
    if [point['phase'] for point in route[:2]] != ['garden', 'garden'] or any(
            point['phase'] == 'garden' for point in route[2:]):
        raise ValueError('Curved routes need start/end garden anchors followed by stairs.')
    for controls in curves:
        if not isinstance(controls, list) or not 3 <= len(controls) <= 8:
            raise ValueError('Garden curves need three to eight control points.')
        for point in controls:
            if not isinstance(point, dict) or set(point) != set(AXES):
                raise ValueError('Curve controls need exactly x, y and z.')
            for axis, maximum in (('x', width), ('y', height), ('z', 0)):
                value = point[axis]
                if type(value) not in (int, float) or not 0 <= value <= maximum:
                    raise ValueError('Garden curve controls must stay on the bounded garden floor.')
    if distance(curves[0][0], route[0]) > EPSILON or distance(curves[-1][-1], route[1]) > EPSILON:
        raise ValueError('Curves must preserve the route start and stair approach anchors.')
    for before, after in zip(curves, curves[1:]):
        if distance(before[-1], after[0]) > EPSILON:
            raise ValueError('Garden curves must share their junction.')
    path = GardenPath(route, curves)
    for index, record in enumerate(path.curves):
        # Planner clearance certification remains an art integration requirement;
        # these bounded samples reject malformed stationary/reversing tangents.
        for amount, _ in record['table']:
            path.curve_at(index, amount)
        if index:
            before = path.curve_at(index - 1, 1)
            after = path.curve_at(index, 0)
            if abs(angle_delta(before['heading'], after['heading'])) > 1e-6 or abs(
                    before['curvature'] - after['curvature']) > 1e-6:
                raise ValueError('Garden turns must join with continuous heading and curvature.')
    end = path.curve_at(len(path.curves) - 1, 1)
    first_line = path.lines[0]
    heading = math.atan2(first_line['to']['y'] - first_line['from']['y'],
                         first_line['to']['x'] - first_line['from']['x'])
    if abs(angle_delta(end['heading'], heading)) > 1e-6 or abs(end['curvature']) > 1e-6:
        raise ValueError('The garden turn must straighten before climbing the stairs.')
    return path
