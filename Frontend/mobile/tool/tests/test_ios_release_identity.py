"""Source regression only; no Xcode/signing/provider/runtime actions."""
from copy import deepcopy
import importlib.util
from pathlib import Path
import plistlib
import unittest

spec=importlib.util.spec_from_file_location('ios_identity',Path(__file__).resolve().parents[1]/'validate_ios_release_identity.py')
identity=importlib.util.module_from_spec(spec);spec.loader.exec_module(identity)


class ClientReleaseIdentityTests(unittest.TestCase):
    def test_actual_source_privacy_covers_payment_and_diagnostics_without_tracking(self):
        result=identity.validate_privacy_manifest(plistlib.loads(identity.PRIVACY_PATH.read_bytes()))
        self.assertTrue(result['source_privacy_manifest_consistent'])
        self.assertFalse(result['app_store_privacy_answers_submitted'])

    def test_removed_declarations_duplicates_tracking_and_purpose_drift_are_refused(self):
        current=plistlib.loads(identity.PRIVACY_PATH.read_bytes())
        cases=[]
        for name in ['PaymentInfo','OtherDiagnosticData']:
            changed=deepcopy(current)
            changed['NSPrivacyCollectedDataTypes']=[row for row in changed['NSPrivacyCollectedDataTypes']
                if row['NSPrivacyCollectedDataType']!='NSPrivacyCollectedDataType'+name]
            cases.append(changed)
        changed=deepcopy(current);changed['NSPrivacyCollectedDataTypes'].append(deepcopy(changed['NSPrivacyCollectedDataTypes'][0]));cases.append(changed)
        for key,value in [('NSPrivacyTracking',True),('NSPrivacyTrackingDomains',['example.test'])]:
            changed=deepcopy(current);changed[key]=value;cases.append(changed)
        for key,value in [('NSPrivacyCollectedDataTypeLinked',False),('NSPrivacyCollectedDataTypeTracking',True),
                          ('NSPrivacyCollectedDataTypePurposes',['NSPrivacyCollectedDataTypePurposeAnalytics'])]:
            changed=deepcopy(current);changed['NSPrivacyCollectedDataTypes'][0][key]=value;cases.append(changed)
        for changed in cases:
            with self.subTest(document=changed),self.assertRaises(ValueError):identity.validate_privacy_manifest(changed)

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
                        ('CODE_SIGN_STYLE = Manual;','CODE_SIGN_STYLE = Automatic;'),
                        ('CODE_SIGN_IDENTITY = "Apple Distribution";','CODE_SIGN_IDENTITY = "Apple Development";'),
                        ('PROVISIONING_PROFILE_SPECIFIER = "Kingdom Kids App Store 2026";','PROVISIONING_PROFILE_SPECIFIER = "Wrong profile";'),
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
