from collections import Counter, deque
from math import isfinite

from django.core.exceptions import ValidationError
from .ark_garden import validate_ark_garden_config
from .ark_traffic import validate_ark_traffic_config
from .creation_world import validate_creation_world_config
from .wise_builders import validate_wise_builders_config
from .matching_studio import validate_coat_studio_config, validate_harvest_chain_config
from .matching_collection import SCENES, validate_scene_matching_config


GAME_TYPES = {
    'quiz',
    'memory',
    'ordering',
    'matching',
    'maze',
    'path',
    'aim',
    'puzzle',
}


def validate_level_definition(*, game_type, config, max_score, star_thresholds):
    """Validate admin-authored content before it can become playable."""

    errors = {}
    if not isinstance(config, dict):
        errors['config'] = 'Level configuration must be an object.'
    if not isinstance(max_score, int) or isinstance(max_score, bool) or max_score < 1:
        errors['max_score'] = 'Maximum score must be a positive integer.'
    if not _valid_thresholds(star_thresholds, max_score):
        errors['star_thresholds'] = (
            'Star thresholds must contain three increasing integers between '
            'zero and the maximum score.'
        )
    if errors:
        raise ValidationError(errors)

    try:
        if game_type == 'quiz':
            _validate_quiz(config, max_score)
        elif game_type == 'ordering':
            _validate_ordering(config)
        elif game_type == 'matching':
            _validate_matching(config)
        elif game_type == 'memory':
            _validate_memory(config)
        elif game_type in {'maze', 'path'}:
            _validate_grid(config)
            if game_type == 'maze' and 'sailing' in config:
                validate_sailing_config(config['sailing'])
            if game_type == 'path' and 'crossing' in config:
                validate_crossing_config(config['crossing'])
        elif game_type == 'aim':
            _validate_aim(config)
        elif game_type == 'puzzle':
            _validate_puzzle(config)
        else:
            raise ValueError('Choose a supported game type.')
    except (KeyError, TypeError, ValueError) as exc:
        raise ValidationError({'config': str(exc)}) from exc


def _valid_thresholds(values, max_score):
    return (
        isinstance(values, list)
        and len(values) == 3
        and all(_is_int(value) for value in values)
        and values == sorted(values)
        and len(set(values)) == 3
        and all(0 <= value <= max_score for value in values)
    )


def _validate_quiz(config, max_score):
    questions = config.get('questions')
    if not isinstance(questions, list) or not questions:
        raise ValueError('Quiz levels need at least one question.')
    question_ids = []
    for question in questions:
        if not isinstance(question, dict):
            raise ValueError('Every quiz question must be an object.')
        question_id = _required_text(question, 'id', 'question')
        _required_text(question, 'prompt', 'question prompt')
        question_ids.append(question_id)
        options = question.get('options')
        if not isinstance(options, list) or len(options) < 2:
            raise ValueError('Every quiz question needs at least two options.')
        option_ids = []
        for option in options:
            if not isinstance(option, dict):
                raise ValueError('Every quiz option must be an object.')
            option_ids.append(_required_text(option, 'id', 'option'))
            _required_text(option, 'text', 'option text')
        _require_unique(option_ids, 'Quiz option IDs')
        if question.get('correct_option_id') not in option_ids:
            raise ValueError('Each quiz answer must reference one of its options.')
    _require_unique(question_ids, 'Quiz question IDs')
    pass_score = config.get('pass_score', 60)
    if not _is_int(pass_score) or not 0 <= pass_score <= max_score:
        raise ValueError('Quiz pass_score must be between zero and max_score.')


def _validate_ordering(config):
    if config.get('mode') == 'living_world':
        validate_creation_world_config(config)
        return
    if config.get('mode') == 'wise_builders':
        validate_wise_builders_config(config)
        return
    item_ids = _item_ids(config.get('items'), 'Ordering')
    sequence = config.get('answer_sequence')
    if not isinstance(sequence, list) or sequence != list(dict.fromkeys(sequence)):
        raise ValueError('Ordering answer_sequence must contain unique item IDs.')
    if set(sequence) != set(item_ids) or len(sequence) != len(item_ids):
        raise ValueError('Ordering answer_sequence must use every item exactly once.')


