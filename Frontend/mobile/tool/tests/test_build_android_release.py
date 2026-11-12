"""Exercise release argument guards with fake tools; never build or sign an app."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


MOBILE = Path(__file__).resolve().parents[2]
SCRIPT = MOBILE / "tool/build_android_release.sh"
PINNED_FLUTTER = json.loads((MOBILE / ".fvmrc").read_text())["flutter"]


class ReleaseScriptTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.record = self.root / "calls.jsonl"
        fake_tool = """#!/usr/bin/env python3
import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
with open(os.environ['FAKE_CALLS'], 'a') as output:
    output.write(json.dumps({'tool': name, 'args': sys.argv[1:], 'cwd': os.getcwd()}) + '\\n')
if name == 'flutter' and sys.argv[1:] == ['--version', '--machine']:
    print(json.dumps({'frameworkVersion': os.environ['FAKE_FLUTTER_VERSION']}))
if name == 'dart':
    sys.exit(int(os.environ.get('FAKE_DART_STATUS', '0')))
"""
        for name in ["flutter", "dart"]:
            path = self.bin / name
            path.write_text(fake_tool)
            path.chmod(0o755)
        self.environment = {
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "FAKE_CALLS": str(self.record),
            "FAKE_FLUTTER_VERSION": PINNED_FLUTTER,
            "API_BASE_URL": "https://api.fixture.example/api",
            "CONTENT_MEDIA_HOSTS": "media.fixture.example",
            "BUILD_NUMBER": "23",
            # Fake executables never load these synthetic fixture values.
            "ANDROID_KEYSTORE_PATH": "fixture-not-a-real-key",
            "ANDROID_KEYSTORE_PASSWORD": "fixture",
            "ANDROID_KEY_ALIAS": "fixture",
            "ANDROID_KEY_PASSWORD": "fixture",
        }

    def run_script(self, *arguments, **environment):
        return subprocess.run(
            ["bash", str(SCRIPT), *arguments],
            cwd=self.root,
            env={**self.environment, **environment},
            text=True,
            capture_output=True,
            check=False,
        )

    def calls(self):
        if not self.record.exists():
            return []
        return [json.loads(line) for line in self.record.read_text().splitlines()]

    def test_build_keeps_guarded_values_and_resolves_project_from_any_cwd(self):
        symbols = str(self.root / "symbols with spaces")
        result = self.run_script(
            "--obfuscate", "--split-debug-info", symbols, "--build-name=1.2.3"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        self.assertTrue(all(call["cwd"] == str(MOBILE) for call in calls))
        self.assertEqual(calls[1]["args"], [
            "run", "tool/validate_release_config.dart",
            self.environment["API_BASE_URL"], self.environment["CONTENT_MEDIA_HOSTS"],
        ])
        self.assertEqual(calls[2]["args"], [
            "build", "appbundle", "--release", "--build-number=23",
            "--dart-define=API_BASE_URL=https://api.fixture.example/api",
            "--dart-define=CONTENT_MEDIA_HOSTS=media.fixture.example",
            "--obfuscate", "--split-debug-info", symbols, "--build-name=1.2.3",
        ])

    def test_caller_cannot_override_release_endpoint_mode_number_or_entrypoint(self):
        for arguments in [
            ["--debug"], ["--profile"], ["--release"],
            ["--build-number=99"], ["--build-number", "99"],
            ["--dart-define=API_BASE_URL=http://localhost/api"],
            ["--dart-define-from-file=unvalidated.json"],
            ["--target=lib/preview.dart"], ["-t", "lib/preview.dart"],
            ["--flavor=qa"], ["--config-only"], ["--unknown-future-option"],
        ]:
            with self.subTest(arguments=arguments):
                result = self.run_script(*arguments)
                self.assertEqual(result.returncode, 64)
                self.assertEqual(self.calls(), [])

    def test_play_build_number_range_is_checked_before_any_tool_runs(self):
        for number in ["", "0", "00", "-1", "bad", "2100000001", "9" * 30]:
            with self.subTest(number=number):
                result = self.run_script(BUILD_NUMBER=number)
                self.assertEqual(result.returncode, 64)
                self.assertEqual(self.calls(), [])
        result = self.run_script(BUILD_NUMBER="2100000000")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_missing_option_value_cannot_be_consumed_as_another_flag(self):
        for arguments in [
            ["--split-debug-info"], ["--build-name="],
            ["--build-name", "--debug"], ["--split-debug-info=--profile"],
        ]:
            with self.subTest(arguments=arguments):
                self.assertEqual(self.run_script(*arguments).returncode, 64)
                self.assertEqual(self.calls(), [])

    def test_mismatched_toolchain_or_failed_validation_never_runs_build(self):
        self.assertEqual(
            self.run_script(FAKE_FLUTTER_VERSION="0.0.0").returncode, 64
        )
        self.assertEqual(len(self.calls()), 1)
        self.record.unlink()
        self.assertEqual(self.run_script(FAKE_DART_STATUS="64").returncode, 64)
        self.assertEqual([call["tool"] for call in self.calls()], ["flutter", "dart"])


if __name__ == "__main__":
    unittest.main()
