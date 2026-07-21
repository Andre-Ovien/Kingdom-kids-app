from __future__ import annotations

import math
from collections import deque
from dataclasses import dataclass
from typing import Any

from .models import Game, GameLevel


class GameResultError(ValueError):
    """Raised when a device submits a malformed or impossible game result."""


@dataclass(frozen=True)
class Evaluation:
    completed: bool
    score: int
    stars: int
    feedback: str
    details: dict[str, Any]


def public_level_config(level: GameLevel) -> dict[str, Any]:
    """Return only the fields needed to render a game, never private answers."""

    config = level.config
    game_type = level.game.game_type
    if game_type == Game.Type.QUIZ:
        return {
            'questions': [
                {
                    'id': question['id'],
                    'prompt': question['prompt'],
                    'options': [
                        {'id': option['id'], 'text': option['text']}
                        for option in question['options']
                    ],
                }
                for question in config.get('questions', [])
            ],
        }
    if game_type == Game.Type.ORDERING:
        return {'items': _public_items(config.get('items', []))}
    if game_type == Game.Type.MATCHING:
        return {
            'left_items': _public_items(config.get('left_items', [])),
            'right_items': _public_items(config.get('right_items', [])),
        }
    if game_type == Game.Type.MEMORY:
        return {
            'cards': [
                {
                    'id': card['id'],
                    'label': card['label'],
                    'asset_key': card.get('asset_key', ''),
                    # A local card game must be able to decide when two opened
                    # cards match. The backend still recomputes completion,
                    # efficiency, score, and stars from the submitted cards.
                    'match_key': card['match_key'],
                }
                for card in config.get('cards', [])
            ],
            'preview_seconds': int(config.get('preview_seconds', 3)),
        }
    if game_type in {Game.Type.MAZE, Game.Type.PATH}:
        grid = config.get('grid', {})
        return {
            'grid': {
                'rows': grid.get('rows'),
                'columns': grid.get('columns'),
                'start': grid.get('start'),
                'end': grid.get('end'),
                'walls': grid.get('walls', []),
                'decorations': grid.get('decorations', []),
            },
        }
    if game_type == Game.Type.AIM:
        return {
            'canvas': config.get('canvas', {}),
            'target': config.get('target', {}),
            'max_shots': config.get('max_shots', 3),
            'obstacles': config.get('obstacles', []),
        }
    raise GameResultError('This game type is not supported.')


