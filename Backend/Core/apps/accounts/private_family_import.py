"""Fail-closed, one-family administrative transfer; never exposed as an API."""
import base64
from datetime import timedelta
import hashlib
import json
import re
import uuid
import zlib

from django.contrib.auth.hashers import identify_hasher, is_password_usable
from django.core.exceptions import ValidationError
from django.db import IntegrityError, transaction
from django.utils import timezone
from django.utils.dateparse import parse_datetime
from django.views.decorators.debug import sensitive_variables

from apps.games.models import Game, GameLevel, GameAttempt, KidGameProgress
from apps.progress.models import KidActivityEvent, StreakDailyVisit
from apps.stories.models import Story
from .models import User, KidProfile, KidProfilePreferences, PrivateFamilyImportReceipt

SERVICE = 'kingdom-kids-checkout-staging.onrender.com'
MAX_JSON_BYTES = 2 * 1024 * 1024
MAX_ENCODED_BYTES = 90000
MAX_ROWS = 2000
FIELDS = {
    'parent': {'email', 'password', 'is_active', 'email_verified_at', 'date_joined', 'last_login', 'first_name', 'last_name'},
    'profiles': {'id', 'display_name', 'avatar_key', 'creation_operation_id', 'created_at', 'updated_at'},
    'preferences': {'profile_id', 'story_text_scale', 'narration_enabled', 'streak_timezone_offset_minutes', 'updated_at'},
    'game_progress': {'id', 'profile_id', 'game_slug', 'highest_completed_level', 'total_stars', 'level_progress', 'last_played_at', 'created_at', 'updated_at'},
    'game_attempts': {'id', 'operation_id', 'profile_id', 'game_slug', 'level_number', 'submitted_result', 'completed', 'score', 'stars', 'feedback', 'evaluation', 'created_at'},
    'story_activity': {'id', 'profile_id', 'operation_id', 'event_type', 'story_slug', 'created_at', 'reward_receipt'},
    'streak_visits': {'id', 'profile_id', 'local_date', 'state', 'timezone_offset_minutes', 'created_at', 'reward_receipt'},
}
TOP_FIELDS = {'version', 'import_id', 'target_service', 'created_at', 'expires_at', 'games', 'stories', *FIELDS}


class FamilyImportRejected(Exception):
    """Intentionally excludes user data, provider credentials and payload bytes."""


def canonical_bytes(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False, allow_nan=False).encode('utf-8')


@sensitive_variables()
def encode_payload(payload):
    raw = canonical_bytes(payload)
    encoded = base64.b64encode(zlib.compress(raw, 9)).decode('ascii')
    if len(raw) > MAX_JSON_BYTES or len(encoded) > MAX_ENCODED_BYTES:
        raise FamilyImportRejected('Family transfer exceeds the size limit.')
    return encoded, hashlib.sha256(raw).hexdigest()


