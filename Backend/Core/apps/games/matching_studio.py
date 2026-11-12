"""Replay rules for two tactile, portrait matching games.

Visual colour/pattern references and seeded grain boards are deliberately public.
The server still derives completion, score and XP from ordered input history.
No client score, collection count or board replacement is accepted.
"""

from copy import deepcopy

COAT_COLORS = ('coral', 'gold', 'teal', 'forest', 'sky', 'lilac')
COAT_PATTERNS = ('dots', 'stripes', 'zigzag')
COAT_PANELS = ('left_shoulder', 'right_shoulder', 'left_body', 'right_body',
               'left_hem', 'right_hem')
GRAINS = ('wheat', 'barley', 'oats')
UINT32_MASK = 0xFFFFFFFF
COAT_MAX_ACTIONS = 120


def _object(value, fields, label):
    if not isinstance(value, dict) or set(value) != set(fields):
        raise ValueError(f'{label} has missing or unknown fields.')


def _integer(value, low, high, label):
    if type(value) is not int or not low <= value <= high:
        raise ValueError(f'{label} must be an integer from {low} to {high}.')


def _text(value, label):
    if not isinstance(value, str) or not 1 <= len(value) <= 64:
        raise ValueError(f'{label} must be short text.')


def _round_ratio(numerator, denominator):
    """Round nonnegative rational halves upward, identical to Dart .round()."""
    return (2 * numerator + denominator) // (2 * denominator)


def validate_coat_studio_config(config):
    _object(config, {'mode', 'panels', 'swatches', 'scene', 'round_number'}, 'Coat config')
    if config['mode'] != 'coat_studio' or config['scene'] != 'joseph_studio':
        raise ValueError('Choose the Joseph coat studio scene.')
    _integer(config['round_number'], 1, 3, 'round_number')
    panels, swatches = config['panels'], config['swatches']
    for label, items in (('panels', panels), ('swatches', swatches)):
        if not isinstance(items, list) or len(items) != 6:
            raise ValueError(f'Coat {label} must have six pieces.')
        ids, attributes = [], []
        for item in items:
            _object(item, {'id', 'color', 'pattern'}, f'Coat {label} item')
            _text(item['id'], f'Coat {label} ID')
            if item['color'] not in COAT_COLORS or item['pattern'] not in COAT_PATTERNS:
                raise ValueError('Coat pieces need a supported colour and pattern.')
            ids.append(item['id'])
            attributes.append((item['color'], item['pattern']))
        if len(set(ids)) != 6 or len(set(attributes)) != 6:
            raise ValueError('Coat piece IDs and colour/pattern combinations must be unique.')
    if {panel['id'] for panel in panels} != set(COAT_PANELS):
        raise ValueError('Coat panels must use the six named garment sections.')
    if {(p['color'], p['pattern']) for p in panels} != {(s['color'], s['pattern']) for s in swatches}:
        raise ValueError('Every coat panel needs one matching fabric swatch.')


def public_coat_studio_config(config):
    validate_coat_studio_config(config)
    return deepcopy(config)


def replay_coat_studio(config, result):
    validate_coat_studio_config(config)
    _object(result, {'actions'}, 'Coat result')
    actions = result['actions']
    if not isinstance(actions, list) or len(actions) > COAT_MAX_ACTIONS:
        raise ValueError('Coat result permits at most 120 placement attempts.')
    panels = {panel['id']: panel for panel in config['panels']}
    swatches = {swatch['id']: swatch for swatch in config['swatches']}
    filled, mistakes = set(), 0
    for action in actions:
        _object(action, {'panel_id', 'swatch_id'}, 'Coat placement')
        panel_id, swatch_id = action['panel_id'], action['swatch_id']
        if not isinstance(panel_id, str) or panel_id not in panels:
            raise ValueError('A coat placement names an unknown panel.')
        if not isinstance(swatch_id, str) or swatch_id not in swatches:
            raise ValueError('A coat placement names an unknown swatch.')
        if panel_id in filled:
            raise ValueError('A stitched coat panel cannot be filled again.')
        panel, swatch = panels[panel_id], swatches[swatch_id]
        if (panel['color'], panel['pattern']) == (swatch['color'], swatch['pattern']):
            filled.add(panel_id)
        else:
            mistakes += 1
    completed = len(filled) == len(panels)
    score = (70 + _round_ratio(30 * len(panels), len(actions)) if completed
             else _round_ratio(50 * len(filled), len(panels)))
    return {'completed': completed, 'score': score, 'filled_panels': sorted(filled),
            'correct_placements': len(filled), 'panel_count': len(panels),
            'attempts': len(actions), 'mistakes': mistakes}


