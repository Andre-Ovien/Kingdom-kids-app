"""Read-only release checks. Never loads Django settings, secrets, or network clients."""
import argparse
import ast
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import shlex
import sys
from zoneinfo import ZoneInfo


BACKEND = Path(__file__).resolve().parents[1]
METADATA = (
    'content/releases/character_narration_v1_manifest.json',
    'content/releases/cloudinary_first_release_v1.json',
)
DISABLED_FLAGS = (
    'PARENT_CHECKOUT_SANDBOX_ENABLED',
    'PARENT_CONTENT_ACCESS_STATUS_ENABLED',
    'SQUARE_SANDBOX_ENABLED',
    'SQUARE_SANDBOX_CHECKOUT_ENABLED',
    'SQUARE_SANDBOX_RECONCILIATION_ENABLED',
    'SQUARE_SANDBOX_CANCELLATION_ENABLED',
    'SQUARE_SANDBOX_TERM_BILLING_ENABLED',
    'SQUARE_SANDBOX_TERM_RECONCILIATION_ENABLED',
    'SQUARE_SANDBOX_HTTP_TRANSPORT_ENABLED',
    'PAID_CONTENT_ENFORCEMENT_ENABLED',
    'CLOUDINARY_PRIVATE_DELIVERY_ENABLED',
)
HEALTH_EXEMPTIONS = ['^health/live/$', '^health/ready/$']


def check_source(backend):
    checks = {}
    docker = (backend / 'Dockerfile').read_text()
    copies = []
    for line in docker.splitlines():
        words = line.strip().split(maxsplit=1)
        if words and words[0].upper() == 'COPY':
            operands = (json.loads(words[1]) if words[1].startswith('[')
                        else shlex.split(words[1]))
            copies.extend(operands[:-1])
    checks['exact_docker_copy_allowlist'] = copies == [
        'requirements.txt', 'Core', 'scripts', *METADATA,
    ]
    checks['unprivileged_read_only_app'] = (
        'USER kingdomkids' in docker and 'chmod -R a-w /app' in docker
        and 'PYTHONDONTWRITEBYTECODE=1' in docker
    )
    checks['static_collection_in_image_build'] = (
        'DJANGO_DEBUG=true python Core/manage.py collectstatic --noinput' in docker
    )
    ignores = [line.strip() for line in (backend / '.dockerignore').read_text().splitlines()
               if line.strip() and not line.lstrip().startswith('#')]
    checks['media_and_secret_build_exclusions'] = all(
        item in ignores for item in ('.env', '.env.*', '.venv', 'Core/db.sqlite3', 'media')
    ) and [item for item in ignores if item.lstrip('!').startswith('content')] == [
        'content/*', '!content/releases/', 'content/releases/*',
        *('!' + item for item in METADATA),
    ]
    checks['local_database_backup_exclusions'] = (
        'Core/.cache' in ignores and '**/*.sqlite3*' in ignores
        and not any(item.startswith('!') and item != '!.env.example'
                    and not item.startswith('!content/') for item in ignores)
    )
    source = ast.parse((backend / 'Core/Core/settings.py').read_text())
    assignments = {
        node.targets[0].id: node.value for node in ast.walk(source)
        if isinstance(node, ast.Assign) and len(node.targets) == 1
        and isinstance(node.targets[0], ast.Name)
    }
    flags = set(DISABLED_FLAGS) | {
        name for name in assignments
        if name.startswith('SQUARE_') and name.endswith('_ENABLED')
    }
    for name in sorted(flags):
        value = assignments.get(name)
        checks['default_off_' + name.lower()] = (
            isinstance(value, ast.Call) and isinstance(value.func, ast.Name)
            and value.func.id == 'env_flag' and len(value.args) == 2
            and isinstance(value.args[0], ast.Constant) and value.args[0].value == name
            and isinstance(value.args[1], ast.Constant) and value.args[1].value is False
        )
    checks['exact_health_redirect_exemptions'] = (
        ast.literal_eval(assignments['SECURE_REDIRECT_EXEMPT']) == HEALTH_EXEMPTIONS
    )
    return checks


def check_image(backend):
    """Run later INSIDE the approved image; does not test service credentials."""
    checks = {
        'python_3_14': sys.version_info[:2] == (3, 14),
        'unprivileged_user': hasattr(os, 'geteuid') and os.geteuid() != 0,
        'application_tree_not_writable': not os.access(backend, os.W_OK),
        'no_local_database_or_media': not any((backend / 'Core').rglob('*.sqlite3*'))
            and not (backend / 'Core/.cache').exists()
            and not (backend / 'media').exists(),
    }
    for line in (backend / 'requirements.txt').read_text().splitlines():
        if not line or line.lstrip().startswith('#'):
            continue
        name, pinned = line.split('==', 1)
        name = name.split('[', 1)[0]
        try:
            checks['pinned_' + name.lower()] = importlib.metadata.version(name) == pinned
        except importlib.metadata.PackageNotFoundError:
            checks['pinned_' + name.lower()] = False
    try:
        static = json.loads((backend / 'staticfiles/staticfiles.json').read_text())
        checks['collected_static_manifest'] = bool(static.get('paths'))
    except (OSError, ValueError, AttributeError):
        checks['collected_static_manifest'] = False
    for zone in ('UTC', 'America/Los_Angeles', 'America/New_York', 'Europe/London'):
        try:
            ZoneInfo(zone)
            checks['iana_zone_' + zone] = True
        except (KeyError, ValueError):
            checks['iana_zone_' + zone] = False
    return checks


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--image', action='store_true', help='Check local image files/runtime only.')
    args = parser.parse_args()
    try:
        checks = check_image(BACKEND) if args.image else check_source(BACKEND)
        for relative in METADATA:
            checks['metadata_json_' + Path(relative).name] = isinstance(
                json.loads((BACKEND / relative).read_text()), dict,
            )
        fingerprints = {
            relative: hashlib.sha256((BACKEND / relative).read_bytes()).hexdigest()
            for relative in METADATA
        }
        result = {
            'mode': 'image-local' if args.image else 'source-only',
            'passed': all(checks.values()), 'checks': checks,
            'metadata_sha256': fingerprints,
            'network_accessed': False, 'secrets_loaded': False,
            'production_environment_checked': False,
            'database_or_cache_checked': False, 'migrations_applied': False,
        }
    except (OSError, ValueError, SyntaxError, TypeError, KeyError):
        result = {'passed': False, 'preflight_input_invalid': True}
    print(json.dumps(result, sort_keys=True, indent=2))
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
