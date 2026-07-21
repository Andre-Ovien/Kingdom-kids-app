from collections import Counter, deque
from math import isfinite

from django.core.exceptions import ValidationError


GAME_TYPES = {'quiz', 'memory', 'ordering', 'matching', 'maze', 'path', 'aim'}


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
        elif game_type == 'aim':
            _validate_aim(config)
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
    item_ids = _item_ids(config.get('items'), 'Ordering')
    sequence = config.get('answer_sequence')
    if not isinstance(sequence, list) or sequence != list(dict.fromkeys(sequence)):
        raise ValueError('Ordering answer_sequence must contain unique item IDs.')
    if set(sequence) != set(item_ids) or len(sequence) != len(item_ids):
        raise ValueError('Ordering answer_sequence must use every item exactly once.')


def _validate_matching(config):
    left_ids = _item_ids(config.get('left_items'), 'Matching left')
    right_ids = _item_ids(config.get('right_items'), 'Matching right')
    pairs = config.get('expected_pairs')
    if not isinstance(pairs, dict):
        raise ValueError('Matching levels need an expected_pairs object.')
    if set(pairs) != set(left_ids) or set(pairs.values()) != set(right_ids):
        raise ValueError('Matching pairs must use every left and right item exactly once.')
    if len(left_ids) != len(right_ids):
        raise ValueError('Matching levels need the same number of items on both sides.')


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
