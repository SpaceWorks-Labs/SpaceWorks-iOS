import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest

module_path = Path(__file__).resolve().parents[1] / 'audit_bundle.py'
if not module_path.exists():
    module_path = Path(__file__).resolve().parent / 'audit_bundle.py'
spec = importlib.util.spec_from_file_location('audit_bundle', module_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class ReleaseBundleAuditTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.app = Path(self.directory.name) / 'SpaceWorks.app'
        self.app.mkdir()
        self.brand = {'ios_bundle_id': 'org.spaceworks.app', 'app_name': 'Space Works'}
        self.info = {'CFBundleIdentifier': 'org.spaceworks.app', 'CFBundleDisplayName': 'Space Works', 'UIDeviceFamily': [1, 2], 'CFBundleShortVersionString': '0.1.0', 'CFBundleVersion': '1', 'NSCameraUsageDescription': 'Camera use', 'NSFaceIDUsageDescription': 'App lock', 'CFBundleURLTypes': [{'CFBundleURLSchemes': ['spaceworks']}], 'UISupportedInterfaceOrientations': ['UIInterfaceOrientationPortrait', 'UIInterfaceOrientationLandscapeLeft', 'UIInterfaceOrientationLandscapeRight'], 'UISupportedInterfaceOrientations~ipad': ['UIInterfaceOrientationPortrait', 'UIInterfaceOrientationLandscapeLeft', 'UIInterfaceOrientationLandscapeRight'], 'UIAppFonts': ['Outfit-Variable.ttf', 'Unbounded-Variable.ttf'], 'CFBundleExecutable': 'SpaceWorks', 'CFBundleIcons': {'CFBundlePrimaryIcon': {'CFBundleIconName': 'AppIcon'}}}
        self.info['UIApplicationSceneManifest'] = {'UIApplicationSupportsMultipleScenes': False}
        self.info.update({'FIREBASE_ANALYTICS_COLLECTION_ENABLED': False, 'GOOGLE_ANALYTICS_ADID_COLLECTION_ENABLED': False,
                          'GOOGLE_ANALYTICS_IDFV_COLLECTION_ENABLED': False, 'GOOGLE_ANALYTICS_DEFAULT_ALLOW_AD_PERSONALIZATION_SIGNALS': False,
                          'SpaceWorksTelemetry': {'debug_override': False}})
        self.write_info()
        collected = [{'NSPrivacyCollectedDataType': kind, 'NSPrivacyCollectedDataTypeLinked': True, 'NSPrivacyCollectedDataTypeTracking': False} for kind in module.TELEMETRY_DATA_TYPES]
        (self.app / 'PrivacyInfo.xcprivacy').write_bytes(plistlib.dumps({'NSPrivacyTracking': False, 'NSPrivacyCollectedDataTypes': collected, 'NSPrivacyAccessedAPITypes': [{'NSPrivacyAccessedAPIType': 'NSPrivacyAccessedAPICategoryUserDefaults', 'NSPrivacyAccessedAPITypeReasons': ['CA92.1']}]}))
        for name in [*module.BRAND_FONTS, *module.FONT_LICENCES, 'PostHog_PostHog.bundle/PrivacyInfo.xcprivacy', 'Assets.car', 'SpaceWorks', 'en.lproj/InfoPlist.strings', 'en.lproj/Localizable.strings', 'SpaceWorksAPI_SpaceWorksAPI.bundle/en.lproj/Localizable.strings']:
            path = self.app / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'fixture')

    def write_info(self):
        (self.app / 'Info.plist').write_bytes(plistlib.dumps(self.info))

    def test_accepts_packaged_resources_and_records_unsigned_scope(self):
        result = module.audit(self.app, self.brand)
        self.assertEqual(result['failures'], [])
        self.assertEqual(result['kind'], 'unsigned-release-resource-audit')
        self.assertEqual(result['scene_manifest'], {'UIApplicationSupportsMultipleScenes': False})
        self.assertEqual(result['privacy_manifests_present'], ['PostHog_PostHog.bundle/PrivacyInfo.xcprivacy', 'PrivacyInfo.xcprivacy'],
                         'SDK privacy manifests are recorded without being audited as the app manifest')

    def test_refuses_gilroy_ad_identifier_support_and_enabled_firebase_collection(self):
        (self.app / 'Gilroy-Bold.ttf').write_bytes(b'fixture')
        (self.app / 'Frameworks/GoogleAppMeasurementIdentitySupport.framework').mkdir(parents=True)
        self.info['FIREBASE_ANALYTICS_COLLECTION_ENABLED'] = True
        self.info['NSUserTrackingUsageDescription'] = 'Track'
        self.write_info()
        (self.app / 'OFL-Outfit.txt').unlink()
        failures = module.audit(self.app, self.brand)['failures']
        for expected in ['Gilroy is not open-licensed', 'Advertising identifier', 'FIREBASE_ANALYTICS_COLLECTION_ENABLED', 'App Tracking Transparency', 'OFL-Outfit.txt']:
            self.assertTrue(any(expected in failure for failure in failures), expected)

    def test_requires_telemetry_data_types_in_app_privacy_manifest(self):
        (self.app / 'PrivacyInfo.xcprivacy').write_bytes(plistlib.dumps({'NSPrivacyTracking': False, 'NSPrivacyAccessedAPITypes': [{'NSPrivacyAccessedAPIType': 'NSPrivacyAccessedAPICategoryUserDefaults', 'NSPrivacyAccessedAPITypeReasons': ['CA92.1']}]}))
        failures = module.audit(self.app, self.brand)['failures']
        self.assertTrue(any('NSPrivacyCollectedDataTypeCrashData' in failure for failure in failures))

    def test_catches_source_resources_omitted_from_app(self):
        (self.app / 'PrivacyInfo.xcprivacy').unlink()
        (self.app / 'Unbounded-Variable.ttf').unlink()
        (self.app / 'SpaceWorksAPI_SpaceWorksAPI.bundle/en.lproj/Localizable.strings').unlink()
        failures = module.audit(self.app, self.brand)['failures']
        self.assertTrue(any('PrivacyInfo.xcprivacy' in failure for failure in failures))
        self.assertTrue(any('Registered font' in failure for failure in failures))
        self.assertTrue(any('API package' in failure for failure in failures))

    def test_refuses_release_transport_overrides_wrong_brand_and_phone_only(self):
        self.info.update({'NSAppTransportSecurity': {'NSAllowsLocalNetworking': True}, 'CFBundleIdentifier': 'other.app', 'UIDeviceFamily': [1]})
        self.write_info()
        failures = module.audit(self.app, self.brand)['failures']
        self.assertTrue(any('transport security' in failure for failure in failures))
        self.assertTrue(any('identifier' in failure for failure in failures))
        self.assertTrue(any('device families' in failure for failure in failures))

    def test_requires_configured_callback_and_compiled_localization(self):
        self.brand['google_reversed_client_id'] = 'com.googleusercontent.apps.example'
        (self.app / 'en.lproj/Localizable.strings').unlink()
        failures = module.audit(self.app, self.brand)['failures']
        self.assertTrue(any('Google callback' in failure for failure in failures))
        self.assertTrue(any('app localization' in failure for failure in failures))

    def test_requires_explicit_single_scene_credential_contract(self):
        for manifest in [{}, {'UIApplicationSupportsMultipleScenes': True}]:
            self.info['UIApplicationSceneManifest'] = manifest
            self.write_info()
            result = module.audit(self.app, self.brand)
            self.assertEqual(result['scene_manifest'], manifest)
            self.assertTrue(any('Single-scene' in failure for failure in result['failures']))

if __name__ == '__main__':
    unittest.main()
