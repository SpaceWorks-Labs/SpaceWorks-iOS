"""Convert the Design-Kit web fonts into native containers at generation time.

The kit ships WOFF2 only. WOFF2 is a compressed container; decompressing it restores the font's
own SFNT tables without renaming or redrawing anything. fontTools with Brotli does the work:
either importable from this Python, or the `fonttools` command (Homebrew: `brew install fonttools`,
or `python3 -m pip install fonttools brotli`). Outputs are cached by source hash, so an Xcode
build phase whose Python lacks fontTools reuses fonts converted earlier by `scripts/generate.py`.
"""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

# Native file name and its kit source. Open-licensed (OFL) faces only: the kit's Gilroy files are
# never converted or bundled (owner decision 2026-11-13); Outfit 800/300 carries display headings.
FACES = [
    ("Outfit-Variable.ttf", "Outfit-Variable.woff2"),
    ("Unbounded-Variable.ttf", "Unbounded-Variable.woff2"),
]
LICENSES = ["OFL-Outfit.txt", "OFL-Unbounded.txt"]
INSTALL = "Converting the Design-Kit WOFF2 fonts needs fontTools with Brotli: brew install fonttools (or python3 -m pip install fonttools brotli)"


def app_fonts():
    return [native for native, _ in FACES]


def _decompress(source, target):
    try:
        from fontTools.ttLib import woff2
        import brotli  # noqa: F401  (fontTools needs it for WOFF2)
    except ImportError:
        tool = shutil.which("fonttools")
        if tool is None:
            raise ValueError(INSTALL)
        result = subprocess.run([tool, "ttLib.woff2", "decompress", "-o", str(target), str(source)], capture_output=True, text=True)
        if result.returncode:
            raise ValueError(f"Could not convert {source.name}: {result.stderr.strip()}")
    else:
        woff2.decompress(str(source), str(target))


def generate_fonts(root):
    root = Path(root)
    kit = root / "design/fonts"
    output = root / "SpaceWorks/Generated/Fonts"
    stamp_path = root / ".build/font-stamp.json"
    sources = {native: kit / source for native, source in FACES}
    missing = [str(path.relative_to(root)) for path in [*sources.values(), *(kit / "LICENSES" / name for name in LICENSES)] if not path.is_file()]
    if missing:
        raise ValueError("Design-Kit fonts are missing: " + ", ".join(missing))
    stamp = {native: hashlib.sha256(path.read_bytes()).hexdigest() for native, path in sources.items()}
    try:
        current = json.loads(stamp_path.read_text())
    except (OSError, ValueError):
        current = None
    output.mkdir(parents=True, exist_ok=True)
    for stale in output.iterdir():  # e.g. faces a previous kit or rule shipped
        if stale.name not in sources and stale.name not in LICENSES:
            stale.unlink()
    if current != stamp or any(not (output / native).is_file() for native in sources):
        for native, source in sources.items():
            _decompress(source, output / native)
        stamp_path.parent.mkdir(parents=True, exist_ok=True)
        stamp_path.write_text(json.dumps(stamp, indent=2, sort_keys=True) + "\n")
    for name in LICENSES:
        shutil.copyfile(kit / "LICENSES" / name, output / name)
    return app_fonts()
