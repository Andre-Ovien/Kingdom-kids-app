from __future__ import annotations

import math
from collections import deque
from dataclasses import dataclass
from typing import Any

from .models import Game, GameLevel
from .ark_garden import evaluate_ark_garden, public_ark_garden_config
from .ark_traffic import evaluate_ark_traffic, public_ark_traffic_config
from .creation_world import evaluate_creation_world, public_creation_world_config
from .wise_builders import evaluate_wise_builders, public_wise_builders_config
from .matching_studio import (evaluate_matching_studio, public_coat_studio_config,
                              public_harvest_chain_config)
from .matching_collection import SCENES, evaluate_scene_matching, public_scene_matching_config


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
        if config.get('mode') == 'living_world':
            return public_creation_world_config(config)
        if config.get('mode') == 'wise_builders':
            return public_wise_builders_config(config)
        return {'items': _public_items(config.get('items', []))}
    if game_type == Game.Type.MATCHING:
        if config.get('mode') in SCENES:
            return public_scene_matching_config(config)
        if config.get('mode') == 'coat_studio':
            return public_coat_studio_config(config)
        if config.get('mode') == 'harvest_chain':
            return public_harvest_chain_config(config)
        if config.get('mode') == 'ark_garden':
            return public_ark_garden_config(config)
        if config.get('mode') == 'ark_traffic':
            return public_ark_traffic_config(config)
        public = {
            'left_items': _public_items(config.get('left_items', [])),
            'right_items': _public_items(config.get('right_items', [])),
        }
        if config.get('mode') == 'ark_boarding':
            public.update({
                'mode': 'ark_boarding',
                'time_limit_seconds': config['time_limit_seconds'],
                'goal_pairs': config['goal_pairs'],
            })
        return public
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
        public = {
            'grid': {
                'rows': grid.get('rows'),
                'columns': grid.get('columns'),
                'start': grid.get('start'),
                'end': grid.get('end'),
                'walls': grid.get('walls', []),
                'decorations': grid.get('decorations', []),
            },
        }
        if game_type == Game.Type.MAZE and isinstance(config.get('sailing'), dict):
            sailing = config['sailing']
            public['sailing'] = {
                key: sailing.get(key)
                for key in (
                    'duration_seconds', 'distance_m', 'ship_radius',
                    'collision_window', 'max_hits', 'steer_speed',
                )
            }
            public['sailing']['obstacles'] = [
                {key: obstacle.get(key) for key in ('id', 'progress', 'x', 'radius')}
                for obstacle in sailing.get('obstacles', [])
            ]
        if game_type == Game.Type.PATH and isinstance(config.get('crossing'), dict):
            crossing = config['crossing']
            public['crossing'] = {
                'time_limit_seconds': crossing.get('time_limit_seconds'),
                'travellers': [
                    {key: traveller.get(key) for key in ('id', 'label')}
                    for traveller in crossing.get('travellers', [])
                ],
                'drop_zone': {
                    key: crossing.get('drop_zone', {}).get(key)
                    for key in ('left', 'top', 'right', 'bottom')
                },
            }
            if 'polygon' in crossing.get('drop_zone', {}):
                public['crossing']['drop_zone']['polygon'] = [
                    list(point) for point in crossing['drop_zone']['polygon']
                ]
        return public
    if game_type == Game.Type.AIM:
        return {
            'canvas': config.get('canvas', {}),
            'target': config.get('target', {}),
            'max_shots': config.get('max_shots', 3),
            'obstacles': config.get('obstacles', []),
        }
    if game_type == Game.Type.PUZZLE:
        artwork = config.get('artwork', {})
        grid = config.get('grid', {})
        return {
            'artwork': {
                'asset_key': artwork.get('asset_key', ''),
                'title': artwork.get('title', ''),
                'alt_text': artwork.get('alt_text', ''),
                'aspect_ratio': artwork.get('aspect_ratio', 1),
            },
            'grid': {
                'rows': grid.get('rows'),
                'columns': grid.get('columns'),
            },
            'pieces': [
                {
                    'id': piece['id'],
                    'label': piece['label'],
                    # The device crops each piece from the shared high-resolution
                    # artwork. The explicit piece-to-slot answer stays private.
                    'source_row': piece['source_row'],
                    'source_column': piece['source_column'],
                }
                for piece in config.get('pieces', [])
            ],
            'slots': [
                {
                    'id': slot['id'],
                    'row': slot['row'],
                    'column': slot['column'],
                }
                for slot in config.get('slots', [])
            ],
            'preview_seconds': int(config.get('preview_seconds', 5)),
            'target_moves': config.get('target_moves'),
            'target_seconds': config.get('target_seconds'),
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
        Game.Type.MAZE: _evaluate_maze,
        Game.Type.PATH: _evaluate_path,
        Game.Type.AIM: _evaluate_aim,
        Game.Type.PUZZLE: _evaluate_puzzle,
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


def _require_only_fields(result: dict[str, Any], allowed_fields: set[str]) -> None:
    unknown_fields = set(result) - allowed_fields
    if unknown_fields:
        allowed = ', '.join(sorted(allowed_fields))
        raise GameResultError(f'Result may only contain: {allowed}.')


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
    _require_only_fields(result, {'answers'})
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
        if not isinstance(question_id, str) or not isinstance(option_id, str):
            raise GameResultError('Quiz question and option IDs must be text.')
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
    if level.config.get('mode') == 'living_world':
        return evaluate_creation_world(level, result)
    if level.config.get('mode') == 'wise_builders':
        return evaluate_wise_builders(level, result)
    _require_only_fields(result, {'sequence'})
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
    if level.config.get('mode') in SCENES:
        return evaluate_scene_matching(level, result)
    if level.config.get('mode') in {'coat_studio', 'harvest_chain'}:
        return evaluate_matching_studio(level, result)
    if level.config.get('mode') == 'ark_garden':
        return evaluate_ark_garden(level, result)
    if level.config.get('mode') == 'ark_traffic':
        return evaluate_ark_traffic(level, result)
    boarding = level.config.get('mode') == 'ark_boarding'
    _require_only_fields(result, {'pairs', 'elapsed_seconds'} if boarding else {'pairs'})
    if boarding:
        elapsed = result.get('elapsed_seconds')
        time_limit = level.config.get('time_limit_seconds')
        goal = level.config.get('goal_pairs')
        if not _is_int(time_limit) or not 10 <= time_limit <= 180:
            raise GameResultError('This ark round has an invalid time limit.')
        if not _is_int(elapsed) or not 0 <= elapsed <= time_limit:
            raise GameResultError(f'elapsed_seconds must be an integer between 0 and {time_limit}.')
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
        if not isinstance(left_id, str) or not isinstance(right_id, str):
            raise GameResultError('Matching item IDs must be text.')
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
    details = {
        'correct_pairs': correct,
        'pair_count': total,
    }
    if boarding:
        if not _is_int(goal) or not 1 <= goal <= total:
            raise GameResultError('This ark round has an invalid boarding goal.')
        completed = correct >= goal
        if correct == total:
            feedback = 'Everyone is aboard! What an amazing animal rescue!'
        elif completed:
            feedback = f'{correct} animal pairs are safe aboard. Wonderful teamwork!'
        else:
            feedback = f'{correct} pairs made it aboard. Try another round to bring {goal} pairs home!'
        details.update({'animals_boarded': correct * 2, 'goal_pairs': goal, 'elapsed_seconds': elapsed})
    else:
        feedback = (
            'Every pair found its perfect partner!'
            if completed
            else 'Keep looking—each picture has one special match.'
        )
    return completed, score, feedback, details


def _evaluate_memory(level, result):
    _require_only_fields(result, {'matched_pairs', 'moves', 'elapsed_seconds'})
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


def _evaluate_maze(level, result):
    if 'voyage' in result:
        return _evaluate_sailing(level, result)
    return _evaluate_grid_path(level, result)


def _evaluate_path(level, result):
    if 'crossing' in result:
        return _evaluate_crossing(level, result)
    return _evaluate_grid_path(level, result)


def _evaluate_crossing(level, result):
    _require_only_fields(result, {'crossing'})
    crossing_result = result.get('crossing')
    if not isinstance(crossing_result, dict):
        raise GameResultError('crossing must be an object.')
    _require_only_fields(crossing_result, {'elapsed_ms', 'placements'})
    crossing = level.config.get('crossing')
    from .validators import crossing_drop_contains, validate_crossing_config

    try:
        validate_crossing_config(crossing)
    except (KeyError, TypeError, ValueError) as exc:
        raise GameResultError('This level has invalid crossing rules.') from exc
    elapsed_ms = crossing_result.get('elapsed_ms')
    limit_ms = crossing['time_limit_seconds'] * 1000
    if not _is_int(elapsed_ms) or not 0 <= elapsed_ms <= limit_ms:
        raise GameResultError('Crossing elapsed_ms must fit the active placement timer.')
    placements = crossing_result.get('placements')
    travellers = {traveller['id'] for traveller in crossing['travellers']}
    if not isinstance(placements, list) or len(placements) > len(travellers):
        raise GameResultError('placements must list at most one drop per traveller.')
    zone = crossing['drop_zone']
    placed_ids = []
    previous_release = 0
    for placement in placements:
        if not isinstance(placement, dict):
            raise GameResultError('Each traveller placement must be an object.')
        _require_only_fields(placement, {'traveller_id', 'x', 'y', 'released_at_ms'})
        traveller_id = placement.get('traveller_id')
        if not isinstance(traveller_id, str) or traveller_id not in travellers:
            raise GameResultError('A placement references an unknown traveller.')
        if traveller_id in placed_ids:
            raise GameResultError('Each traveller may be placed only once.')
        x, y = placement.get('x'), placement.get('y')
        if not _is_number(x) or not _is_number(y):
            raise GameResultError('Traveller drop coordinates must be finite numbers.')
        if not crossing_drop_contains(zone, x, y):
            raise GameResultError('Every traveller must be released onto the dry path.')
        released_at_ms = placement.get('released_at_ms')
        if (
            not _is_int(released_at_ms)
            or not previous_release <= released_at_ms <= elapsed_ms
        ):
            raise GameResultError('Traveller release times must be ordered within the placement timer.')
        previous_release = released_at_ms
        placed_ids.append(traveller_id)
    completed = len(placed_ids) == len(travellers)
    if completed:
        fraction = elapsed_ms / limit_ms
        score_fraction = 1.0 if fraction <= 0.6 else (0.85 if fraction <= 0.85 else 0.65)
        score = round(level.max_score * score_fraction)
        feedback = 'Everyone reached the dry path! What a wonderful crossing!'
    else:
        score = round(level.max_score * 0.5 * len(placed_ids) / len(travellers))
        feedback = 'Some travellers still need help. Try again and bring everyone to the dry path!'
    return completed, score, feedback, {
        'elapsed_ms': elapsed_ms,
        'traveller_count': len(travellers),
        'rescued_count': len(placed_ids),
        'placed_traveller_ids': placed_ids,
    }


def _evaluate_sailing(level, result):
    _require_only_fields(result, {'voyage'})
    voyage = result.get('voyage')
    if not isinstance(voyage, dict):
        raise GameResultError('voyage must be an object.')
    _require_only_fields(voyage, {'duration_ms', 'samples'})
    sailing = level.config.get('sailing')
    from .validators import validate_sailing_config

    try:
        validate_sailing_config(sailing)
    except (KeyError, TypeError, ValueError) as exc:
        raise GameResultError('This level has invalid sailing rules.') from exc
    duration_ms = sailing['duration_seconds'] * 1000
    if not _is_int(voyage.get('duration_ms')) or voyage['duration_ms'] != duration_ms:
        raise GameResultError('The voyage must record the full 60 seconds.')
    samples = voyage.get('samples')
    if not isinstance(samples, list) or not 2 <= len(samples) <= duration_ms + 1:
        raise GameResultError('samples must be a bounded list of [time_ms, x] pairs.')
    points = []
    for sample in samples:
        if (
            not isinstance(sample, list)
            or len(sample) != 2
            or not _is_int(sample[0])
            or not _is_number(sample[1])
            or not 0 <= sample[0] <= duration_ms
            or not -1 <= sample[1] <= 1
        ):
            raise GameResultError('Each sample needs integer milliseconds and finite x from -1 to 1.')
        points.append((sample[0], sample[1]))
    if points[0] != (0, 0) or points[-1][0] != duration_ms:
        raise GameResultError('The voyage must start at [0, 0] and finish at 60000 milliseconds.')
    for previous, current in zip(points, points[1:]):
        elapsed_ms = current[0] - previous[0]
        if not 1 <= elapsed_ms <= 250:
            raise GameResultError('Sample times must increase with no gap over 250 milliseconds.')
        # Scale the rounding allowance with time, so submitting very dense
        # samples cannot turn per-sample tolerance into additional speed.
        if abs(current[1] - previous[1]) > (sailing['steer_speed'] + 0.02) * elapsed_ms / 1000:
            raise GameResultError('The boat cannot move faster than its steering speed.')
    hit_ids = []
    for obstacle in sailing['obstacles']:
        if any(
            abs(time_ms / duration_ms - obstacle['progress']) <= sailing['collision_window']
            and abs(x - obstacle['x']) < obstacle['radius'] + sailing['ship_radius']
            for time_ms, x in points
        ):
            hit_ids.append(obstacle['id'])
    hit_count = len(hit_ids)
    completed = hit_count < sailing['max_hits']
    score = round(level.max_score * ({0: 1.0, 1: 0.85, 2: 0.65}.get(hit_count, 0.35)))
    feedback = (
        'You made it to the calm shore! Beautiful sailing!'
        if completed
        else 'The storm was strong! Try again and steer around the rocks.'
    )
    return completed, score, feedback, {
        'duration_ms': duration_ms,
        'distance_m': sailing['distance_m'],
        'hit_count': hit_count,
        'hit_obstacle_ids': hit_ids,
        'sample_count': len(points),
    }


def _evaluate_grid_path(level, result):
    _require_only_fields(result, {'path'})
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
    _require_only_fields(result, {'shots'})
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


def _evaluate_puzzle(level, result):
    _require_only_fields(result, {'placements', 'moves', 'elapsed_seconds'})

    placements = result.get('placements')
    moves = result.get('moves')
    elapsed_seconds = result.get('elapsed_seconds')
    if not isinstance(placements, list):
        raise GameResultError('placements must be a list.')
    if not _is_int(moves) or moves < 0 or moves > 10_000:
        raise GameResultError('moves must be an integer between 0 and 10000.')
    if not _is_int(elapsed_seconds) or elapsed_seconds < 0 or elapsed_seconds > 3_600:
        raise GameResultError('elapsed_seconds must be an integer between 0 and 3600.')

    solution = level.config.get('solution', {})
    if (
        not isinstance(solution, dict)
        or any(not isinstance(piece_id, str) for piece_id in solution)
        or any(not isinstance(slot_id, str) for slot_id in solution.values())
    ):
        raise GameResultError('This puzzle level has an invalid solution.')
    piece_ids = set(solution)
    slot_ids = set(solution.values())
    if not piece_ids or len(piece_ids) != len(slot_ids):
        raise GameResultError('This puzzle level has an invalid solution.')
    if len(placements) > len(piece_ids):
        raise GameResultError('placements contains more pieces than this puzzle.')

    submitted: dict[str, str] = {}
    used_slots: set[str] = set()
    for placement in placements:
        if not isinstance(placement, dict):
            raise GameResultError('Each puzzle placement must be an object.')
        if set(placement) != {'piece_id', 'slot_id'}:
            raise GameResultError(
                'Each puzzle placement needs only piece_id and slot_id.'
            )
        piece_id = placement.get('piece_id')
        slot_id = placement.get('slot_id')
        if not isinstance(piece_id, str) or not isinstance(slot_id, str):
            raise GameResultError('Puzzle piece and slot IDs must be strings.')
        if piece_id not in piece_ids or slot_id not in slot_ids:
            raise GameResultError(
                'A puzzle placement references an unknown piece or slot.'
            )
        if piece_id in submitted:
            raise GameResultError('Each puzzle piece can only be placed once.')
        if slot_id in used_slots:
            raise GameResultError('Each puzzle slot can only hold one piece.')
        submitted[piece_id] = slot_id
        used_slots.add(slot_id)

    if moves < len(placements):
        raise GameResultError(
            'moves cannot be lower than the number of placed puzzle pieces.'
        )

    piece_count = len(solution)
    correct = sum(
        solution[piece_id] == slot_id
        for piece_id, slot_id in submitted.items()
    )
    completed = len(submitted) == piece_count and correct == piece_count
    score = level.max_score * 0.7 * correct / piece_count
    target_moves = level.config.get('target_moves')
    target_seconds = level.config.get('target_seconds')
    if not _is_int(target_moves) or not _is_int(target_seconds):
        raise GameResultError('This puzzle level has invalid scoring targets.')

    if completed:
        extra_moves = max(0, moves - target_moves)
        move_bonus = max(0, 20 - extra_moves * 2)
        overtime = max(0, elapsed_seconds - target_seconds)
        time_bonus = max(0, 10 - math.ceil(overtime / 10))
        score += level.max_score * (move_bonus + time_bonus) / 100
        feedback = (
            'Picture perfect! You rebuilt every sparkling piece!'
            if score >= level.max_score
            else 'Puzzle complete! Every piece found its special place!'
        )
    else:
        extra_moves = max(0, moves - target_moves)
        overtime = max(0, elapsed_seconds - target_seconds)
        feedback = 'Great start! Keep looking for where every piece belongs.'

    return completed, score, feedback, {
        'correct_placements': correct,
        'placed_pieces': len(submitted),
        'piece_count': piece_count,
        'moves': moves,
        'elapsed_seconds': elapsed_seconds,
        'moves_over_target': extra_moves,
        'seconds_over_target': overtime,
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