def _public_items(items: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [
        {
            'id': item['id'],
            'label': item['label'],
            'asset_key': item.get('asset_key', ''),
        }
        for item in items
    ]


def evaluate_level(level: GameLevel, result: dict[str, Any]) -> Evaluation:
    if not isinstance(result, dict):
        raise GameResultError('result must be an object.')

    evaluators = {
        Game.Type.QUIZ: _evaluate_quiz,
        Game.Type.ORDERING: _evaluate_ordering,
        Game.Type.MATCHING: _evaluate_matching,
        Game.Type.MEMORY: _evaluate_memory,
        Game.Type.MAZE: _evaluate_grid_path,
        Game.Type.PATH: _evaluate_grid_path,
        Game.Type.AIM: _evaluate_aim,
    }
    try:
        evaluator = evaluators[level.game.game_type]
    except KeyError as exc:
        raise GameResultError('This game type is not supported.') from exc

    completed, score, feedback, details = evaluator(level, result)
    bounded_score = max(0, min(level.max_score, int(round(score))))
    thresholds = _star_thresholds(level)
    stars = sum(bounded_score >= threshold for threshold in thresholds) if completed else 0
    return Evaluation(
        completed=completed,
        score=bounded_score,
        stars=stars,
        feedback=feedback,
        details=details,
    )


def _star_thresholds(level: GameLevel) -> list[int]:
    raw = level.star_thresholds or [60, 80, 95]
    if not isinstance(raw, list) or len(raw) != 3:
        raise GameResultError('This level has invalid star thresholds.')
    thresholds = []
    for value in raw:
        if not _is_number(value):
            raise GameResultError('This level has invalid star thresholds.')
        thresholds.append(int(value))
    if thresholds != sorted(thresholds):
        raise GameResultError('This level has invalid star thresholds.')
    return thresholds


def _evaluate_quiz(level, result):
    questions = level.config.get('questions', [])
    answers = result.get('answers')
    if not isinstance(answers, list):
        raise GameResultError('answers must be a list.')

    question_map = {question['id']: question for question in questions}
    submitted: dict[str, str] = {}
    for answer in answers:
        if not isinstance(answer, dict):
            raise GameResultError('Each answer must be an object.')
        question_id = answer.get('question_id')
        option_id = answer.get('option_id')
        if question_id not in question_map:
            raise GameResultError('An answer references an unknown question.')
        if question_id in submitted:
            raise GameResultError('A question can only be answered once.')
        valid_options = {option['id'] for option in question_map[question_id]['options']}
        if option_id not in valid_options:
            raise GameResultError('An answer references an unknown option.')
        submitted[question_id] = option_id

    correct = sum(
        submitted.get(question['id']) == question['correct_option_id']
        for question in questions
    )
    total = len(questions)
    if not total:
        raise GameResultError('This level has no questions.')
    score = round(level.max_score * correct / total)
    pass_score = int(level.config.get('pass_score', 60))
    completed = len(submitted) == total and score >= pass_score
    if completed and correct == total:
        feedback = 'Amazing! Every answer sparkles!'
    elif completed:
        feedback = 'Great thinking! You completed the challenge!'
    elif len(submitted) < total:
        feedback = 'Answer every question to finish this level.'
    else:
        feedback = 'So close! Try again and look for the story clues.'
    return completed, score, feedback, {
        'correct_answers': correct,
        'question_count': total,
        'answered_count': len(submitted),
    }


def _evaluate_ordering(level, result):
    sequence = result.get('sequence')
    if not isinstance(sequence, list) or any(not isinstance(item, str) for item in sequence):
        raise GameResultError('sequence must be a list of item IDs.')
    expected = level.config.get('answer_sequence', [])
    known = set(expected)
    if len(sequence) != len(set(sequence)):
        raise GameResultError('An item cannot appear more than once.')
    if any(item not in known for item in sequence):
        raise GameResultError('sequence contains an unknown item.')
    correct_positions = sum(
        index < len(expected) and item == expected[index]
        for index, item in enumerate(sequence)
    )
    total = len(expected)
    if not total:
        raise GameResultError('This level has no ordering answer.')
    score = round(level.max_score * correct_positions / total)
    completed = sequence == expected
    feedback = (
        'Perfect order! The whole story lines up!'
        if completed
        else 'Good try! Move the story moments into the right order.'
    )
    return completed, score, feedback, {
        'correct_positions': correct_positions,
        'item_count': total,
    }


def _evaluate_matching(level, result):
    pairs = result.get('pairs')
    if not isinstance(pairs, list):
        raise GameResultError('pairs must be a list.')
    expected = level.config.get('expected_pairs', {})
    left_ids = set(expected)
    right_ids = set(expected.values())
    submitted: dict[str, str] = {}
    used_right: set[str] = set()
    for pair in pairs:
        if not isinstance(pair, dict):
            raise GameResultError('Each pair must be an object.')
        left_id = pair.get('left_id')
        right_id = pair.get('right_id')
        if left_id not in left_ids or right_id not in right_ids:
            raise GameResultError('A pair references an unknown item.')
        if left_id in submitted or right_id in used_right:
            raise GameResultError('Each matching item can only be used once.')
        submitted[left_id] = right_id
        used_right.add(right_id)
    total = len(expected)
    if not total:
        raise GameResultError('This level has no matching answer.')
    correct = sum(expected[left_id] == right_id for left_id, right_id in submitted.items())
    score = round(level.max_score * correct / total)
    completed = len(submitted) == total and correct == total
    feedback = (
        'Every pair found its perfect partner!'
        if completed
        else 'Keep looking—each picture has one special match.'
    )
    return completed, score, feedback, {
        'correct_pairs': correct,
        'pair_count': total,
    }


def _evaluate_memory(level, result):
    pairs = result.get('matched_pairs')
    moves = result.get('moves')
    elapsed_seconds = result.get('elapsed_seconds')
    if not isinstance(pairs, list):
        raise GameResultError('matched_pairs must be a list.')
    if not _is_int(moves) or moves < 0 or moves > 10_000:
        raise GameResultError('moves must be an integer between 0 and 10000.')
    if not _is_int(elapsed_seconds) or elapsed_seconds < 0 or elapsed_seconds > 3_600:
        raise GameResultError('elapsed_seconds must be an integer between 0 and 3600.')

    cards = {card['id']: card for card in level.config.get('cards', [])}
    used_cards: set[str] = set()
    matched_keys: set[str] = set()
    for pair in pairs:
        if not isinstance(pair, list) or len(pair) != 2:
            raise GameResultError('Each memory pair must contain exactly two card IDs.')
        first_id, second_id = pair
        if first_id not in cards or second_id not in cards:
            raise GameResultError('A memory pair references an unknown card.')
        if first_id == second_id or first_id in used_cards or second_id in used_cards:
            raise GameResultError('Each memory card can only be matched once.')
        first_key = cards[first_id]['match_key']
        second_key = cards[second_id]['match_key']
        if first_key != second_key:
            raise GameResultError('matched_pairs contains cards that do not match.')
        if first_key in matched_keys:
            raise GameResultError('A memory match can only be completed once.')
        used_cards.update((first_id, second_id))
        matched_keys.add(first_key)

    expected_keys = {card['match_key'] for card in cards.values()}
    pair_count = len(expected_keys)
    if not pair_count or len(cards) != pair_count * 2:
        raise GameResultError('This memory level has an invalid deck.')
    if moves < len(pairs):
        raise GameResultError('moves cannot be lower than the number of matched pairs.')

    completed = matched_keys == expected_keys
    base_score = level.max_score * 0.7 * len(matched_keys) / pair_count
    if completed:
        extra_moves = max(0, moves - pair_count)
        move_bonus = max(0, 20 - extra_moves * 2)
        target_seconds = int(level.config.get('target_seconds', 45))
        time_bonus = max(0, 10 - max(0, elapsed_seconds - target_seconds) // 10)
        score = round(base_score + level.max_score * (move_bonus + time_bonus) / 100)
        feedback = 'Brilliant memory! Daniel would be proud!'
    else:
        score = round(base_score)
        feedback = 'Nice matches! Turn over the rest to finish.'
    return completed, score, feedback, {
        'matched_pairs': len(matched_keys),
        'pair_count': pair_count,
        'moves': moves,
        'elapsed_seconds': elapsed_seconds,
    }


def _evaluate_grid_path(level, result):
    path = result.get('path')
    if not isinstance(path, list) or not path:
        raise GameResultError('path must be a non-empty list of coordinates.')
    grid = level.config.get('grid', {})
    rows = grid.get('rows')
    columns = grid.get('columns')
    if not _is_int(rows) or not _is_int(columns) or rows < 2 or columns < 2:
        raise GameResultError('This level has an invalid grid.')
    if len(path) > rows * columns * 4:
        raise GameResultError('path is longer than this grid allows.')
    coordinates = [_coordinate(value) for value in path]
    start = _coordinate(grid.get('start'))
    end = _coordinate(grid.get('end'))
    walls = {_coordinate(value) for value in grid.get('walls', [])}
    if coordinates[0] != start:
        raise GameResultError('path must begin at the configured start.')
    for row, column in coordinates:
        if row < 0 or row >= rows or column < 0 or column >= columns:
            raise GameResultError('path contains a coordinate outside the grid.')
        if (row, column) in walls:
            raise GameResultError('path cannot pass through a wall.')
    for previous, current in zip(coordinates, coordinates[1:]):
        if abs(previous[0] - current[0]) + abs(previous[1] - current[1]) != 1:
            raise GameResultError('Every path step must move one square up, down, left, or right.')

    optimal_steps = _shortest_path_steps(rows, columns, start, end, walls)
    if optimal_steps is None:
        raise GameResultError('This level does not have a valid route.')
    completed = coordinates[-1] == end
    if completed:
        submitted_steps = len(coordinates) - 1
        extra_steps = max(0, submitted_steps - optimal_steps)
        score = max(round(level.max_score * 0.6), level.max_score - extra_steps * 5)
        feedback = 'You found the way! What an adventure!'
    else:
        final_distance = abs(coordinates[-1][0] - end[0]) + abs(coordinates[-1][1] - end[1])
        start_distance = max(1, abs(start[0] - end[0]) + abs(start[1] - end[1]))
        score = round(level.max_score * 0.5 * max(0, 1 - final_distance / start_distance))
        feedback = 'You are on the trail—keep going to the glowing finish!'
    return completed, score, feedback, {
        'steps': len(coordinates) - 1,
        'optimal_steps': optimal_steps,
    }


def _evaluate_aim(level, result):
    shots = result.get('shots')
    if not isinstance(shots, list) or not shots:
        raise GameResultError('shots must be a non-empty list.')
    config = level.config
    canvas = config.get('canvas', {})
    target = config.get('target', {})
    width = canvas.get('width')
    height = canvas.get('height')
    target_x = target.get('x')
    target_y = target.get('y')
    radius = target.get('radius')
    max_shots = config.get('max_shots', 3)
    if not all(_is_number(value) for value in (width, height, target_x, target_y, radius)):
        raise GameResultError('This aim level has invalid geometry.')
    if width <= 0 or height <= 0 or radius <= 0 or not _is_int(max_shots) or max_shots < 1:
        raise GameResultError('This aim level has invalid geometry.')
    if len(shots) > max_shots:
        raise GameResultError(f'No more than {max_shots} shots are allowed.')

    distances: list[float] = []
    for shot in shots:
        if not isinstance(shot, dict) or not _is_number(shot.get('x')) or not _is_number(shot.get('y')):
            raise GameResultError('Each shot must contain numeric x and y coordinates.')
        x = float(shot['x'])
        y = float(shot['y'])
        if not 0 <= x <= width or not 0 <= y <= height:
            raise GameResultError('A shot landed outside the game canvas.')
        distances.append(math.hypot(x - target_x, y - target_y))

    best_distance = min(distances)
    completed = best_distance <= radius
    if completed:
        score = round(level.max_score * (1 - 0.35 * best_distance / radius))
        feedback = 'Bullseye! Small stone, giant courage!'
    else:
        closeness = max(0, 1 - (best_distance - radius) / (radius * 3))
        score = round(level.max_score * 0.49 * closeness)
        feedback = 'Almost! Breathe, aim, and try once more.'
    return completed, score, feedback, {
        'shots_used': len(shots),
        'best_distance': round(best_distance, 2),
        'hit': completed,
    }


def _coordinate(value: Any) -> tuple[int, int]:
    if (
        not isinstance(value, list)
        or len(value) != 2
        or not all(_is_int(part) for part in value)
    ):
        raise GameResultError('Every coordinate must be a [row, column] integer pair.')
    return value[0], value[1]


def _shortest_path_steps(rows, columns, start, end, walls):
    queue = deque([(start, 0)])
    seen = {start}
    while queue:
        current, distance = queue.popleft()
        if current == end:
            return distance
        row, column = current
        for neighbor in (
            (row - 1, column),
            (row + 1, column),
            (row, column - 1),
            (row, column + 1),
        ):
            n_row, n_column = neighbor
            if (
                0 <= n_row < rows
                and 0 <= n_column < columns
                and neighbor not in walls
                and neighbor not in seen
            ):
                seen.add(neighbor)
                queue.append((neighbor, distance + 1))
    return None


def _is_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _is_number(value: Any) -> bool:
    return (
        isinstance(value, (int, float))
        and not isinstance(value, bool)
        and math.isfinite(value)
    )
