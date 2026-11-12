"""Canonical-policy parity and fail-closed generation checks."""

import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location(
    'privacy_policy_generator', Path(__file__).resolve().parents[1] / 'generate_privacy_policy.py',
)
GENERATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GENERATOR)


class CanonicalPrivacyPolicyTests(unittest.TestCase):
    def setUp(self):
        self.policy = GENERATOR.POLICY.read_text()
        self.config = GENERATOR.CONFIG.read_text()

    def test_every_policy_section_and_confirmed_operator_contact_survives(self):
        document = GENERATOR.generate_document(self.policy, self.config)
        self.assertEqual(len(document['sections']), 11)
        self.assertEqual(len({s['id'] for s in document['sections']}), 11)
        text = ' '.join(b['text'] for s in document['sections'] for b in s['blocks'])
        for expected in [
            'iOS and Android apps', 'prerecorded synthetic character narration',
            'Production vendors have not yet been named',
            'Production log and backup schedules are not yet finalized',
            'Kingdom Kids LLC operates Kingdom Kids', 'ages 3–10',
            'kingdomkidshq@gmail.com',
        ]:
            self.assertIn(expected, text)
        self.assertFalse(document['contact_is_provisional'])
        self.assertEqual(document['contact_email'], 'kingdomkidshq@gmail.com')
        self.assertNotIn('privacy@kingdom-kids.app', text)
        self.assertNotIn('This privacy inbox is provisional', text)
        self.assertEqual(document['last_updated'], '12 November 2026')
        self.assertEqual(document['canonical_url'], 'https://kingdom-kids.app/privacy/')

    def test_bundled_asset_is_exactly_current_deterministic_output(self):
        generated = GENERATOR.encoded_document(self.policy, self.config)
        self.assertEqual(generated, GENERATOR.encoded_document(self.policy, self.config))
        self.assertEqual(generated, GENERATOR.OUTPUT.read_text())
        self.assertEqual(json.loads(generated)['schema_version'], 1)

    def test_unrecognized_markup_cannot_silently_drop_legal_copy(self):
        for marker in ['<iframe src="https://example.com"></iframe>', '<h4>New rule</h4>']:
            source = self.policy.replace('<h2 id="scope-title">', marker + '<h2 id="scope-title">')
            with self.subTest(marker=marker), self.assertRaises(ValueError):
                GENERATOR.generate_document(source, self.config)

    def test_unresolved_dynamic_content_and_broken_structure_fail(self):
        cases = [
            self.policy.replace('{privacyContact.email}', '{privacyContact.unknown}'),
            self.policy.replace('</section>', '', 1),
            self.policy.replace('href="/account-deletion/"', 'href="javascript:alert(1)"'),
        ]
        for source in cases:
            with self.subTest(source=source[:60]), self.assertRaises(ValueError):
                GENERATOR.generate_document(source, self.config)

    def test_check_mode_detects_stale_asset_without_rewriting_it(self):
        current = GENERATOR.encoded_document(self.policy, self.config)
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'policy.json'
            output.write_text(current)
            with patch.object(GENERATOR, 'OUTPUT', output), patch('sys.argv', ['generator', '--check']):
                with contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(GENERATOR.main(), 0)
                output.write_text(current + ' ')
                with contextlib.redirect_stderr(io.StringIO()) as error:
                    self.assertEqual(GENERATOR.main(), 1)
                self.assertIn('stale', error.getvalue())
                self.assertEqual(output.read_text(), current + ' ')


if __name__ == '__main__':
    unittest.main()
