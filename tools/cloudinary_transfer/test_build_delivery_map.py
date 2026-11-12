import copy
import unittest

from tools.cloudinary_transfer.build_delivery_map import MapError, build_map


class DeliveryMapTests(unittest.TestCase):
    def setUp(self):
        digest = 'a' * 64
        public_id = 'kingdom-kids/media-v1/sha256-' + digest
        alias = 'Frontend/mobile/assets/images/stories/noah.webp'
        self.hashes = {name: str(index) * 64 for index, name in enumerate(('manifest', 'selection', 'proof', 'bindings'), 1)}
        upload = {'public_id': public_id, 'resource_type': 'image', 'type': 'authenticated',
                  'sha256': digest, 'bytes': 100, 'source_path': alias, 'aliases': [alias]}
        self.manifest = {'unique_uploads': [upload], 'asset_aliases': [dict(upload, path=alias, delivery_type='authenticated')]}
        self.selection = {'scope': 'first_release_only', 'included': [dict(upload)]}
        self.proof = {'complete': True, 'cloud_name': 'fixture-cloud', 'manifest_sha256': self.hashes['manifest'], 'selection_sha256': self.hashes['selection'],
                      'summary': {'expected_count': 1, 'verified_count': 1, 'failed_count': 0},
                      'objects': [dict(upload, asset_id='immutable-provider-id', version=123, remote_original_verified=True)]}
        self.bindings = {'schema_version': 1, 'scope': 'first_release_only', 'bindings': {alias: ['story-cover:noah']}}

    def build(self):
        return build_map(self.manifest, self.selection, self.proof, self.bindings, hashes=self.hashes, expected_count=1)

    def test_exact_complete_metadata_produces_only_bound_immutable_aliases(self):
        actual = self.build()
        self.assertEqual(list(actual['assets']), list(self.bindings['bindings']))
        self.assertEqual(actual['assets'][next(iter(actual['assets']))]['uses'], ['story-cover:noah'])
        self.assertTrue(actual['remote_originals_verified'])
        self.assertNotIn('url', str(actual))
        self.assertNotIn('api_secret', str(actual))
        self.assertEqual(self.build(), actual)

    def test_incomplete_scope_forged_identity_and_unverified_bytes_are_rejected(self):
        baseline = copy.deepcopy(self.proof)
        mutations = [lambda p: p.update(complete=False),
                     lambda p: p['summary'].update(verified_count=0),
                     lambda p: p.update(selection_sha256='f' * 64),
                     lambda p: p['objects'][0].update(remote_original_verified=False),
                     lambda p: p['objects'][0].update(type='upload'),
                     lambda p: p['objects'][0].update(sha256='b' * 64),
                     lambda p: p['objects'][0].update(bytes=101),
                     lambda p: p['objects'].append(p['objects'][0])]
        for mutate in mutations:
            self.proof = copy.deepcopy(baseline)
            mutate(self.proof)
            with self.assertRaises(MapError):
                self.build()

    def test_unknown_and_noncanonical_bindings_never_enter_map(self):
        for alias in ('Backend/media/private-unpublished.mp3', 'Frontend/mobile/assets/../private.png', 'Frontend/mobile/assets/%2e%2e/private.png'):
            self.bindings['bindings'] = {alias: ['story-cover:noah']}
            with self.assertRaises(MapError):
                self.build()

    def test_alias_cannot_change_verified_resource_type_or_delivery_type(self):
        alias = self.manifest['asset_aliases'][0]
        alias['resource_type'] = 'raw'
        with self.assertRaises(MapError):
            self.build()
        alias['resource_type'] = 'image'
        alias['delivery_type'] = 'upload'
        with self.assertRaises(MapError):
            self.build()


if __name__ == '__main__':
    unittest.main()