def _validate_matching(config):
    if config.get('mode') in SCENES:
        validate_scene_matching_config(config)
        return
    if config.get('mode') == 'coat_studio':
        validate_coat_studio_config(config)
        return
    if config.get('mode') == 'harvest_chain':
        validate_harvest_chain_config(config)
        return
    if config.get('mode') == 'ark_garden':
        validate_ark_garden_config(config)
        return
    if config.get('mode') == 'ark_traffic':
        validate_ark_traffic_config(config)
        return
    left_ids = _item_ids(config.get('left_items'), 'Matching left')
    right_ids = _item_ids(config.get('right_items'), 'Matching right')
    pairs = config.get('expected_pairs')
    if not isinstance(pairs, dict):
        raise ValueError('Matching levels need an expected_pairs object.')
    if set(pairs) != set(left_ids) or set(pairs.values()) != set(right_ids):
        raise ValueError('Matching pairs must use every left and right item exactly once.')
    if len(left_ids) != len(right_ids):
        raise ValueError('Matching levels need the same number of items on both sides.')
    mode = config.get('mode')
    if mode is not None and mode != 'ark_boarding':
        raise ValueError('Choose a supported matching mode.')
    if mode == 'ark_boarding':
        limit = config.get('time_limit_seconds')
        goal = config.get('goal_pairs')
        if not _is_int(limit) or not 10 <= limit <= 180:
            raise ValueError('Ark time_limit_seconds must be between 10 and 180.')
        if not _is_int(goal) or not 1 <= goal <= len(left_ids):
            raise ValueError('Ark goal_pairs must fit the available animal pairs.')
        left_items = {value['id']: value for value in config['left_items']}
        right_items = {value['id']: value for value in config['right_items']}
        for left_id, right_id in pairs.items():
            left_animal = left_items[left_id]
            right_animal = right_items[right_id]
            portrait = left_animal.get('asset_key')
            if (
                not isinstance(portrait, str)
                or not portrait.startswith('animal:')
                or portrait != right_animal.get('asset_key')
                or left_animal['label'] != right_animal['label']
            ):
                raise ValueError('Each ark pair must show the same animal portrait and label.')


def _validate_memory(config):
    cards = config.get('cards')
    if not isinstance(cards, list) or len(cards) < 2 or len(cards) % 2:
        raise ValueError('Memory levels need an even number of cards.')
    ids = []
    match_keys = []
    for card in cards:
        if not isinstance(card, dict):
            raise ValueError('Every memory card must be an object.')
        ids.append(_required_text(card, 'id', 'memory card'))
        _required_text(card, 'label', 'memory card label')
        match_keys.append(_required_text(card, 'match_key', 'memory match key'))
    _require_unique(ids, 'Memory card IDs')
    if any(count != 2 for count in Counter(match_keys).values()):
        raise ValueError('Every memory match key must appear on exactly two cards.')
    preview = config.get('preview_seconds', 3)
    if not _is_number(preview) or not 0 <= preview <= 30:
        raise ValueError('Memory preview_seconds must be between zero and 30.')
    target = config.get('target_seconds', 45)
    if not _is_int(target) or not 1 <= target <= 3_600:
        raise ValueError('Memory target_seconds must be between one and 3600.')


def validate_sailing_config(sailing):
    """Validate the continuous ocean rules before either rendering or scoring."""

    if not isinstance(sailing, dict):
        raise ValueError('Sailing configuration must be an object.')
    if not _is_int(sailing.get('duration_seconds')) or sailing['duration_seconds'] != 60:
        raise ValueError('A sailing voyage must last 60 seconds.')
    distance = sailing.get('distance_m')
    if not _is_number(distance) or not 1 <= distance <= 100_000:
        raise ValueError('Sailing distance must be positive and bounded.')
    for field, minimum, maximum in (
        ('ship_radius', 0.01, 0.2),
        ('collision_window', 0.002, 0.015),
        ('steer_speed', 0.1, 3.0),
    ):
        value = sailing.get(field)
        if not _is_number(value) or not minimum <= value <= maximum:
            raise ValueError(f'Sailing {field} must be finite and bounded.')
    if not _is_int(sailing.get('max_hits')) or sailing['max_hits'] != 3:
        raise ValueError('A sailing voyage allows three hits.')
    obstacles = sailing.get('obstacles')
    if not isinstance(obstacles, list) or not 1 <= len(obstacles) <= 20:
        raise ValueError('Sailing needs between one and twenty obstacles.')
    ids = []
    previous_progress = None
    for obstacle in obstacles:
        if not isinstance(obstacle, dict):
            raise ValueError('Every sailing obstacle must be an object.')
        ids.append(_required_text(obstacle, 'id', 'sailing obstacle'))
        progress = obstacle.get('progress')
        x = obstacle.get('x')
        radius = obstacle.get('radius')
        if not _is_number(progress) or not 0.12 < progress < 0.9:
            raise ValueError('Sailing obstacles must leave clear launch and landing water.')
        if previous_progress is not None and progress - previous_progress < 0.035 - 1e-8:
            raise ValueError('Sailing obstacles must be ordered with room to steer.')
        if not _is_number(x) or not -1 <= x <= 1:
            raise ValueError('Sailing obstacle x must stay inside the ocean.')
        if not _is_number(radius) or not 0.12 <= radius <= 0.2:
            raise ValueError('Sailing obstacle radius must be between 0.12 and 0.2.')
        previous_progress = progress
    _require_unique(ids, 'Sailing obstacle IDs')


