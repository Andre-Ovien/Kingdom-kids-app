"""Read-only single-family SQLite export into private, ignored operator files.

Requires KK_TEST_FAMILY_EXPORT_EMAIL in the private process environment. No
password text, session token, billing state or another family is exported.
"""
import base64
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import sys
import uuid
import zlib

SERVICE = 'kingdom-kids-checkout-staging.onrender.com'
MAX_JSON_BYTES = 2 * 1024 * 1024
MAX_ENCODED_BYTES = 90000


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False, allow_nan=False).encode()


def stamp(value):
    if value is None:
        return None
    parsed = datetime.fromisoformat(value)
    return parsed.replace(tzinfo=timezone.utc).isoformat() if parsed.tzinfo is None else parsed.isoformat()


def read_rows(db, table, fields, profile_ids, json_fields=()):
    slots = ','.join('?' for _ in profile_ids)
    rows = [dict(row) for row in db.execute(
        f'SELECT {",".join(fields)} FROM {table} WHERE profile_id IN ({slots}) ORDER BY rowid', profile_ids)]
    for row in rows:
        for field in json_fields:
            row[field] = json.loads(row[field])
        for field in ['created_at', 'updated_at', 'last_played_at']:
            if field in row:
                row[field] = stamp(row[field])
        for field in ['completed', 'narration_enabled']:
            if field in row:
                row[field] = bool(row[field])
    return rows


def export_family(sqlite_path, email):
    with sqlite3.connect(sqlite_path.resolve().as_uri() + '?mode=ro', uri=True) as db:
        db.row_factory = sqlite3.Row
        db.execute('PRAGMA query_only=ON')
        db.execute('BEGIN')
        source = db.execute('SELECT id,is_staff,is_superuser,email,password,is_active,email_verified_at,date_joined,last_login,first_name,last_name FROM accounts_user WHERE lower(email)=lower(?)', (email,)).fetchall()
        if len(source) != 1:
            raise ValueError('exactly one source parent required')
        parent = dict(source[0])
        parent_id = parent.pop('id')
        if parent.pop('is_staff') or parent.pop('is_superuser') or not parent['is_active'] or not parent['email_verified_at']:
            raise ValueError('source parent is not an eligible nonprivileged verified account')
        parent['is_active'] = True
        for field in ['email_verified_at', 'date_joined', 'last_login']:
            parent[field] = stamp(parent[field])
        profiles = [dict(row) for row in db.execute('SELECT id,display_name,avatar_key,creation_operation_id,created_at,updated_at FROM accounts_kidprofile WHERE parent_id=? ORDER BY created_at', (parent_id,))]
        if len(profiles) != 3:
            raise ValueError('reviewed family must contain exactly three profiles')
        ids = [row['id'] for row in profiles]
        for row in profiles:
            row['created_at'], row['updated_at'] = stamp(row['created_at']), stamp(row['updated_at'])
        prefs = read_rows(db, 'accounts_kidprofilepreferences', ['profile_id','story_text_scale','narration_enabled','streak_timezone_offset_minutes','updated_at'], ids)
        progress = read_rows(db, 'games_kidgameprogress', ['id','profile_id','game_id','highest_completed_level','total_stars','level_progress','last_played_at','created_at','updated_at'], ids, ['level_progress'])
        attempts = read_rows(db, 'games_gameattempt', ['id','operation_id','profile_id','game_id','level_id','submitted_result','completed','score','stars','feedback','evaluation','created_at'], ids, ['submitted_result','evaluation'])
        activity = read_rows(db, 'progress_kidactivityevent', ['id','profile_id','operation_id','event_type','story_id','created_at','reward_receipt'], ids, ['reward_receipt'])
        visits = read_rows(db, 'progress_streakdailyvisit', ['id','profile_id','local_date','state','timezone_offset_minutes','created_at','reward_receipt'], ids, ['reward_receipt'])
        games = []
        game_lookup, level_lookup = {}, {}
        for gid in sorted({row['game_id'] for row in [*progress, *attempts]}):
            game = db.execute('SELECT slug,game_type FROM games_game WHERE id=?',(gid,)).fetchone()
            if game is None:
                raise ValueError('missing source game')
            game_lookup[gid] = game['slug']
            levels = []
            for row in db.execute('SELECT id,level_number,config,max_score,star_thresholds FROM games_gamelevel WHERE game_id=? ORDER BY level_number',(gid,)):
                level_lookup[row['id']] = (gid, row['level_number'])
                rule = {'game_type':game['game_type'],'config':json.loads(row['config']),'max_score':row['max_score'],'star_thresholds':json.loads(row['star_thresholds'])}
                levels.append({'level_number':row['level_number'],'rule_sha256':hashlib.sha256(canonical(rule)).hexdigest()})
            games.append({'slug':game['slug'],'levels':levels})
        for row in progress:
            row['game_slug'] = game_lookup[row.pop('game_id')]
        for row in attempts:
            gid = row.pop('game_id')
            bound_gid, number = level_lookup[row.pop('level_id')]
            if bound_gid != gid:
                raise ValueError('source level belongs to another game')
            row['game_slug'], row['level_number'] = game_lookup[gid], number
        stories, story_lookup = [], {}
        for sid in sorted({row['story_id'] for row in activity}):
            story = db.execute('SELECT slug,body FROM stories_story WHERE id=?',(sid,)).fetchone()
            if story is None:
                raise ValueError('missing source story')
            story_lookup[sid] = story['slug']
            stories.append({'slug':story['slug'],'text_sha256':hashlib.sha256(story['body'].encode()).hexdigest()})
        for row in activity:
            row['story_slug'] = story_lookup[row.pop('story_id')]
        now = datetime.now(timezone.utc)
        return {'version':1,'import_id':str(uuid.uuid4()),'target_service':SERVICE,'created_at':now.isoformat(),
                'expires_at':(now+timedelta(hours=2)).isoformat(),'parent':parent,'profiles':profiles,'preferences':prefs,
                'games':games,'stories':stories,'game_progress':progress,'game_attempts':attempts,
                'story_activity':activity,'streak_visits':visits}


