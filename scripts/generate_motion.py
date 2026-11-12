"""Generate native motion only from the shared mobile repository contract."""
import json
import pathlib
import re


def kit_mismatches(document, kit_motion):
    """Values the mobile contract shares with the Design-Kit `motion` tokens must stay equal to them."""
    def parse(value):
        if value.startswith("cubic-bezier("):
            return [float(part) for part in value[13:-1].split(",")]
        return float(re.sub(r"(ms|px|%)$", "", value))
    kit = {"duration_ms": kit_motion["duration"], "easing": kit_motion["easing"], "distance": kit_motion["distance"]}
    return [f"{section}.{key}" for section, mapping in document["kit_tokens"].items() for key, token in mapping.items()
            if parse(kit[section][token]) != document[section][key]]


def render_motion(document):
    durations = document["duration_ms"]
    if document["onboarding"]["logo_motion"] != "none" or document["onboarding"]["blocking_delay_ms"] != 0:
        raise ValueError("The master stays static and onboarding never blocks interaction")
    reduced = document["reduce_motion"]
    if reduced["spatial_transitions"] or reduced["decorative_repeats"] or reduced["blocking_delay_ms"] or reduced["opacity_duration_ms"]:
        raise ValueError("Reduced motion must remove all custom movement and delays")
    if any(not isinstance(value, int) or value < 0 or value > 1000 for value in durations.values()):
        raise ValueError("Invalid duration")
    curves = document["easing"]
    for curve in curves.values():
        if len(curve) != 4 or any(not isinstance(value, (int, float)) or not 0 <= value <= 1 for value in curve):
            raise ValueError("Invalid motion curve")
    distance = document["distance"]
    if not 0 <= distance["enter_y_pt"] <= 24 or not 0.9 <= distance["pop_scale"] <= 1:
        raise ValueError("Invalid motion distance")
    constants = "\n".join(f"    static let {name}: Double = {durations[key] / 1000:g}" for name, key in [
        ("color", "color"), ("expand", "expand"), ("overlayEnter", "overlay_enter"), ("overlayExit", "overlay_exit"), ("routeSettle", "route_settle")])
    timing = lambda key, duration: "Animation.timingCurve(" + ", ".join(f"{value:g}" for value in curves[key]) + f", duration: {duration})"
    return ("// Generated from tokens/mobile-motion.json. Do not edit.\nimport SwiftUI\nenum MobileMotion {\n"
            + constants
            + f"\n    static let enterY: CGFloat = {distance['enter_y_pt']:g}\n    static let popScale: CGFloat = {distance['pop_scale']:g}"
            + "\n    static let expandAnimation = " + timing("standard_cubic_bezier", "expand")
            + "\n    static let enterAnimation = " + timing("overlay_enter_cubic_bezier", "routeSettle")
            + "\n    static let exitAnimation = " + timing("overlay_exit_cubic_bezier", "overlayExit") + "\n}\n")


def generate_motion(root):
    root = pathlib.Path(root)
    document = json.loads((root / "tokens/mobile-motion.json").read_text())
    kit = root / "design/tokens/tokens.json"
    if kit.is_file():
        mismatches = kit_mismatches(document, json.loads(kit.read_text())["motion"])
        if mismatches:
            raise ValueError("Mobile motion differs from the Design-Kit tokens: " + ", ".join(mismatches))
    (root / "SpaceWorks/Generated/MobileMotion.swift").write_text(render_motion(document), encoding="utf-8")
