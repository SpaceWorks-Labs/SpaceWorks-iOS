"""Generate native branding and light/dark assets, and stage the authoritative API contract.

Only Python's standard library plus the build-time rsvg-convert executable are required.
Run before xcodegen generate, and again automatically before app builds.
"""
import argparse
import hashlib
import importlib.util
import json
import os
import pathlib
import plistlib
import re
import shutil
import subprocess
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parents[1]


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(value, encoding="utf-8")


def inside(relative):
    path = (ROOT / relative).resolve()
    if not path.is_relative_to(ROOT):
        raise ValueError("Brand assets must stay inside the repository")
    return path


TELEMETRY_KEYS = {
    "sentry_dsn": r"https://[0-9a-f]{16,64}@[A-Za-z0-9.-]+(:[0-9]{1,5})?/[0-9]{1,20}",
    "sentry_environment": r"[A-Za-z0-9_.-]{1,64}",
    "sentry_traces_sample_rate": None,
    "posthog_api_key": r"phc_[A-Za-z0-9]{10,64}",
    "posthog_host": r"https://[A-Za-z0-9.-]+(:[0-9]{1,5})?",
    "clarity_project_id": r"[a-z0-9]{6,32}",
}


def telemetry_config(brand, environ):
    """Public provider identifiers from brand.json, each overridable by SPACEWORKS_<KEY> at build time."""
    block = brand.get("telemetry") or {}
    if not isinstance(block, dict) or set(block) - set(TELEMETRY_KEYS):
        raise ValueError("telemetry accepts only " + ", ".join(TELEMETRY_KEYS))
    config = {}
    for key, pattern in TELEMETRY_KEYS.items():
        value = environ.get("SPACEWORKS_" + key.upper()) or block.get(key)
        if value is None:
            continue
        if pattern is None:
            try:
                value = float(value)
            except (TypeError, ValueError):
                raise ValueError(f"Invalid telemetry.{key}") from None
            if isinstance(block.get(key), bool) or not 0 <= value <= 1:
                raise ValueError(f"Invalid telemetry.{key}")
        elif not isinstance(value, str) or not re.fullmatch(pattern, value):
            # Secret-bearing values (Sentry auth tokens, PostHog personal keys) never match.
            raise ValueError(f"Invalid telemetry.{key}")
        config[key] = value
    config["debug_override"] = environ.get("SPACEWORKS_TELEMETRY_DEBUG", "").lower() in ("1", "true")
    return config


def color_entry(color, mode):
    entry = {"idiom": "universal", "color": {"color-space": "srgb", "components": {
        "red": "0x" + color[1:3], "green": "0x" + color[3:5], "blue": "0x" + color[5:7], "alpha": "1.000"}}}
    if mode == "dark":
        entry["appearances"] = [{"appearance": "luminosity", "value": "dark"}]
    return entry