def private_write(path, content):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, 'O_NOFOLLOW', 0), 0o600)
    with os.fdopen(fd, 'wb') as output:
        output.write(content)


def main():
    if len(sys.argv) != 3:
        raise ValueError('provide source SQLite file and ignored private output directory')
    email = os.environ.get('KK_TEST_FAMILY_EXPORT_EMAIL', '').strip().lower()
    if not email or '@' not in email:
        raise ValueError('explicit private target email is required')
    source, output = Path(sys.argv[1]), Path(sys.argv[2])
    # Operator supplies a disposable directory, never a repository source path.
    root = Path(__file__).resolve().parents[2]
    if output.resolve().is_relative_to(root / 'output') is False:
        raise ValueError('private export must remain under ignored output')
    output.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(output, 0o700)
    payload = export_family(source, email)
    raw = canonical(payload)
    encoded = base64.b64encode(zlib.compress(raw,9)).decode('ascii')
    if len(raw) > MAX_JSON_BYTES or len(encoded) > MAX_ENCODED_BYTES:
        raise ValueError('private transfer exceeds bounded environment size')
    digest = hashlib.sha256(raw).hexdigest()
    private_write(output/'family.json', raw)
    private_write(output/'render-private-env.json', canonical({
        'KK_TEST_FAMILY_IMPORT_ZLIB_B64':encoded,'KK_TEST_FAMILY_IMPORT_SHA256':digest,
        'KK_TEST_FAMILY_IMPORT_EMAIL':email}))
    print(json.dumps({'exported':True,'raw_bytes':len(raw),'encoded_bytes':len(encoded),
                      'profiles':len(payload['profiles']),
                      'game_progress':len(payload['game_progress']),'game_attempts':len(payload['game_attempts']),
                      'story_activity':len(payload['story_activity']),'streak_visits':len(payload['streak_visits']),
                      'expires_at':payload['expires_at'],'private_file_mode':'0600'}))


if __name__ == '__main__':
    try:
        main()
    except Exception:
        print('Private family export failed; no credential details are displayed.', file=sys.stderr)
        raise SystemExit(1) from None
