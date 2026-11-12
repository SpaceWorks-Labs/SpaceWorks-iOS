import hashlib
import importlib.util
import json
import pathlib
import plistlib
import struct
import shutil
import tempfile
from unittest import mock
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("generate", ROOT / "scripts/generate.py")
generator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generator)


class GenerationTests(unittest.TestCase):
    def test_authoritative_contract_is_unchanged_and_staged_for_plugin(self):
        source = (ROOT / "api/openapi.json").read_bytes()
        self.assertEqual(hashlib.sha256(source).hexdigest(), json.loads((ROOT / "api/provenance.json").read_text())["sha256"])
        staged = json.loads((ROOT / "Packages/SpaceWorksAPI/Sources/SpaceWorksAPI/openapi.json").read_bytes())
        expected = json.loads(source)
        for operations in expected["paths"].values():
            for operation in operations.values():
                if not isinstance(operation, dict):
                    continue
                content = operation.get("requestBody", {}).get("content", {})
                if "application/json" in content:
                    operation["requestBody"]["content"] = {"application/json": content["application/json"]}
                elif content and not any("/" in media for media in content) and not operation["requestBody"].get("required", False):
                    del operation["requestBody"]
        self.assertEqual(staged, expected, "Only documented JSON or optional no-body representations may be selected; all models remain unchanged")
        self.assertEqual(len(json.loads(source)["paths"]), 760)

    def test_brand_config_drives_project_display_name_bundle_and_icon(self):
        brand = json.loads((ROOT / "branding/brand.json").read_text())
        config = (ROOT / "Brand.xcconfig").read_text()
        self.assertIn(f"BRAND_BUNDLE_ID = {brand['ios_bundle_id']}", config)
        self.assertIn(f"BRAND_DISPLAY_NAME = {brand['app_name']}", config)
        project = (ROOT / "project.yml").read_text()
        self.assertIn("$(BRAND_BUNDLE_ID)", project)
        self.assertIn("$(BRAND_DISPLAY_NAME)", project)
        self.assertIn("Brand.xcconfig", project)
        self.assertIn("AppIcon", project)
        source = generator.inside(brand["app_icon"])
        self.assertTrue(source.is_file(), "Configured repository-local icon source must exist")
        self.assertTrue((ROOT / "SpaceWorks/Assets.xcassets/AppIcon.appiconset/Contents.json").is_file())
        icon = ROOT / "SpaceWorks/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
        if icon.exists():
            data = icon.read_bytes()
            self.assertEqual(struct.unpack(">II", data[16:24]), (1024, 1024))
            self.assertEqual(data[25], 2, "App Store icon must be opaque RGB")

    def test_every_semantic_role_has_both_appearances(self):
        brand = json.loads((ROOT / "branding/brand.json").read_text())
        tokens = json.loads(generator.inside(brand["theme_tokens"]).read_text())
        for role in tokens["light"]:
            asset = json.loads((ROOT / f"SpaceWorks/Assets.xcassets/{role}.colorset/Contents.json").read_text())
            for index, mode in enumerate(["light", "dark"]):
                rgb = asset["colors"][index]["color"]["components"]
                actual = "#" + "".join(rgb[k][2:] for k in ["red", "green", "blue"])
                self.assertEqual(actual.upper(), tokens[mode][role].upper())
        baseline = json.loads((ROOT / "design/tokens/tokens.json").read_text())
        for mode in ("light", "dark"):
            self.assertTrue(set(baseline[mode]).issubset(tokens[mode]), "Custom themes must retain required semantic roles")

    def test_custom_configuration_generates_custom_artwork_palette_and_renderer_flags(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            for folder in ["scripts", "branding", "tokens", "api", "Fixtures"]:
                shutil.copytree(ROOT / folder, root / folder, ignore=shutil.ignore_patterns("__pycache__"))
            (root / "design/logo").mkdir(parents=True)
            for name in ["lockup-horizontal-one-colour-ink.png", "lockup-horizontal-reversed.png", "lockup-stacked.png", "lockup-stacked-reversed.png", "symbol.png", "symbol-reversed.png"]:
                shutil.copyfile(ROOT / "design/logo" / name, root / "design/logo" / name)
            shutil.copytree(ROOT / "design/fonts", root / "design/fonts")
            for name in ["original/patch.png", "dark/patch.png"]:
                (root / "design/mascot" / name).parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(ROOT / "design/mascot" / name, root / "design/mascot" / name)
            shutil.copytree(ROOT / "SpaceWorks/Generated/Fonts", root / "SpaceWorks/Generated/Fonts")
            (root / ".build").mkdir()
            shutil.copyfile(ROOT / ".build/font-stamp.json", root / ".build/font-stamp.json")
            brand = json.loads((root / "branding/brand.json").read_text())
            brand.update(app_name="Workshop", ios_bundle_id="org.example.workshop", app_icon="branding/custom-icon.svg", theme_tokens="branding/custom-tokens.json", privacy_url="HTTPS://B\u00dcCHER.example/privacy?lang=en#retention")
            (root / brand["app_icon"]).write_text((ROOT / "branding/app-icon.svg").read_text().replace("#FFF4E8", "#FAF2E8"))
            # Distinct bytes prove the selected custom sources actually reach the assets.
            for key, master in [("logo_symbol", "symbol-reversed.png"), ("logo_symbol_reversed", "symbol.png"), ("logo_stacked", "lockup-stacked-reversed.png"), ("logo_stacked_reversed", "lockup-stacked.png")]:
                brand[key] = "branding/" + key + ".png"
                shutil.copyfile(root / "design/logo" / master, root / brand[key])
            tokens = json.loads((ROOT / "design/tokens/tokens.json").read_text())
            tokens["light"]["bg"] = "#FAF2E8"
            (root / brand["theme_tokens"]).write_text(json.dumps(tokens))
            (root / "branding/brand.json").write_text(json.dumps(brand))
            with mock.patch.object(generator, "ROOT", root), mock.patch.object(generator.subprocess, "run") as raster:
                generator.generate(raster=True, environ={})
            swift = (root / "SpaceWorks/Generated/Brand.swift").read_text()
            self.assertIn('appName: String = "Workshop"', swift)
            self.assertIn('privacyURL: String? = "https://xn--bcher-kva.example/privacy?lang=en#retention"', swift)
            self.assertIn('hasCustomWordmark = true', swift)
            self.assertIn('hasCustomStacked = true', swift)
            self.assertIn('hasCustomSymbol = true', swift)
            self.assertEqual((root / "SpaceWorks/Assets.xcassets/BrandSymbol.imageset/light.png").read_bytes(), (root / brand["logo_symbol"]).read_bytes())
            self.assertEqual((root / "SpaceWorks/Assets.xcassets/BrandStacked.imageset/dark.png").read_bytes(), (root / brand["logo_stacked_reversed"]).read_bytes())
            color = json.loads((root / "SpaceWorks/Assets.xcassets/bg.colorset/Contents.json").read_text())["colors"][0]["color"]["components"]
            self.assertEqual([color[key] for key in ["red", "green", "blue"]], ["0xFA", "0xF2", "0xE8"])
            self.assertEqual(raster.call_args.args[0][-1], str(root / brand["app_icon"]))
            self.assertIn("--background-color", raster.call_args.args[0])
            self.assertEqual(raster.call_args.args[0][2], "#FAF2E8")

    def test_invalid_external_link_or_artwork_cannot_partially_rewrite_outputs(self):
        for changes in [{"privacy_url": "https://user:private@example.org/legal"}, {"logo_symbol": "missing.png"},
                        {"app_icon": "missing.svg"}, {"app_icon": "../outside.svg"}, {"theme_tokens": "missing.json"}]:
            with self.subTest(changes=changes), tempfile.TemporaryDirectory() as temporary:
                root = pathlib.Path(temporary).resolve()
                (root / "branding").mkdir(); (root / "scripts").mkdir()
                for name in ["brand_links.py", "brand_artwork.py"]:
                    shutil.copyfile(ROOT / "scripts" / name, root / "scripts" / name)
                brand = json.loads((ROOT / "branding/brand.json").read_text())
                shutil.copytree(ROOT / "design/logo", root / "design/logo")
                for relative in [brand["theme_tokens"], brand["app_icon"], *[value for key, value in brand.items() if key.startswith("logo_") and value is not None]]:
                    destination = root / relative; destination.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(ROOT / relative, destination)
                brand.update(changes)
                (root / "branding/brand.json").write_text(json.dumps(brand))
                output = root / "Brand.xcconfig"; output.write_text("keep existing build")
                with mock.patch.object(generator, "ROOT", root), self.assertRaises(ValueError): generator.generate(raster=False)
                self.assertEqual(output.read_text(), "keep existing build")
                self.assertFalse((root / "SpaceWorks/Generated").exists())

    def test_design_kit_palette_is_the_0_12_0_brand_baseline(self):
        # This immutable upstream check is deliberately separate from configured output.
        baseline = json.loads((ROOT / "design/tokens/tokens.json").read_text())
        self.assertEqual(baseline["light"]["bg"], "#FFF4E8")
        self.assertEqual(baseline["dark"]["bg"], "#000000", "Design-Kit 0.12.0 solid-black dark palette")
        self.assertEqual(baseline["dark"]["surface"], "#0B0B0B")
        self.assertEqual(baseline["light"]["scrim"], "#142C2A")
        self.assertEqual(baseline["dark"]["scrim"], "#000000")

    def test_generated_dark_palette_scrim_and_aurora_card_follow_the_kit(self):
        def components(name):
            colors = json.loads((ROOT / f"SpaceWorks/Assets.xcassets/{name}.colorset/Contents.json").read_text())["colors"]
            return ["#" + "".join(entry["color"]["components"][key][2:] for key in ["red", "green", "blue"]) for entry in colors]
        self.assertEqual(components("bg"), ["#FFF4E8", "#000000"])
        self.assertEqual(components("surface"), ["#F6ECE0", "#0B0B0B"])
        self.assertEqual(components("scrim"), ["#142C2A", "#000000"])
        self.assertEqual(components("card-aurora-background"), ["#FFF4E8", "#142C2A"])
        self.assertEqual(components("card-aurora-label"), ["#006E63", "#DFFF8F"])
        theme = (ROOT / "SpaceWorks/Generated/Theme.swift").read_text()
        self.assertIn('static let swScrim = Color("scrim")', theme)
        self.assertIn('static let swCardAuroraRibbon = Color("card-aurora-ribbon")', theme)

    def test_mascot_ships_the_light_pose_and_the_dark_mode_die_cut_variant(self):
        imageset = ROOT / "SpaceWorks/Assets.xcassets/Patch.imageset"
        self.assertEqual((imageset / "light.png").read_bytes(), (ROOT / "design/mascot/original/patch.png").read_bytes())
        self.assertEqual((imageset / "dark.png").read_bytes(), (ROOT / "design/mascot/dark/patch.png").read_bytes())
        images = json.loads((imageset / "Contents.json").read_text())["images"]
        self.assertEqual(images[1]["appearances"], [{"appearance": "luminosity", "value": "dark"}])

    def test_theme_and_brand_generation_are_deterministic(self):
        paths = [ROOT / "SpaceWorks/Generated/Theme.swift", ROOT / "SpaceWorks/Generated/Brand.swift", ROOT / "Brand.xcconfig"]
        before = [p.read_bytes() for p in paths]
        generator.generate(raster=False, environ={})
        self.assertEqual(before, [p.read_bytes() for p in paths])

    def test_key_ui_text_pairs_meet_contrast_floor(self):
        def luminance(code):
            rgb = [int(code[i:i+2], 16) / 255 for i in [1, 3, 5]]
            linear = [v / 12.92 if v <= .04045 else ((v + .055) / 1.055) ** 2.4 for v in rgb]
            return sum(a * b for a, b in zip(linear, [.2126, .7152, .0722]))
        brand = json.loads((ROOT / "branding/brand.json").read_text())
        tokens = json.loads(generator.inside(brand["theme_tokens"]).read_text())
        for mode in ["light", "dark"]:
            for ink, bg in [("ink", "bg"), ("muted", "bg"), ("ink", "surface"), ("muted", "surface"), ("accent-ink", "surface"), ("on-accent", "accent")]:
                values = sorted([luminance(tokens[mode][ink]), luminance(tokens[mode][bg])])
                self.assertGreaterEqual((values[1] + .05) / (values[0] + .05), 4.5)

    def test_release_has_no_transport_security_exceptions(self):
        debug = plistlib.loads((ROOT / "SpaceWorks/Generated/Info-Debug.plist").read_bytes())
        release = plistlib.loads((ROOT / "SpaceWorks/Generated/Info-Release.plist").read_bytes())
        self.assertEqual(debug["NSAppTransportSecurity"], {"NSAllowsLocalNetworking": True})
        self.assertNotIn("NSAppTransportSecurity", release)
        # Xcode must preserve the explicit generated single-scene manifest.
        for info in [debug, release]:
            self.assertIs(info["UIApplicationSceneManifest"]["UIApplicationSupportsMultipleScenes"], False)
        project = (ROOT / "project.yml").read_text()
        self.assertIn("        INFOPLIST_KEY_UIApplicationSceneManifest_Generation: NO\n", project)
        self.assertNotIn("INFOPLIST_KEY_UIApplicationSceneManifest_Generation: YES", project)

    def test_simulator_keychain_identity_never_changes_physical_entitlements(self):
        simulator = plistlib.loads((ROOT / "SpaceWorks/Generated/Simulator.entitlements").read_bytes())
        brand = json.loads((ROOT / "branding/brand.json").read_text())
        identity = "LOCALCI." + brand["ios_bundle_id"]
        self.assertEqual(simulator["application-identifier"], identity)
        self.assertEqual(simulator["keychain-access-groups"], [identity])
        for configuration in ("Debug", "Release"):
            real = plistlib.loads((ROOT / f"SpaceWorks/Generated/Attestation-{configuration}.entitlements").read_bytes())
            self.assertNotIn("application-identifier", real)
            self.assertNotIn("keychain-access-groups", real)

    def test_telemetry_block_is_optional_public_and_env_overridable(self):
        brand = {"telemetry": {"sentry_dsn": None, "sentry_traces_sample_rate": 0.1, "posthog_host": "https://eu.i.posthog.com"}}
        self.assertEqual(generator.telemetry_config(brand, {}), {"sentry_traces_sample_rate": 0.1, "posthog_host": "https://eu.i.posthog.com", "debug_override": False})
        self.assertEqual(generator.telemetry_config({}, {}), {"debug_override": False})
        env = {"SPACEWORKS_SENTRY_DSN": "https://0123456789abcdef0123456789abcdef@o1.ingest.sentry.io/42",
               "SPACEWORKS_POSTHOG_API_KEY": "phc_testkey1234567890", "SPACEWORKS_CLARITY_PROJECT_ID": "abc123xyz",
               "SPACEWORKS_SENTRY_TRACES_SAMPLE_RATE": "0.25", "SPACEWORKS_TELEMETRY_DEBUG": "1"}
        config = generator.telemetry_config(brand, env)
        self.assertEqual(config["sentry_dsn"], env["SPACEWORKS_SENTRY_DSN"])
        self.assertEqual(config["posthog_api_key"], "phc_testkey1234567890")
        self.assertEqual(config["clarity_project_id"], "abc123xyz")
        self.assertEqual(config["sentry_traces_sample_rate"], 0.25)
        self.assertIs(config["debug_override"], True)
        for invalid in [{"unknown": 1}, {"sentry_dsn": "https://key:secret@o1.ingest.sentry.io/42"}, {"posthog_api_key": "phx_personalsecretkey"},
                        {"posthog_host": "http://eu.i.posthog.com"}, {"sentry_traces_sample_rate": 2}, {"sentry_traces_sample_rate": True}]:
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                generator.telemetry_config({"telemetry": invalid}, {})

    def test_info_plist_carries_telemetry_and_disables_firebase_collection_and_ad_ids(self):
        for configuration in ("Debug", "Release"):
            info = plistlib.loads((ROOT / f"SpaceWorks/Generated/Info-{configuration}.plist").read_bytes())
            self.assertIn("debug_override", info["SpaceWorksTelemetry"])
            for key in ["FIREBASE_ANALYTICS_COLLECTION_ENABLED", "GOOGLE_ANALYTICS_ADID_COLLECTION_ENABLED", "GOOGLE_ANALYTICS_IDFV_COLLECTION_ENABLED",
                        "GOOGLE_ANALYTICS_DEFAULT_ALLOW_AD_PERSONALIZATION_SIGNALS", "FirebaseAutomaticScreenReportingEnabled"]:
                self.assertIs(info[key], False, key)
            self.assertNotIn("NSUserTrackingUsageDescription", info, "No App Tracking Transparency prompt")
        self.assertIn("SpaceWorks/GoogleService-Info.plist", (ROOT / ".gitignore").read_text().splitlines())


if __name__ == "__main__":
    unittest.main()