def validate_crossing_config(crossing):
    """Validate the authored travellers and normalized dry-path drop area."""

    if not isinstance(crossing, dict):
        raise ValueError('Crossing configuration must be an object.')
    limit = crossing.get('time_limit_seconds')
    if not _is_int(limit) or not 10 <= limit <= 180:
        raise ValueError('Crossing time limit must be between ten and 180 seconds.')
    travellers = crossing.get('travellers')
    if not isinstance(travellers, list) or not 1 <= len(travellers) <= 20:
        raise ValueError('Crossing needs between one and twenty travellers.')
    ids = []
    for traveller in travellers:
        if not isinstance(traveller, dict):
            raise ValueError('Every crossing traveller must be an object.')
        ids.append(_required_text(traveller, 'id', 'crossing traveller'))
        _required_text(traveller, 'label', 'crossing traveller label')
    _require_unique(ids, 'Crossing traveller IDs')
    zone = crossing.get('drop_zone')
    if not isinstance(zone, dict):
        raise ValueError('Crossing needs a normalized drop_zone object.')
    if not all(
        _is_number(zone.get(field)) and 0 <= zone[field] <= 1
        for field in ('left', 'top', 'right', 'bottom')
    ):
        raise ValueError('Crossing drop coordinates must be finite values from zero to one.')
    if zone['right'] - zone['left'] < 0.05 or zone['bottom'] - zone['top'] < 0.05:
        raise ValueError('Crossing drop zone needs enough dry space in both dimensions.')
    if 'polygon' in zone:
        _validate_crossing_polygon(zone['polygon'])


def _validate_crossing_polygon(polygon):
    if not isinstance(polygon, list) or not 3 <= len(polygon) <= 16:
        raise ValueError('Crossing dry-path polygon needs between three and sixteen vertices.')
    for point in polygon:
        if (
            not isinstance(point, list)
            or len(point) != 2
            or not all(_is_number(value) and 0 <= value <= 1 for value in point)
        ):
            raise ValueError('Crossing polygon vertices must be finite normalized [x, y] pairs.')
    if len({tuple(point) for point in polygon}) != len(polygon):
        raise ValueError('Crossing polygon vertices cannot repeat.')
    area = sum(
        start[0] * end[1] - end[0] * start[1]
        for start, end in zip(polygon, polygon[1:] + polygon[:1])
    )
    if abs(area) <= 1e-6:
        raise ValueError('Crossing dry-path polygon must enclose usable land.')
    direction = 1 if area > 0 else -1
    # Every vertex must lie on the inner side of every edge. This also rejects
    # crossed edges and concave shapes, keeping client and server drop rules equal.
    for start, end in zip(polygon, polygon[1:] + polygon[:1]):
        for point in polygon:
            cross = ((end[0] - start[0]) * (point[1] - start[1])
                     - (end[1] - start[1]) * (point[0] - start[0]))
            if cross * direction < -1e-9:
                raise ValueError('Crossing dry-path polygon must be convex with uncrossed edges.')


def crossing_drop_contains(zone, x, y):
    """Use authored land edges when present; keep old rectangular courses playable."""

    if not _is_number(x) or not _is_number(y):
        return False
    polygon = zone.get('polygon')
    if polygon is None:
        return zone['left'] <= x <= zone['right'] and zone['top'] <= y <= zone['bottom']
    positive = negative = False
    for start, end in zip(polygon, polygon[1:] + polygon[:1]):
        cross = ((end[0] - start[0]) * (y - start[1])
                 - (end[1] - start[1]) * (x - start[0]))
        positive = positive or cross > 1e-9
        negative = negative or cross < -1e-9
        if positive and negative:
            return False
    return True


