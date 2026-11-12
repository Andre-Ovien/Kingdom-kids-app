"""Local safety checks; no provider/credentials/app runtime access."""

import copy
import importlib.util
from pathlib import Path
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location('prepare', Path(__file__).with_name('prepare.py'))
prepare = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(prepare)
ROOT = Path(__file__).resolve().parents[2]


class PreparationSafetyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.manifest = prepare.inventory(ROOT)

    def test_approved_recordings_and_all_canonical_sources_verify(self):
        result = prepare.verify(ROOT, self.manifest)
        self.assertEqual(result['uploads'], 0)
        self.assertEqual(result['network_requests'], 0)
        self.assertEqual(self.manifest['summary']['recording_bytes'], 19_454_292)
        self.assertEqual(self.manifest['summary']['narration_tracks'], 33)
        self.assertFalse(self.manifest['missing_references'])
        self.assertTrue(all(not row.get('model_dependencies', {}).get('external_uris')
                            for row in self.manifest['asset_aliases']))

    def test_public_or_overwrite_upload_options_are_rejected(self):
        for field, value in [('type', 'upload'), ('upload_options', {'overwrite': True})]:
            with self.subTest(field=field):
                data = copy.deepcopy(self.manifest)
                data['unique_uploads'][0][field] = value
                with self.assertRaises(ValueError):
                    prepare.verify(ROOT, data)

    def test_modified_object_identity_or_unapproved_alias_is_rejected(self):
        data = copy.deepcopy(self.manifest)
        data['unique_uploads'][0]['public_id'] += '-different'
        with self.assertRaises(ValueError):
            prepare.verify(ROOT, data)

    def test_edited_remote_success_cannot_become_a_preparation_claim(self):
        for collection in ['unique_uploads', 'asset_aliases']:
            for key, value in [('remote_verified', True), ('remote_receipt', {'state': 'uploaded'})]:
                with self.subTest(collection=collection, key=key):
                    data = copy.deepcopy(self.manifest)
                    data[collection][0][key] = value
                    with self.assertRaises(ValueError):
                        prepare.verify(ROOT, data)
        data = copy.deepcopy(self.manifest)
        data['asset_aliases'].append({'path': 'Backend/media/private-user-upload.mp3'})
        with self.assertRaises(ValueError):
            prepare.verify(ROOT, data)

    def test_traversal_and_symlink_escape_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            folder = root / 'Frontend/mobile/assets'
            folder.mkdir(parents=True)
            external = root / 'outside.png'
            external.write_bytes(b'not an allowed asset')
            (folder / 'link.png').symlink_to(external)
            for path in ['Frontend/mobile/assets/../outside.png',
                         'Frontend/mobile/assets/link.png', '/tmp/arbitrary.png']:
                with self.subTest(path=path), self.assertRaises(ValueError):
                    prepare.safe_path(root, path)


if __name__ == '__main__':
    unittest.main()