def generate(raster=True, environ=None):
    environ = os.environ if environ is None else environ
    brand = json.loads((ROOT / "branding/brand.json").read_text())
    telemetry = telemetry_config(brand, environ)
    links_spec = importlib.util.spec_from_file_location("spaceworks_brand_links", ROOT / "scripts/brand_links.py")
    links_module = importlib.util.module_from_spec(links_spec)
    links_spec.loader.exec_module(links_module)
    # Validate destinations before writing any generated output. Only these optional
    # external links are normalized; the deployment origin has its own strict policy.
    brand.update(links_module.validated_links(brand))
    artwork_spec = importlib.util.spec_from_file_location("spaceworks_artwork", ROOT / "scripts/brand_artwork.py")
    artwork_module = importlib.util.module_from_spec(artwork_spec)
    artwork_spec.loader.exec_module(artwork_module)
    selected_artwork = artwork_module.selected_artwork(ROOT, brand)
    artwork_flags = artwork_module.artwork_flags(brand)
    icon_source = inside(brand["app_icon"])
    theme_source = inside(brand["theme_tokens"])
    if not icon_source.is_file() or icon_source.suffix.lower() != ".svg":
        raise ValueError("app_icon must name a repository-local SVG file")
    try:
        if ET.parse(icon_source).getroot().tag.split("}")[-1] != "svg":
            raise ValueError("app_icon must contain SVG artwork")
    except (ET.ParseError, OSError) as error:
        raise ValueError("app_icon must contain valid SVG artwork") from error
    if not theme_source.is_file():
        raise ValueError("theme_tokens must name a repository-local JSON file")
    tokens = json.loads(theme_source.read_text(encoding="utf-8"))
    if not isinstance(tokens, dict) or any(not isinstance(tokens.get(mode), dict) or not tokens[mode] for mode in ["light", "dark"]):
        raise ValueError("theme_tokens requires nonempty light and dark semantic roles")
    if set(tokens["light"]) != set(tokens["dark"]):
        raise ValueError("Light and dark semantic roles must match")
    for mode in ["light", "dark"]:
        for role, color in tokens[mode].items():
            if not isinstance(color, str) or not re.fullmatch(r"#[0-9A-Fa-f]{6}", color):
                raise ValueError(f"Invalid token {mode}.{role}")
    # Optional Design-Kit card looks (cards.aurora): the membership card and event ticket.
    cards = {}
    for card, look in (tokens.get("cards") or {}).items():
        if not isinstance(look, dict) or not isinstance(look.get("light"), dict) or look.get("light", {}).keys() != (look.get("dark") or {}).keys():
            raise ValueError(f"Card {card} requires matching light and dark roles")
        for mode in ["light", "dark"]:
            for role, color in look[mode].items():
                if not isinstance(color, str) or not re.fullmatch(r"#[0-9A-Fa-f]{6}", color):
                    raise ValueError(f"Invalid token cards.{card}.{mode}.{role}")
        cards[card] = look
    for key in ["ios_bundle_id", "ios_team_id"]:
        if not re.fullmatch(r"[A-Za-z0-9.-]*", brand[key]):
            raise ValueError(f"Invalid {key}")
    if not brand["ios_bundle_id"] or any(ord(c) < 32 for c in brand["app_name"]) or any(c in brand["app_name"] for c in '$#;\\') or "//" in brand["app_name"]:
        raise ValueError("Invalid app name or bundle ID")
    if brand["server_url"] is not None:
        from urllib.parse import urlsplit
        u = urlsplit(brand["server_url"])
        if u.scheme != "https" or not u.hostname or u.username or u.password or u.path not in ["", "/"] or u.query or u.fragment:
            raise ValueError("Locked server_url must be an HTTPS origin")
    write(ROOT / "Brand.xcconfig", "// Generated from branding/brand.json.\n"
          + f"BRAND_BUNDLE_ID = {brand['ios_bundle_id']}\n"
          + f"BRAND_DISPLAY_NAME = {brand['app_name']}\n"
          + f"BRAND_TEAM_ID = {brand['ios_team_id']}\n")
    fonts_spec = importlib.util.spec_from_file_location("spaceworks_fonts", ROOT / "scripts/brand_fonts.py")
    fonts_module = importlib.util.module_from_spec(fonts_spec)
    fonts_spec.loader.exec_module(fonts_module)
    capability_spec = importlib.util.spec_from_file_location("spaceworks_capabilities", ROOT / "scripts/mobile_capabilities.py")
    capability_module = importlib.util.module_from_spec(capability_spec)
    capability_spec.loader.exec_module(capability_module)
    deployment = capability_module.capabilities(brand, "Release")
    push_configured = "aps-environment" in deployment
    swift_literal = lambda value: "nil" if value is None else json.dumps(value, ensure_ascii=False)
    write(ROOT / "SpaceWorks/Generated/Brand.swift", "// Generated. Do not edit.\nimport Foundation\nenum Brand {\n"
          + "\n".join(f"    static let {name}: String{'?' if key in ['server_url', 'support_url', 'privacy_url'] else ''} = {swift_literal(brand[key])}"
                      for name, key in [("appName", "app_name"), ("bundleID", "ios_bundle_id"), ("serverURL", "server_url"), ("supportURL", "support_url"), ("privacyURL", "privacy_url")])
          + "\n" + "\n".join(f"    static let {name} = {str(value).lower()}" for name, value in artwork_flags.items())
          + "\n    static let pushConfigured = " + str(push_configured).lower()
          + "\n    #if DEBUG\n    static let pushEnvironment = \"development\"\n    #else\n    static let pushEnvironment = \"production\"\n    #endif\n"
          + "    static let associatedDomains: [String] = " + json.dumps(brand.get("associated_domains", []))
          + "\n}\n")
    for mode in ["Debug", "Release"]:
        info = {"CFBundleDisplayName": brand["app_name"], "UILaunchScreen": {}, "UIApplicationSceneManifest": {"UIApplicationSupportsMultipleScenes": False}}
        info["UISupportedInterfaceOrientations"] = ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"]
        info["UISupportedInterfaceOrientations~ipad"] = info["UISupportedInterfaceOrientations"] + ["UIInterfaceOrientationPortraitUpsideDown"]
        info["UIAppFonts"] = fonts_module.app_fonts()
        # Telemetry: public identifiers only; every provider stays off until consent (docs/TELEMETRY.md).
        info["SpaceWorksTelemetry"] = telemetry
        info["FIREBASE_ANALYTICS_COLLECTION_ENABLED"] = False
        info["GOOGLE_ANALYTICS_ADID_COLLECTION_ENABLED"] = False
        info["GOOGLE_ANALYTICS_IDFV_COLLECTION_ENABLED"] = False
        info["GOOGLE_ANALYTICS_DEFAULT_ALLOW_AD_PERSONALIZATION_SIGNALS"] = False
        info["FirebaseAutomaticScreenReportingEnabled"] = False
        info["FirebaseAppDelegateProxyEnabled"] = False
        info["NSCameraUsageDescription"] = "Scan member and event codes or photograph handover evidence when you choose to."
        info["NSFaceIDUsageDescription"] = "Unlock your makerspace account when you turn on app lock."
        schemes = ["spaceworks"]
        google_scheme = brand.get("google_reversed_client_id")
        if google_scheme is not None:
            if not re.fullmatch(r"com\.googleusercontent\.apps\.[A-Za-z0-9.-]+", google_scheme):
                raise ValueError("Invalid Google reversed client ID")
            schemes.append(google_scheme)
        info["CFBundleURLTypes"] = [{"CFBundleURLName": brand["ios_bundle_id"], "CFBundleURLSchemes": schemes}]
        if mode == "Debug":
            info["NSAppTransportSecurity"] = {"NSAllowsLocalNetworking": True}
        target = ROOT / f"SpaceWorks/Generated/Info-{mode}.plist"
        target.write_bytes(plistlib.dumps(info))
        entitlements = {
            "com.apple.developer.devicecheck.appattest-environment": "development" if mode == "Debug" else "production",
            "com.apple.developer.applesignin": ["Default"]}
        entitlements.update(capability_module.capabilities(brand, mode))
        (ROOT / f"SpaceWorks/Generated/Attestation-{mode}.entitlements").write_bytes(plistlib.dumps(entitlements))
    # Simulator Keychain requires an effective signed app identity, even without an owner team.
    # This local-only identity is never used in a physical-device build or release archive.
    simulator_identity = "LOCALCI." + brand["ios_bundle_id"]
    (ROOT / "SpaceWorks/Generated/Simulator.entitlements").write_bytes(plistlib.dumps({
        "application-identifier": simulator_identity,
        "keychain-access-groups": [simulator_identity], "get-task-allow": True}))
    # Theme input was parsed and validated before generated output writes.
    if set(tokens["light"]) != set(tokens["dark"]):
        raise ValueError("Light and dark semantic roles must match")
    assets = ROOT / "SpaceWorks/Assets.xcassets"
    write(assets / "Contents.json", json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2))
    declarations = []
    for role, light in tokens["light"].items():
        name = "sw" + "".join(w.title() for w in role.split("-"))
        declarations.append(f'    static let {name} = Color("{role}")')
        colors = [color_entry(tokens[mode][role], mode) for mode in ["light", "dark"]]
        write(assets / f"{role}.colorset/Contents.json", json.dumps({"colors": colors, "info": {"author": "xcode", "version": 1}}, indent=2))
    for card, look in cards.items():
        for role in look["light"]:
            name = f"card-{card}-{role}"
            declarations.append(f'    static let {"sw" + "".join(w.title() for w in name.split("-"))} = Color("{name}")')
            write(assets / f"{name}.colorset/Contents.json", json.dumps({"colors": [color_entry(look[mode][role], mode) for mode in ["light", "dark"]],
                "info": {"author": "xcode", "version": 1}}, indent=2))
    write(ROOT / "SpaceWorks/Generated/Theme.swift", "// Generated from semantic tokens, both appearances.\nimport SwiftUI\nextension Color {\n" + "\n".join(declarations) + "\n}\n")
    fonts_module.generate_fonts(ROOT)
    # Patch, the Design-Kit mascot: the sheet-size hero pose, with the die-cut dark/ variant for dark mode.
    mascot = assets / "Patch.imageset"
    mascot.mkdir(parents=True, exist_ok=True)
    for name, source in [("light.png", "design/mascot/original/patch.png"), ("dark.png", "design/mascot/dark/patch.png")]:
        shutil.copyfile(inside(source), mascot / name)
    write(mascot / "Contents.json", json.dumps({"images": [{"idiom": "universal", "filename": "light.png", "scale": "3x"},
        {"idiom": "universal", "filename": "dark.png", "scale": "3x", "appearances": [{"appearance": "luminosity", "value": "dark"}]}],
        "info": {"author": "xcode", "version": 1}}))
    motion_spec = importlib.util.spec_from_file_location("spaceworks_motion", ROOT / "scripts/generate_motion.py")
    motion_module = importlib.util.module_from_spec(motion_spec)
    motion_spec.loader.exec_module(motion_module)
    motion_module.generate_motion(ROOT)
    fixture_spec = importlib.util.spec_from_file_location("spaceworks_fixtures", ROOT / "scripts/generate_member_fixtures.py")
    fixture_module = importlib.util.module_from_spec(fixture_spec)
    fixture_spec.loader.exec_module(fixture_module)
    fixture_module.generate_member_fixtures(ROOT)
    staff_spec = importlib.util.spec_from_file_location("spaceworks_staff_fixtures", ROOT / "scripts/generate_staff_fixtures.py")
    staff_module = importlib.util.module_from_spec(staff_spec)
    staff_spec.loader.exec_module(staff_module)
    staff_module.generate_staff_fixtures(ROOT)
    account_spec = importlib.util.spec_from_file_location("spaceworks_account_fixtures", ROOT / "scripts/generate_account_fixtures.py")
    account_module = importlib.util.module_from_spec(account_spec)
    account_spec.loader.exec_module(account_module)
    account_module.generate_account_fixtures(ROOT)
    for asset in ["Wordmark", "BrandStacked", "BrandSymbol"]:
        target = assets / f"{asset}.imageset"
        target.mkdir(parents=True, exist_ok=True)
        for selected_asset, name, master in selected_artwork:
            if selected_asset == asset:
                shutil.copyfile(master, target / name)
        write(target / "Contents.json", json.dumps({"images": [{"idiom": "universal", "filename": "light.png"},
            {"idiom": "universal", "filename": "dark.png", "appearances": [{"appearance": "luminosity", "value": "dark"}]}],
            "info": {"author": "xcode", "version": 1}}))
    icon = assets / "AppIcon.appiconset"
    icon.mkdir(parents=True, exist_ok=True)
    if raster:
        source = inside(brand["app_icon"])
        rect = ET.parse(source).getroot().find("{http://www.w3.org/2000/svg}rect")
        background = rect.get("fill") if rect is not None else None
        if not background or not re.fullmatch(r"#[0-9A-Fa-f]{6}", background):
            raise ValueError("App icon must define its opaque background as a top-level rect fill")
        subprocess.run(["rsvg-convert", "--background-color", background, "-w", "1024", "-h", "1024", "-o", str(icon / "AppIcon.png"), str(source)], check=True)
    write(icon / "Contents.json", json.dumps({"images": [{"filename": "AppIcon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}], "info": {"author": "xcode", "version": 1}}, indent=2))
    schema = ROOT / "api/openapi.json"
    expected = json.loads((ROOT / "api/provenance.json").read_text())["sha256"]
    if hashlib.sha256(schema.read_bytes()).hexdigest() != expected:
        raise ValueError("API contract hash differs from its recorded provenance")
    document = project_contract(json.loads(schema.read_bytes()), selected_operations())
    write(ROOT / "Packages/SpaceWorksAPI/Sources/SpaceWorksAPI/openapi.json", json.dumps(document, ensure_ascii=False, indent=2) + "\n")


GENERATOR_CONFIG = "Packages/SpaceWorksAPI/Sources/SpaceWorksAPI/openapi-generator-config.yaml"
SCHEMA_REF = "#/components/schemas/"


def selected_operations():
    """The generator's operation allowlist (`filter.operations`), read without a YAML dependency."""
    lines = (ROOT / GENERATOR_CONFIG).read_text(encoding="utf-8").splitlines()
    return {match.group(1) for line in lines if (match := re.fullmatch(r"\s+- (api_v1_[a-z0-9_]+)\s*", line))}


def schema_refs(node):
    if isinstance(node, dict):
        ref = node.get("$ref")
        if isinstance(ref, str) and ref.startswith(SCHEMA_REF):
            yield ref[len(SCHEMA_REF):]
        for value in node.values():
            yield from schema_refs(value)
    elif isinstance(node, list):
        for value in node:
            yield from schema_refs(value)


def closure(schemas, roots):
    seen, pending = set(), list(roots)
    while pending:
        name = pending.pop()
        if name in seen or name not in schemas:
            continue
        seen.add(name)
        pending.extend(schema_refs(schemas[name]))
    return seen


def string_enum(node):
    values = node.get("enum") if isinstance(node, dict) else None
    if not isinstance(values, list) or node.get("type", "string") != "string":
        return False
    texts = [value for value in values if value is not None]
    return bool(texts) and all(isinstance(value, str) for value in texts)


def open_enums(node, opened):
    """Drop closed string `enum` lists and collapse unions of opened enums to one string."""
    if isinstance(node, list):
        for value in node:
            open_enums(value, opened)
        return
    if not isinstance(node, dict):
        return
    if string_enum(node):
        nullable = None in node["enum"] or node.get("nullable") is True
        del node["enum"]
        node["type"] = "string"
        if nullable:
            node["nullable"] = True
    for union in ("oneOf", "anyOf"):
        branches = node.get(union)
        if isinstance(branches, list) and branches and all(
                isinstance(branch, dict) and set(branch) == {"$ref"} and branch["$ref"][len(SCHEMA_REF):] in opened
                for branch in branches) and any(opened[branch["$ref"][len(SCHEMA_REF):]] is not None for branch in branches):
            del node[union]
            node["type"] = "string"
            if any(opened[branch["$ref"][len(SCHEMA_REF):]] is not False for branch in branches):
                node["nullable"] = True
    for value in node.values():
        open_enums(value, opened)


def project_contract(document, operations):
    """Mechanical build projection of the authoritative schema; the source file stays untouched.

    1. Keep only the selected operations and the schemas they reach (the generator's own filter
       does the same; pruning keeps the 17 MB contract fast to parse at build time).
    2. Apple's generator models any multipart root component as a multipart enum. Select the
       documented JSON request representation, or the no-body form of an optional body whose
       content declares schema keys instead of media types.
    3. PRD §7: treat an unknown enum value as "other" instead of failing to decode. Apple's
       generator emits closed `@frozen` enums, so every string enum reachable from a selected
       operation's responses is opened to a plain string; the app maps the values it acts on in
       hand-written wrappers. Request-only enums stay closed.
    """
    paths = {}
    for path, operations_at in document["paths"].items():
        kept = {method: operation for method, operation in operations_at.items()
                if isinstance(operation, dict) and operation.get("operationId") in operations}
        if kept:
            shared = {key: value for key, value in operations_at.items() if key == "parameters"}
            paths[path] = {**shared, **kept}
    missing = operations - {op["operationId"] for ops in paths.values() for op in ops.values() if isinstance(op, dict) and "operationId" in op}
    if missing:
        raise ValueError(f"Selected operations are absent from the contract: {sorted(missing)}")
    document["paths"] = paths
    for operations_at in paths.values():
        for operation in operations_at.values():
            if not isinstance(operation, dict) or "requestBody" not in operation:
                continue
            content = operation["requestBody"].get("content", {})
            if "application/json" in content:
                operation["requestBody"]["content"] = {"application/json": content["application/json"]}
            elif content and not any("/" in media for media in content) and not operation["requestBody"].get("required", False):
                del operation["requestBody"]
    schemas = document["components"]["schemas"]
    document["components"]["schemas"] = {name: schemas[name] for name in sorted(closure(schemas, schema_refs(paths)))}
    schemas = document["components"]["schemas"]
    responses = [operation.get("responses", {}) for ops in paths.values() for operation in ops.values() if isinstance(operation, dict)]
    reachable = closure(schemas, schema_refs(responses))
    # name -> nullable (True/False); a null-only enum (`NullEnum`) maps to None: it only marks a union nullable.
    opened = {name: None in schemas[name]["enum"] for name in reachable if string_enum(schemas[name])}
    opened.update({name: None for name in reachable if schemas[name].get("enum") == [None]})
    for name in sorted(reachable):
        open_enums(schemas[name], opened)
    for response in responses:
        open_enums(response, opened)
    return document


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--no-raster", action="store_true", help="Only for generator tests on hosts without librsvg")
    generate(not parser.parse_args().no_raster)
