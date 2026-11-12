"""Noncharging, stdlib-only report: no credential files, Django, DB or provider I/O."""
import json
import os

try:
    from .render_start import production_preflight_report
except ImportError:
    from render_start import production_preflight_report


def main(environ=None, emit=print):
    report = production_preflight_report(os.environ if environ is None else environ)
    emit(json.dumps(report, sort_keys=True))
    return 0 if report['local_configuration_valid'] else 2


if __name__ == '__main__':
    raise SystemExit(main())
