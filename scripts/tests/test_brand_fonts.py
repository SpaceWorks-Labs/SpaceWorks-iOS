import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import struct
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('brand_fonts', ROOT / 'scripts/brand_fonts.py')
FONTS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(FONTS)


def names(data):
    """PostScript (6) and family (1) names straight from the SFNT name table."""
    count = struct.unpack_from('>H', data, 4)[0]
    tables = {struct.unpack_from('>4s', data, 12 + i * 16)[0]: struct.unpack_from('>II', data, 12 + i * 16 + 8) for i in range(count)}
    offset, _ = tables[b'name']
    _, records, storage = struct.unpack_from('>HHH', data, offset)
    found = {}
    for index in range(records):
        platform, _, _, name_id, length, start = struct.unpack_from('>HHHHHH', data, offset + 6 + index * 12)
        raw = data[offset + storage + start:offset + storage + start + length]
        found.setdefault(name_id, raw.decode('utf-16-be') if platform in (0, 3) else raw.decode('latin-1'))
    return found


class BrandFontTests(unittest.TestCase):
    def test_kit_fonts_are_generated_as_native_containers_with_unchanged_names(self):
        output = ROOT / 'SpaceWorks/Generated/Fonts'
        expected = {'Outfit-Variable.ttf': (b'\x00\x01\x00\x00', 'Outfit-Thin'), 'Unbounded-Variable.ttf': (b'\x00\x01\x00\x00', 'Unbounded-Regular')}
        self.assertEqual(set(FONTS.app_fonts()), set(expected))
        for name, (signature, postscript) in expected.items():
            data = (output / name).read_bytes()
            self.assertEqual(data[:4], signature, name)
            self.assertEqual(names(data)[6], postscript, name)

    def test_licences_are_bundled_beside_the_fonts(self):
        for name in FONTS.LICENSES:
            self.assertEqual((ROOT / 'SpaceWorks/Generated/Fonts' / name).read_bytes(), (ROOT / 'design/fonts/LICENSES' / name).read_bytes())

    def test_only_open_licensed_faces_are_shipped(self):
        shipped = {path.name for path in ROOT.joinpath('SpaceWorks').rglob('*') if path.suffix in ('.ttf', '.otf', '.txt')}
        self.assertFalse([name for name in shipped if name.lower().startswith('gilroy')])
        self.assertEqual(set(FONTS.LICENSES), {'OFL-Outfit.txt', 'OFL-Unbounded.txt'})

    def test_both_generated_app_configurations_register_every_bundled_brand_face(self):
        for configuration in ['Debug', 'Release']:
            info = plistlib.loads((ROOT / f'SpaceWorks/Generated/Info-{configuration}.plist').read_bytes())
            self.assertEqual(info['UIAppFonts'], FONTS.app_fonts())
        for name in FONTS.app_fonts():
            self.assertTrue((ROOT / 'SpaceWorks/Generated/Fonts' / name).is_file())

    def test_cached_conversion_is_reused_without_fonttools_and_redone_when_the_kit_changes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            shutil.copytree(ROOT / 'design/fonts', root / 'design/fonts')
            calls = []
            fake = lambda source, target: (calls.append(source.name), Path(target).write_bytes(b'converted'))
            with mock.patch.object(FONTS, '_decompress', side_effect=fake):
                FONTS.generate_fonts(root)
                self.assertEqual(len(calls), 2)
                FONTS.generate_fonts(root)
                self.assertEqual(len(calls), 2, 'Unchanged sources reuse the cached conversion')
                (root / 'design/fonts/Outfit-Variable.woff2').write_bytes(b'new kit release')
                FONTS.generate_fonts(root)
                self.assertEqual(len(calls), 4)
            self.assertEqual(json.loads((root / '.build/font-stamp.json').read_text()).keys(), set(FONTS.app_fonts()))

    def test_missing_converter_explains_the_install(self):
        with tempfile.TemporaryDirectory() as temporary, mock.patch.dict('sys.modules', {'fontTools': None, 'fontTools.ttLib': None}), \
                mock.patch.object(FONTS.shutil, 'which', return_value=None):
            source = Path(temporary) / 'font.woff2'; source.write_bytes(b'wOF2')
            with self.assertRaisesRegex(ValueError, 'brew install fonttools'):
                FONTS._decompress(source, Path(temporary) / 'font.ttf')


if __name__ == '__main__':
    unittest.main()
