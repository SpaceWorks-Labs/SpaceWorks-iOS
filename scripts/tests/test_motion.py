import copy
import importlib.util
import json
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("motion", ROOT / "scripts/generate_motion.py")
motion = importlib.util.module_from_spec(spec)
spec.loader.exec_module(motion)


class MotionTests(unittest.TestCase):
    def test_generated_native_motion_matches_local_contract(self):
        document = json.loads((ROOT / "tokens/mobile-motion.json").read_text())
        output = motion.render_motion(document)
        self.assertEqual(output, (ROOT / "SpaceWorks/Generated/MobileMotion.swift").read_text())
        self.assertIn(f'static let expand: Double = {document["duration_ms"]["expand"] / 1000:g}', output)

    def test_motion_rejects_logo_animation_and_reduced_motion_delays(self):
        original = json.loads((ROOT / "tokens/mobile-motion.json").read_text())
        for section, key, invalid in [("onboarding", "logo_motion", "scale"), ("onboarding", "blocking_delay_ms", 100),
                                      ("reduce_motion", "opacity_duration_ms", 120), ("reduce_motion", "spatial_transitions", True)]:
            document = copy.deepcopy(original)
            document[section][key] = invalid
            with self.assertRaises(ValueError):
                motion.render_motion(document)

    def test_native_logo_assets_preserve_configured_source_bytes_in_both_appearances(self):
        artwork_spec = importlib.util.spec_from_file_location("artwork", ROOT / "scripts/brand_artwork.py")
        artwork = importlib.util.module_from_spec(artwork_spec)
        artwork_spec.loader.exec_module(artwork)
        brand = json.loads((ROOT / "branding/brand.json").read_text())
        for asset, filename, source in artwork.selected_artwork(ROOT, brand):
            self.assertEqual((ROOT / f"SpaceWorks/Assets.xcassets/{asset}.imageset/{filename}").read_bytes(), source.read_bytes())

    def test_shared_motion_matches_the_design_kit_tokens_where_they_overlap(self):
        document = json.loads((ROOT / "tokens/mobile-motion.json").read_text())
        kit = json.loads((ROOT / "design/tokens/tokens.json").read_text())["motion"]
        self.assertEqual(motion.kit_mismatches(document, kit), [])
        self.assertEqual(document["duration_ms"]["overlay_enter"], 180)
        self.assertEqual(document["easing"]["overlay_enter_cubic_bezier"], [0.16, 1.0, 0.3, 1.0])
        drifted = copy.deepcopy(document)
        drifted["duration_ms"]["expand"] = 200
        self.assertEqual(motion.kit_mismatches(drifted, kit), ["duration_ms.expand"])
