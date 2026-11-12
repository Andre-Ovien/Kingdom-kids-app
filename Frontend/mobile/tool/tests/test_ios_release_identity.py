"""Source regression only; no Xcode/signing/provider/runtime actions."""
from copy import deepcopy
import importlib.util
from pathlib import Path
import unittest

spec=importlib.util.spec_from_file_location('ios_identity',Path(__file__).resolve().parents[1]/'validate_ios_release_identity.py')
identity=importlib.util.module_from_spec(spec);spec.loader.exec_module(identity)


class ClientReleaseIdentityTests(unittest.TestCase):
    def test_actual_client_release_and_existing_development_return_boundaries(self):
        result=identity.validate(*identity.load_source())
        self.assertTrue(result['source_identity_consistent'])
        self.assertTrue(result['debug_profile_identity_preserved'])
        self.assertFalse(result['archive_signature_or_profile_verified'])
        self.assertFalse(result['upload_ready_certified'])

    def test_dev_release_wrong_client_or_changed_debug_profile_are_refused(self):
        project,defines,association,entitlements=identity.load_source()
        for old,new in [('DEVELOPMENT_TEAM = GG228DP7G6;','DEVELOPMENT_TEAM = VTV9889TNF;'),
                        ('PRODUCT_BUNDLE_IDENTIFIER = app.kingdom-kids.kingdomkids;','PRODUCT_BUNDLE_IDENTIFIER = com.andreovien.kingdomkids;'),
                        ('DEVELOPMENT_TEAM = VTV9889TNF;','DEVELOPMENT_TEAM = GG228DP7G6;'),
                        ('CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements;','CODE_SIGN_ENTITLEMENTS = Runner/Runner-DevPreview.entitlements;')]:
            with self.subTest(old=old),self.assertRaises(ValueError):identity.validate(project.replace(old,new),defines,association,entitlements)

    def test_preview_wrong_identity_and_broad_or_missing_associations_are_refused(self):
        project,defines,association,entitlements=identity.load_source()
        for changes in [{'APP_STORE_BUNDLE_ID':identity.DEV_BUNDLE},{'APP_STORE_TEAM_ID':identity.DEV_TEAM},
                        {'HOSTED_RETURN_SCHEME_ONLY_PREVIEW':True}]:
            with self.subTest(changes=changes),self.assertRaises(ValueError):identity.validate(project,{**defines,**changes},association,entitlements)
        for app_ids,path in [([identity.DEV_TEAM+'.'+identity.DEV_BUNDLE],'/payments/return/'),
                             ([identity.CLIENT_TEAM+'.'+identity.CLIENT_BUNDLE],'/*')]:
            changed=deepcopy(association);changed['applinks']['details'][0].update(appIDs=app_ids,components=[{'/':path}])
            with self.assertRaises(ValueError):identity.validate(project,defines,changed,entitlements)
