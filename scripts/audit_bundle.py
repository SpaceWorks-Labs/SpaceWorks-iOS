"""Inspect an actual unsigned Release app; this does not validate signing or store readiness."""
import argparse
import json
from pathlib import Path
import plistlib


BRAND_FONTS = {'Outfit-Variable.ttf', 'Unbounded-Variable.ttf'}
FONT_LICENCES = ['OFL-Outfit.txt', 'OFL-Unbounded.txt']
TELEMETRY_DATA_TYPES = ['NSPrivacyCollectedDataTypeProductInteraction', 'NSPrivacyCollectedDataTypeCrashData',
                        'NSPrivacyCollectedDataTypePerformanceData', 'NSPrivacyCollectedDataTypeOtherDiagnosticData']


def audit(app, brand):
    app = Path(app)
    failures = []
    def check(condition, message):
        if not condition:
            failures.append(message)
    def plist(path):
        try:
            return plistlib.loads(path.read_bytes())
        except (OSError, ValueError, plistlib.InvalidFileException):
            failures.append(f"Missing or invalid property list: {path.relative_to(app)}")
            return {}
    info = plist(app / 'Info.plist')
    check(info.get('CFBundleIdentifier') == brand['ios_bundle_id'], 'Bundle identifier differs from branding')
    check(info.get('CFBundleDisplayName') == brand['app_name'], 'Display name differs from branding')
    check(set(info.get('UIDeviceFamily', [])) == {1, 2}, 'App must include both phone and tablet device families')
    check(info.get('UIApplicationSceneManifest', {}).get('UIApplicationSupportsMultipleScenes') is False,
          'Single-scene credential ownership requires multiple scenes to be explicitly disabled')
    check(info.get('CFBundleShortVersionString') and info.get('CFBundleVersion'), 'Missing version or build number')
    check('NSAppTransportSecurity' not in info, 'Release app contains transport security overrides')
    check(bool(info.get('NSCameraUsageDescription')), 'Missing camera purpose string')
    check(bool(info.get('NSFaceIDUsageDescription')), 'Missing Face ID purpose string for app lock')
    schemes = {scheme for item in info.get('CFBundleURLTypes', []) for scheme in item.get('CFBundleURLSchemes', [])}
    check('spaceworks' in schemes, 'Missing app callback scheme')
    google = brand.get('google_reversed_client_id')
    check(not google or google in schemes, 'Missing configured Google callback scheme')
    required_orientations = {'UIInterfaceOrientationPortrait', 'UIInterfaceOrientationLandscapeLeft', 'UIInterfaceOrientationLandscapeRight'}
    for key in ['UISupportedInterfaceOrientations', 'UISupportedInterfaceOrientations~ipad']:
        check(required_orientations <= set(info.get(key, [])), f'Missing supported orientations in {key}')
    fonts = info.get('UIAppFonts', [])
    check(BRAND_FONTS <= set(fonts), 'Brand fonts are not registered')
    for font in fonts:
        check(Path(font).name == font and (app / font).is_file(), f'Registered font is missing from bundle: {font}')
    check(not any(path.name.lower().startswith('gilroy') for path in app.rglob('*')),
          'Gilroy is not open-licensed and must not be bundled')
    for licence in FONT_LICENCES:
        check((app / licence).is_file(), f'Font licence text is missing from bundle: {licence}')
    # Telemetry: Firebase collection and ad identifiers stay off until consent; no tracking prompt or ad-id SDK.
    for key in ['FIREBASE_ANALYTICS_COLLECTION_ENABLED', 'GOOGLE_ANALYTICS_ADID_COLLECTION_ENABLED', 'GOOGLE_ANALYTICS_IDFV_COLLECTION_ENABLED',
                'GOOGLE_ANALYTICS_DEFAULT_ALLOW_AD_PERSONALIZATION_SIGNALS']:
        check(info.get(key) is False, f'{key} must be false in the shipped Info.plist')
    check(isinstance(info.get('SpaceWorksTelemetry'), dict), 'Generated telemetry configuration is missing')
    check('NSUserTrackingUsageDescription' not in info, 'App must not request App Tracking Transparency')
    check(not any('IdentitySupport' in path.name or path.name.startswith('AdSupport') or 'AdsOnDeviceConversion' in path.name for path in app.rglob('*')),
          'Advertising identifier support is bundled')
    check((app / 'Assets.car').is_file(), 'Compiled asset catalog is missing')
    check(bool(info.get('CFBundleIcons', {}).get('CFBundlePrimaryIcon', {}).get('CFBundleIconName')), 'Primary app icon is missing')
    executable = info.get('CFBundleExecutable', '')
    check(bool(executable) and Path(executable).name == executable and (app / executable).is_file(), 'App executable is missing')
    privacy = plist(app / 'PrivacyInfo.xcprivacy')
    accessed = privacy.get('NSPrivacyAccessedAPITypes', [])
    check(any(item.get('NSPrivacyAccessedAPIType') == 'NSPrivacyAccessedAPICategoryUserDefaults' and 'CA92.1' in item.get('NSPrivacyAccessedAPITypeReasons', []) for item in accessed), 'App privacy manifest lacks its reviewed UserDefaults reason')
    collected = {item.get('NSPrivacyCollectedDataType'): item for item in privacy.get('NSPrivacyCollectedDataTypes', [])}
    for kind in TELEMETRY_DATA_TYPES:
        item = collected.get(kind, {})
        check(item.get('NSPrivacyCollectedDataTypeTracking') is False and item.get('NSPrivacyCollectedDataTypeLinked') is True,
              f'App privacy manifest must declare {kind} as linked, not tracking')
    check(privacy.get('NSPrivacyTracking') is False, 'App privacy manifest must declare no tracking')
    app_localizations = [app / 'en.lproj' / name for name in ['Localizable.strings', 'Localizable.stringsdict']]
    check(any(path.is_file() and path.stat().st_size for path in app_localizations), 'Compiled English app localization is missing')
    check((app / 'en.lproj/InfoPlist.strings').is_file(), 'Localized camera purpose resource is missing')
    api_resources = [path for path in app.rglob('*.bundle') if 'SpaceWorksAPI' in path.name and (path / 'en.lproj/Localizable.strings').is_file()]
    check(bool(api_resources), 'Generated API package English resource bundle is missing')
    manifests = sorted(str(path.relative_to(app)) for path in app.rglob('PrivacyInfo.xcprivacy'))
    result = {'kind': 'unsigned-release-resource-audit', 'bundle_id': info.get('CFBundleIdentifier'), 'version': info.get('CFBundleShortVersionString'), 'build': info.get('CFBundleVersion'), 'device_families': info.get('UIDeviceFamily'), 'scene_manifest': info.get('UIApplicationSceneManifest'), 'privacy_manifests_present': manifests, 'api_resource_bundles': sorted(str(path.relative_to(app)) for path in api_resources), 'failures': failures}
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--brand', type=Path, default=Path('branding/brand.json'))
    parser.add_argument('--output', type=Path, default=Path('validation-bundle.json'))
    args = parser.parse_args()
    result = audit(args.app, json.loads(args.brand.read_text(encoding='utf-8')))
    args.output.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    if result['failures']:
        raise SystemExit('\n'.join(result['failures']))
    print('Unsigned Release bundle resource audit passed; signing and runtime integration remain separate checks.')