def _validate_grid(config):
    grid = config.get('grid')
    if not isinstance(grid, dict):
        raise ValueError('Maze and path levels need a grid object.')
    rows = grid.get('rows')
    columns = grid.get('columns')
    if not _is_int(rows) or not _is_int(columns) or not (2 <= rows <= 10 and 2 <= columns <= 10):
        raise ValueError('Grid rows and columns must each be between two and 10.')
    start = _coordinate(grid.get('start'), rows, columns)
    end = _coordinate(grid.get('end'), rows, columns)
    if start == end:
        raise ValueError('Grid start and end must be different.')
    raw_walls = grid.get('walls', [])
    if not isinstance(raw_walls, list):
        raise ValueError('Grid walls must be a list.')
    walls = {_coordinate(value, rows, columns) for value in raw_walls}
    if len(walls) != len(raw_walls):
        raise ValueError('Grid walls cannot repeat.')
    if start in walls or end in walls:
        raise ValueError('Grid start and end cannot be walls.')
    if not _has_route(rows, columns, start, end, walls):
        raise ValueError('Grid must contain a route from start to end.')
    decorations = grid.get('decorations', [])
    if not isinstance(decorations, list):
        raise ValueError('Grid decorations must be a list.')
    for decoration in decorations:
        if not isinstance(decoration, dict):
            raise ValueError('Every grid decoration must be an object.')
        _coordinate(decoration.get('position'), rows, columns)


def _validate_aim(config):
    canvas = config.get('canvas')
    target = config.get('target')
    if not isinstance(canvas, dict) or not isinstance(target, dict):
        raise ValueError('Aim levels need canvas and target objects.')
    width = canvas.get('width')
    height = canvas.get('height')
    if not _is_number(width) or not _is_number(height) or not (100 <= width <= 1_000 and 100 <= height <= 1_000):
        raise ValueError('Aim canvas dimensions must be between 100 and 1000.')
    x = target.get('x')
    y = target.get('y')
    radius = target.get('radius')
    if not all(_is_number(value) for value in (x, y, radius)):
        raise ValueError('Aim target geometry must be numeric.')
    if not (0 <= x <= width and 0 <= y <= height and 1 <= radius <= min(width, height) / 2):
        raise ValueError('Aim target must fit inside the canvas.')
    shots = config.get('max_shots', 3)
    if not _is_int(shots) or not 1 <= shots <= 10:
        raise ValueError('Aim max_shots must be between one and 10.')
    obstacles = config.get('obstacles', [])
    if not isinstance(obstacles, list) or any(not isinstance(item, dict) for item in obstacles):
        raise ValueError('Aim obstacles must be a list of objects.')


