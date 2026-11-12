"""Source-only identity consistency. Does not build, sign, provision or upload."""
import json
from pathlib import Path
import plistlib
import re

MOBILE = Path(__file__).resolve().parents[1]
ROOT = MOBILE.parents[1]
CLIENT_TEAM = 'GG228DP7G6'
CLIENT_BUNDLE = 'app.kingdom-kids.kingdomkids'
DEV_TEAM = 'VTV9889TNF'
DEV_BUNDLE = 'com.andreovien.kingdomkids'
CONFIGS = {'Release': '97C147071CF9000F007C117D', 'Debug': '97C147061CF9000F007C117D',
           'Profile': '249021D4217E4FDB00AE95B9'}
PRIVACY_PATH = MOBILE / 'ios/Runner/PrivacyInfo.xcprivacy'
REVIEWED_PRIVACY_TYPES = {
    'Name', 'EmailAddress', 'UserID', 'GameplayContent', 'ProductInteraction',
    'PurchaseHistory', 'PaymentInfo', 'OtherDiagnosticData', 'OtherDataTypes',
}


def runner_settings(project, configuration):
    identifier = CONFIGS[configuration]
    match = re.search(r'\b' + identifier + r' /\* ' + configuration + r' \*/ = \{(.*?)\n\t\t\};', project, re.S)
    if not match: raise ValueError('Runner configuration is missing.')
    fields = dict(re.findall(r'^\s*([A-Z_]+) = ([^;\n]+);', match.group(1), re.M))
    return {key: value.strip('"') for key, value in fields.items()}


def validate(project, defines, association, entitlements):
    for name in CONFIGS:
        settings = runner_settings(project, name)
        team, bundle = (CLIENT_TEAM, CLIENT_BUNDLE) if name == 'Release' else (DEV_TEAM, DEV_BUNDLE)
        if settings.get('DEVELOPMENT_TEAM') != team or settings.get('PRODUCT_BUNDLE_IDENTIFIER') != bundle:
            raise ValueError('Runner identity does not match its release/development boundary.')
        if settings.get('CODE_SIGN_STYLE') != 'Automatic': raise ValueError('Unexpected signing configuration.')
    if runner_settings(project, 'Release').get('CODE_SIGN_ENTITLEMENTS') != 'Runner/Runner.entitlements':
        raise ValueError('App Store Release must use the normal Associated Domains entitlements.')
    if (defines.get('APP_STORE_TEAM_ID') != CLIENT_TEAM or defines.get('APP_STORE_BUNDLE_ID') != CLIENT_BUNDLE
            or defines.get('HOSTED_RETURN_SCHEME_ONLY_PREVIEW') is not False):
        raise ValueError('App Store input identity or return mode is incorrect.')
    if entitlements.get('com.apple.developer.associated-domains') != ['applinks:kingdom-kids.app']:
        raise ValueError('Expected exact associated domain is missing.')
    expected_ids = {CLIENT_TEAM + '.' + CLIENT_BUNDLE, DEV_TEAM + '.' + DEV_BUNDLE}
    details = association.get('applinks', {}).get('details', [])
    if len(details) != 1 or set(details[0].get('appIDs', [])) != expected_ids:
        raise ValueError('AASA must retain the development ID and include the registered client ID.')
    components = details[0].get('components', [])
    if len(components) != 1 or components[0].get('/') != '/payments/return/':
        raise ValueError('Payment association must remain restricted to the exact return path.')
    return {'source_identity_consistent': True, 'client_release_team': CLIENT_TEAM,
            'client_release_bundle': CLIENT_BUNDLE, 'debug_profile_identity_preserved': True,
            'archive_signature_or_profile_verified': False, 'upload_ready_certified': False}


def load_source():
    return ((MOBILE/'ios/Runner.xcodeproj/project.pbxproj').read_text(),
            json.loads((MOBILE/'tool/hosted_production_build_defines.json').read_text()),
            json.loads((ROOT/'Frontend/website/public/.well-known/apple-app-site-association').read_text()),
            plistlib.loads((MOBILE/'ios/Runner/Runner.entitlements').read_bytes()))


def validate_privacy_manifest(document):
    if document.get('NSPrivacyTracking') is not False or document.get('NSPrivacyTrackingDomains') != []:
        raise ValueError('Reviewed App Store source does not use tracking.')
    rows = document.get('NSPrivacyCollectedDataTypes', [])
    expected = {'NSPrivacyCollectedDataType' + name for name in REVIEWED_PRIVACY_TYPES}
    if (not isinstance(rows, list) or len(rows) != len(expected)
            or any(not isinstance(row, dict) for row in rows)
            or {row.get('NSPrivacyCollectedDataType') for row in rows} != expected):
        raise ValueError('Privacy declarations must cover the reviewed account, learning, payment and diagnostic data.')
    for row in rows:
        if (row.get('NSPrivacyCollectedDataTypeLinked') is not True
                or row.get('NSPrivacyCollectedDataTypeTracking') is not False
                or row.get('NSPrivacyCollectedDataTypePurposes') != ['NSPrivacyCollectedDataTypePurposeAppFunctionality']):
            raise ValueError('Reviewed data is linked for app functionality and is not used for tracking.')
    return {'source_privacy_manifest_consistent': True, 'declared_privacy_type_count': len(rows),
            'app_store_privacy_answers_submitted': False}


if __name__ == '__main__':
    print(json.dumps({**validate(*load_source()),
                      **validate_privacy_manifest(plistlib.loads(PRIVACY_PATH.read_bytes()))}, sort_keys=True))