def build_coat_studio_config(round_number):
    _integer(round_number, 1, 3, 'round_number')
    patterns = (('dots', 'stripes', 'zigzag', 'dots', 'stripes', 'zigzag'),
                ('zigzag', 'dots', 'stripes', 'zigzag', 'dots', 'stripes'),
                ('stripes', 'zigzag', 'dots', 'stripes', 'zigzag', 'dots'))[round_number - 1]
    colors = (COAT_COLORS,
              ('coral', 'coral', 'teal', 'teal', 'gold', 'gold'),
              ('forest', 'forest', 'sky', 'sky', 'lilac', 'lilac'))[round_number - 1]
    panels = [{'id': panel_id, 'color': color, 'pattern': pattern}
              for panel_id, color, pattern in zip(COAT_PANELS, colors, patterns)]
    order = ((3, 0, 4, 1, 5, 2), (4, 2, 0, 5, 3, 1), (5, 3, 1, 4, 2, 0))[round_number - 1]
    config = {'mode': 'coat_studio', 'scene': 'joseph_studio', 'round_number': round_number,
              'panels': panels, 'swatches': [
                  {'id': f'fabric_{index + 1}', 'color': panels[source]['color'],
                   'pattern': panels[source]['pattern']} for index, source in enumerate(order)]}
    validate_coat_studio_config(config)
    return config


def example_coat_studio_result(config):
    return {'actions': [{'panel_id': panel['id'], 'swatch_id': next(
        swatch['id'] for swatch in config['swatches']
        if (swatch['color'], swatch['pattern']) == (panel['color'], panel['pattern']))}
        for panel in config['panels']]}


class XorShift32:
    def __init__(self, seed):
        _integer(seed, 1, UINT32_MASK, 'seed')
        self.state = seed

    def next(self):
        value = self.state
        value ^= (value << 13) & UINT32_MASK
        value ^= value >> 17
        value ^= (value << 5) & UINT32_MASK
        self.state = value & UINT32_MASK
        return self.state


def validate_harvest_chain_config(config):
    _object(config, {'mode', 'scene', 'round_number', 'seed', 'rows', 'columns',
                     'grain_types', 'goals', 'max_chains', 'min_chain'}, 'Harvest config')
    if config['mode'] != 'harvest_chain' or config['scene'] != 'ruth_field':
        raise ValueError('Choose the Ruth harvest field scene.')
    _integer(config['round_number'], 1, 3, 'round_number')
    _integer(config['seed'], 1, UINT32_MASK, 'seed')
    if type(config['rows']) is not int or type(config['columns']) is not int or (config['rows'], config['columns']) != (6, 5):
        raise ValueError('Harvest boards have six rows and five columns.')
    if config['grain_types'] != list(GRAINS):
        raise ValueError('Harvest uses wheat, barley and oats in that order.')
    _object(config['goals'], GRAINS, 'Harvest goals')
    for grain, goal in config['goals'].items():
        _integer(goal, 3, 60, f'{grain} goal')
    _integer(config['max_chains'], 3, 30, 'max_chains')
    if type(config['min_chain']) is not int or config['min_chain'] != 3:
        raise ValueError('Harvest chains start at three neighbouring bundles.')
    if sum(config['goals'].values()) > config['max_chains'] * 30:
        raise ValueError('Harvest goals must fit the available chains.')


def public_harvest_chain_config(config):
    validate_harvest_chain_config(config)
    return deepcopy(config)


def neighbors(cell, rows=6, columns=5):
    row, column = divmod(cell, columns)
    return [next_row * columns + next_column
            for next_row in range(max(0, row - 1), min(rows, row + 2))
            for next_column in range(max(0, column - 1), min(columns, column + 2))
            if (next_row, next_column) != (row, column)]


def available_three_chains(board):
    """Return oriented simple length-three paths in deterministic cell order."""
    for first in range(len(board)):
        for second in neighbors(first):
            if board[first] != board[second]:
                continue
            for third in neighbors(second):
                if third != first and board[third] == board[first]:
                    yield [first, second, third]


def ensure_harvest_move(board):
    # This repair is deterministic and consumes no random values. It only runs
    # on a genuinely stuck board, so existing child-visible matches stay put.
    if next(available_three_chains(board), None) is None:
        board[1] = board[2] = board[0]
        return True
    return False