@sensitive_variables()
def decode_payload(encoded, digest):
    try:
        if not isinstance(encoded, str) or not 1 <= len(encoded) <= MAX_ENCODED_BYTES:
            raise ValueError
        if not isinstance(digest, str) or not re.fullmatch(r'[0-9a-f]{64}', digest):
            raise ValueError
        compressed = base64.b64decode(encoded, validate=True)
        decoder = zlib.decompressobj()
        raw = decoder.decompress(compressed, MAX_JSON_BYTES + 1)
        if len(raw) > MAX_JSON_BYTES or decoder.unconsumed_tail or not decoder.eof or decoder.unused_data:
            raise ValueError
        if hashlib.sha256(raw).hexdigest() != digest:
            raise ValueError
        def unique_pairs(pairs):
            result = {}
            for key, value in pairs:
                if key in result:
                    raise ValueError
                result[key] = value
            return result
        value = json.loads(raw, object_pairs_hook=unique_pairs, parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
        if raw != canonical_bytes(value):
            raise ValueError
        return value
    except (ValueError, TypeError, UnicodeError, zlib.error):
        raise FamilyImportRejected('Family transfer encoding or checksum is invalid.') from None


def rule_digest(level):
    return hashlib.sha256(canonical_bytes({'game_type': level.game.game_type,
        'config': level.config, 'max_score': level.max_score,
        'star_thresholds': level.star_thresholds})).hexdigest()


def _exact(value, fields):
    if not isinstance(value, dict) or set(value) != fields:
        raise FamilyImportRejected('Family transfer schema is invalid.')


def _datetime(value):
    if not isinstance(value, str):
        raise FamilyImportRejected('Family transfer timestamps are invalid.')
    parsed = parse_datetime(value)
    if parsed is None or timezone.is_naive(parsed):
        raise FamilyImportRejected('Family transfer timestamps are invalid.')
    return parsed


@sensitive_variables()
def _insert(model, values):
    values = dict(values)
    timestamps = {}
    for field in model._meta.concrete_fields:
        if field.name in values and field.get_internal_type() == 'DateTimeField':
            value = values[field.name]
            values[field.name] = _datetime(value) if value is not None else None
            if field.auto_created or getattr(field, 'auto_now', False) or getattr(field, 'auto_now_add', False):
                timestamps[field.name] = values[field.name]
    obj = model(**values)
    # Historical receipts legitimately use the model's empty-dict default.
    # JSON shape is checked above; Django's form-style blank check otherwise
    # rejects these valid stored defaults while restoring old earned history.
    empty_json = [field.name for field in model._meta.concrete_fields
                  if field.get_internal_type() == 'JSONField' and values.get(field.name) == {}]
    obj.full_clean(exclude=empty_json, validate_unique=False, validate_constraints=False)
    obj.save(force_insert=True)
    if timestamps:
        model.objects.filter(pk=obj.pk).update(**timestamps)
    return obj


@sensitive_variables()
def apply_payload(payload, digest, expected_email, dry_run=True):
    try:
        return _apply_payload(payload, digest, expected_email, dry_run)
    except FamilyImportRejected:
        raise
    except Exception:
        raise FamilyImportRejected('Family transfer validation or transaction failed; nothing was changed.') from None


@sensitive_variables()
def _apply_payload(payload, digest, expected_email, dry_run):
    _exact(payload, TOP_FIELDS)
    if (type(payload['version']) is not int or payload['version'] != 1
            or payload['target_service'] != SERVICE
            or hashlib.sha256(canonical_bytes(payload)).hexdigest() != digest
            or not isinstance(expected_email, str) or not expected_email.strip()):
        raise FamilyImportRejected('Family transfer binding is invalid.')
    import_id = uuid.UUID(payload['import_id'])
    parent_values = payload['parent']
    _exact(parent_values, FIELDS['parent'])
    if (parent_values['email'] != User.objects.normalize_email(expected_email)
            or parent_values['is_active'] is not True or parent_values['email_verified_at'] is None):
        raise FamilyImportRejected('Family transfer parent binding is invalid.')
    if (not isinstance(payload['games'], list) or len(payload['games']) > 100
            or not isinstance(payload['stories'], list) or len(payload['stories']) > 100):
        raise FamilyImportRejected('Family transfer catalogue scope is invalid.')
    for key in FIELDS.keys() - {'parent'}:
        rows = payload[key]
        if not isinstance(rows, list) or len(rows) > MAX_ROWS:
            raise FamilyImportRejected('Family transfer row limit is invalid.')
        for row in rows:
            _exact(row, FIELDS[key])
    if len(payload['profiles']) != 3 or sum(len(payload[k]) for k in FIELDS if k != 'parent') > MAX_ROWS:
        raise FamilyImportRejected('Family transfer family scope is invalid.')
    created = _datetime(payload['created_at'])
    expires = _datetime(payload['expires_at'])
    if not created < expires <= created + timedelta(hours=2):
        raise FamilyImportRejected('Family transfer validity window is invalid.')
    with transaction.atomic():
        # The parent unique-email constraint also serializes competing new IDs.
        receipt = PrivateFamilyImportReceipt.objects.select_for_update().filter(pk=import_id).first()
        if receipt is not None:
            if receipt.digest != digest:
                raise FamilyImportRejected('Family transfer receipt conflicts with this payload.')
            return {'status': 'already_completed', 'changed': False}
        now = timezone.now()
        if created > now + timedelta(minutes=5) or expires <= now:
            raise FamilyImportRejected('Family transfer has expired or is not yet valid.')
        if User.objects.select_for_update().filter(email__iexact=expected_email.strip()).exists():
            raise FamilyImportRejected('Family transfer refuses to overwrite an existing parent.')
        encoded = parent_values['password']
        if not isinstance(encoded, str) or not is_password_usable(encoded):
            raise FamilyImportRejected('Family transfer requires a usable stored password encoding.')
        identify_hasher(encoded).decode(encoded)
        profiles = {str(uuid.UUID(row['id'])) for row in payload['profiles']}
        if len(profiles) != len(payload['profiles']) or KidProfile.objects.filter(pk__in=profiles).exists():
            raise FamilyImportRejected('Family transfer child identity collision.')
        games = {}
        for item in payload['games']:
            _exact(item, {'slug', 'levels'})
            if item['slug'] in games or not isinstance(item['levels'], list) or not item['levels']:
                raise FamilyImportRejected('Family transfer game binding is invalid.')
            game = Game.objects.select_for_update().get(slug=item['slug'])
            levels = {}
            for level in item['levels']:
                _exact(level, {'level_number', 'rule_sha256'})
                number = level['level_number']
                if type(number) is not int or number in levels:
                    raise FamilyImportRejected('Family transfer level binding is invalid.')
                remote = GameLevel.objects.select_for_update().get(game=game, level_number=number)
                if rule_digest(remote) != level['rule_sha256']:
                    raise FamilyImportRejected('Family transfer game rules differ from the target.')
                levels[number] = remote
            if set(game.levels.values_list('level_number', flat=True)) != set(levels):
                raise FamilyImportRejected('Family transfer level catalogue differs from the target.')
            games[item['slug']] = (game, levels)
        stories = {}
        for item in payload['stories']:
            _exact(item, {'slug', 'text_sha256'})
            if item['slug'] in stories:
                raise FamilyImportRejected('Family transfer story binding is invalid.')
            story = Story.objects.select_for_update().get(slug=item['slug'])
            if hashlib.sha256(story.body.encode('utf-8')).hexdigest() != item['text_sha256']:
                raise FamilyImportRejected('Family transfer story text differs from the target.')
            stories[item['slug']] = story
        parent = _insert(User, {**parent_values, 'is_staff': False, 'is_superuser': False})
        for row in payload['profiles']:
            _insert(KidProfile, {**row, 'parent': parent})
        # Every imported child-owned row must refer to this exact transferred family.
        models = {'preferences': KidProfilePreferences, 'game_progress': KidGameProgress,
                  'game_attempts': GameAttempt, 'story_activity': KidActivityEvent, 'streak_visits': StreakDailyVisit}
        for kind, model in models.items():
            for row in payload[kind]:
                values = dict(row)
                for key in {'completed', 'narration_enabled'} & values.keys():
                    if type(values[key]) is not bool:
                        raise FamilyImportRejected('Family transfer boolean fields are invalid.')
                for key in {'highest_completed_level', 'total_stars', 'level_number', 'score', 'stars', 'timezone_offset_minutes'} & values.keys():
                    if type(values[key]) is not int:
                        raise FamilyImportRejected('Family transfer numeric fields are invalid.')
                for key in {'level_progress', 'submitted_result', 'evaluation', 'reward_receipt'} & values.keys():
                    if not isinstance(values[key], dict):
                        raise FamilyImportRejected('Family transfer receipt fields are invalid.')
                if str(uuid.UUID(values['profile_id'])) not in profiles:
                    raise FamilyImportRejected('Family transfer contains a foreign child reference.')
                if kind in {'game_progress', 'game_attempts'}:
                    game, levels = games[values.pop('game_slug')]
                    values['game'] = game
                    if kind == 'game_attempts':
                        values['level'] = levels[values.pop('level_number')]
                        if not 0 <= values['score'] <= values['level'].max_score or not 0 <= values['stars'] <= 3:
                            raise FamilyImportRejected('Family transfer game result bounds are invalid.')
                    elif not 0 <= values['highest_completed_level'] <= len(levels) or not 0 <= values['total_stars'] <= len(levels) * 3:
                        raise FamilyImportRejected('Family transfer progress bounds are invalid.')
                if kind == 'story_activity':
                    values['story'] = stories[values.pop('story_slug')]
                _insert(model, values)
        counts = {key: len(payload[key]) for key in FIELDS if key != 'parent'}
        if dry_run:
            transaction.set_rollback(True)
            return {'status': 'validated', 'changed': False, 'counts': counts}
        PrivateFamilyImportReceipt.objects.create(id=import_id, parent=parent, digest=digest)
        return {'status': 'completed', 'changed': True, 'counts': counts}