def _validate_puzzle(config):
    artwork = config.get('artwork')
    if not isinstance(artwork, dict):
        raise ValueError('Puzzle levels need an artwork object.')
    _required_text(artwork, 'asset_key', 'puzzle artwork')
    _required_text(artwork, 'title', 'puzzle artwork')
    _required_text(artwork, 'alt_text', 'puzzle artwork')
    aspect_ratio = artwork.get('aspect_ratio')
    if not _is_number(aspect_ratio) or not 0.5 <= aspect_ratio <= 2:
        raise ValueError('Puzzle artwork aspect_ratio must be between 0.5 and 2.')

    grid = config.get('grid')
    if not isinstance(grid, dict):
        raise ValueError('Puzzle levels need a grid object.')
    rows = grid.get('rows')
    columns = grid.get('columns')
    if (
        not _is_int(rows)
        or not _is_int(columns)
        or not (2 <= rows <= 3 and 2 <= columns <= 3)
    ):
        raise ValueError('Puzzle rows and columns must each be between two and three.')
    expected_positions = {
        (row, column)
        for row in range(rows)
        for column in range(columns)
    }
    piece_count = rows * columns

    slots = config.get('slots')
    if not isinstance(slots, list) or len(slots) != piece_count:
        raise ValueError('Puzzle slots must fill every grid position exactly once.')
    slot_ids = []
    slot_positions = {}
    for slot in slots:
        if not isinstance(slot, dict):
            raise ValueError('Every puzzle slot must be an object.')
        slot_id = _required_text(slot, 'id', 'puzzle slot')
        position = _puzzle_position(
            slot.get('row'),
            slot.get('column'),
            rows,
            columns,
            label='slot',
        )
        slot_ids.append(slot_id)
        slot_positions[slot_id] = position
    _require_unique(slot_ids, 'Puzzle slot IDs')
    if set(slot_positions.values()) != expected_positions:
        raise ValueError('Puzzle slots must fill every grid position exactly once.')

    pieces = config.get('pieces')
    if not isinstance(pieces, list) or len(pieces) != piece_count:
        raise ValueError('Puzzle pieces must cover every artwork crop exactly once.')
    piece_ids = []
    piece_positions = {}
    for piece in pieces:
        if not isinstance(piece, dict):
            raise ValueError('Every puzzle piece must be an object.')
        piece_id = _required_text(piece, 'id', 'puzzle piece')
        _required_text(piece, 'label', 'puzzle piece')
        position = _puzzle_position(
            piece.get('source_row'),
            piece.get('source_column'),
            rows,
            columns,
            label='piece source',
        )
        piece_ids.append(piece_id)
        piece_positions[piece_id] = position
    _require_unique(piece_ids, 'Puzzle piece IDs')
    if set(piece_positions.values()) != expected_positions:
        raise ValueError('Puzzle pieces must cover every artwork crop exactly once.')

    solution = config.get('solution')
    if not isinstance(solution, dict):
        raise ValueError('Puzzle levels need a private solution object.')
    if set(solution) != set(piece_ids) or set(solution.values()) != set(slot_ids):
        raise ValueError('Puzzle solution must use every piece and slot exactly once.')
    for piece_id, slot_id in solution.items():
        if piece_positions[piece_id] != slot_positions[slot_id]:
            raise ValueError(
                'Each puzzle solution entry must match its artwork crop position.'
            )

    preview_seconds = config.get('preview_seconds', 5)
    if not _is_int(preview_seconds) or not 1 <= preview_seconds <= 30:
        raise ValueError('Puzzle preview_seconds must be between one and 30.')
    target_moves = config.get('target_moves')
    if (
        not _is_int(target_moves)
        or not piece_count <= target_moves <= 10_000
    ):
        raise ValueError(
            'Puzzle target_moves must be at least the number of pieces and at most 10000.'
        )
    target_seconds = config.get('target_seconds')
    if not _is_int(target_seconds) or not 1 <= target_seconds <= 3_600:
        raise ValueError('Puzzle target_seconds must be between one and 3600.')


def _puzzle_position(row, column, rows, columns, *, label):
    if not _is_int(row) or not _is_int(column):
        raise ValueError(f'Every puzzle {label} needs integer row and column values.')
    position = row, column
    if not (0 <= row < rows and 0 <= column < columns):
        raise ValueError(f'Every puzzle {label} must stay inside the grid.')
    return position


def _item_ids(items, prefix):
    if not isinstance(items, list) or not items:
        raise ValueError(f'{prefix} levels need at least one item.')
    ids = []
    for item in items:
        if not isinstance(item, dict):
            raise ValueError(f'Every {prefix.lower()} item must be an object.')
        ids.append(_required_text(item, 'id', f'{prefix.lower()} item'))
        _required_text(item, 'label', f'{prefix.lower()} item label')
    _require_unique(ids, f'{prefix} item IDs')
    return ids


def _required_text(value, key, label):
    text = value.get(key)
    if not isinstance(text, str) or not text.strip():
        raise ValueError(f'Every {label} needs a non-empty {key}.')
    return text


def _require_unique(values, label):
    if len(values) != len(set(values)):
        raise ValueError(f'{label} must be unique.')


def _coordinate(value, rows, columns):
    if not isinstance(value, list) or len(value) != 2 or not all(_is_int(part) for part in value):
        raise ValueError('Grid coordinates must be [row, column] integer pairs.')
    coordinate = value[0], value[1]
    if not (0 <= coordinate[0] < rows and 0 <= coordinate[1] < columns):
        raise ValueError('Grid coordinates must stay inside the grid.')
    return coordinate


def _has_route(rows, columns, start, end, walls):
    queue = deque([start])
    seen = {start}
    while queue:
        row, column = queue.popleft()
        if (row, column) == end:
            return True
        for neighbor in (
            (row - 1, column),
            (row + 1, column),
            (row, column - 1),
            (row, column + 1),
        ):
            if (
                0 <= neighbor[0] < rows
                and 0 <= neighbor[1] < columns
                and neighbor not in walls
                and neighbor not in seen
            ):
                seen.add(neighbor)
                queue.append(neighbor)
    return False


def _is_int(value):
    return isinstance(value, int) and not isinstance(value, bool)


def _is_number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and isfinite(value)