class HarvestState:
    def __init__(self, config):
        validate_harvest_chain_config(config)
        self.config = config
        self.random = XorShift32(config['seed'])
        self.board = [GRAINS[self.random.next() % len(GRAINS)] for _ in range(30)]
        self.repairs = int(ensure_harvest_move(self.board))
        self.collected = {grain: 0 for grain in GRAINS}
        self.chains = []

    @property
    def completed(self):
        return all(self.collected[grain] >= self.config['goals'][grain] for grain in GRAINS)

    def apply(self, chain):
        if self.completed:
            raise ValueError('Harvest input ends as soon as every basket goal is met.')
        if len(self.chains) >= self.config['max_chains']:
            raise ValueError('Harvest input exceeds the available chains.')
        if not isinstance(chain, list) or not 3 <= len(chain) <= 30:
            raise ValueError('Harvest chains need three to thirty neighbouring cells.')
        for cell in chain:
            _integer(cell, 0, 29, 'Harvest cell')
        if len(set(chain)) != len(chain):
            raise ValueError('A grain bundle can occur only once in a chain.')
        grain = self.board[chain[0]]
        if any(self.board[cell] != grain for cell in chain):
            raise ValueError('A harvest chain must contain one kind of grain.')
        if any(second not in neighbors(first) for first, second in zip(chain, chain[1:])):
            raise ValueError('Harvest chains must follow neighbouring bundles.')
        self.collected[grain] += len(chain)
        cleared = set(chain)
        for column in range(5):
            survivors = [self.board[row * 5 + column] for row in range(5, -1, -1)
                         if row * 5 + column not in cleared]
            for offset, value in enumerate(survivors):
                self.board[(5 - offset) * 5 + column] = value
            for row in range(5 - len(survivors), -1, -1):
                self.board[row * 5 + column] = GRAINS[self.random.next() % 3]
        self.repairs += int(ensure_harvest_move(self.board))
        self.chains.append(list(chain))

    def outcome(self):
        completed = self.completed
        if completed:
            score = 80 + _round_ratio(20 * max(0, self.config['max_chains'] - len(self.chains)),
                                      self.config['max_chains'] - 1)
        else:
            # All fractions are exact rationals to keep client and server
            # rounding stable. 50 * average(capped collected / goal).
            from fractions import Fraction
            fraction = sum((Fraction(min(self.collected[g], self.config['goals'][g]),
                                     self.config['goals'][g]) for g in GRAINS), Fraction())
            score = int(50 * fraction / len(GRAINS))
        return {'completed': completed, 'score': score, 'collected': dict(self.collected),
                'chains_used': len(self.chains), 'max_chains': self.config['max_chains'],
                'board': list(self.board), 'random_state': self.random.state,
                'board_repairs': self.repairs}


def replay_harvest_chain(config, result):
    validate_harvest_chain_config(config)
    _object(result, {'chains'}, 'Harvest result')
    if not isinstance(result['chains'], list) or len(result['chains']) > config['max_chains']:
        raise ValueError('Harvest result must be a bounded list of chains.')
    state = HarvestState(config)
    for chain in result['chains']:
        state.apply(chain)
    return state.outcome()


def build_harvest_chain_config(round_number):
    _integer(round_number, 1, 3, 'round_number')
    goals = ((9, 6, 6), (12, 9, 9), (15, 12, 12))[round_number - 1]
    config = {'mode': 'harvest_chain', 'scene': 'ruth_field', 'round_number': round_number,
              'seed': (1021, 2047, 4093)[round_number - 1], 'rows': 6, 'columns': 5,
              'grain_types': list(GRAINS), 'goals': dict(zip(GRAINS, goals)),
              'max_chains': (18, 18, 20)[round_number - 1], 'min_chain': 3}
    validate_harvest_chain_config(config)
    return config


def example_harvest_chain_result(config):
    """A reproducible short-chain winning replay for cross-platform checks."""
    state = HarvestState(config)
    while not state.completed and len(state.chains) < config['max_chains']:
        choices = list(available_three_chains(state.board))
        # Prefer a grain whose basket needs the largest remaining fraction.
        chain = max(choices, key=lambda cells: (
            (config['goals'][state.board[cells[0]]] - state.collected[state.board[cells[0]]])
            / config['goals'][state.board[cells[0]]], -cells[0], -cells[1], -cells[2]))
        state.apply(chain)
    if not state.completed:
        raise ValueError('The authored harvest round has no checked winning replay.')
    return {'chains': state.chains}


def evaluate_matching_studio(level, result):
    from .services import GameResultError
    try:
        details = (replay_coat_studio(level.config, result)
                   if level.config.get('mode') == 'coat_studio'
                   else replay_harvest_chain(level.config, result))
    except ValueError as exc:
        raise GameResultError(str(exc)) from exc
    completed, score = details.pop('completed'), details.pop('score')
    if level.config['mode'] == 'coat_studio':
        feedback = ('Every stitch fits! Joseph’s colourful coat is ready.' if completed
                    else 'Keep creating! Match each fabric’s colour and pattern.')
    else:
        feedback = ('Beautiful harvest! Ruth filled every basket for Naomi.' if completed
                    else 'A lovely start! Follow matching grain to fill Naomi’s baskets.')
    return completed, level.max_score * score / 100, feedback, details
