# tests/test_data_formats.mojo — resources.minitoml round-trip + corruption
# handling. Run: pixi run mojo -I . tests/test_data_formats.mojo
#
# No disk IO here on purpose: the config/sidecar call paths are tested in
# test_config.mojo / test_offline_library.mojo; this file pins the parser.

from std.collections import Dict, List
from std.testing import assert_equal, assert_raises, assert_true, assert_false

from resources.minitoml import TomlDoc, TomlSection, parse_toml, utf8_string
from resources.minitoml import _toml_string


def _empty_list() -> List[String]:
    return List[String]()


def test_utf8_decode() raises:
    """Multi-byte UTF-8 decodes to real codepoints (byte-chr broke them)."""
    var bytes = List[UInt8]()
    bytes.append(0xC3)  # "ö" = U+00F6
    bytes.append(0xB6)
    bytes.append(65)
    var text = utf8_string(bytes)
    assert_equal(text, "öA")
    assert_equal(text.count_codepoints(), 2)


def test_utf8_decode_4byte() raises:
    """Astral plane codepoints survive."""
    var bytes = List[UInt8]()
    bytes.append(0xF0)
    bytes.append(0x9F)
    bytes.append(0x98)
    bytes.append(0x80)  # U+1F600
    bytes.append(65)
    var text = utf8_string(bytes)
    assert_equal(text.count_codepoints(), 2)


def test_utf8_decode_invalid_skipped() raises:
    """Truncated/stray bytes are skipped, not crashes."""
    var bytes = List[UInt8]()
    bytes.append(0xC3)  # dangling lead byte
    bytes.append(65)
    assert_equal(utf8_string(bytes), "A")


def test_scalars() raises:
    var text = String()
    text += "# comment line\n"
    text += 'client_identifier = "abc-123"\n'
    text += "font_multiplier = 1.5   # scaled type #2\n"
    text += "count = 42\n"
    text += "flag = true\n"
    text += "off = false\n"
    var tables = parse_toml(text)
    var root = tables.get("", TomlSection())
    assert_equal(root.strings.get("client_identifier", "MISSING"), "abc-123")
    assert_equal(root.ints.get("count", 0), 42)
    assert_equal(root.floats.get("font_multiplier", 0.0), 1.5)
    assert_true(root.bools.get("flag", False))
    assert_false(root.bools.get("off", True))


def test_sections_and_arrays() raises:
    var text = String()
    text += 'client_identifier = "abc"\n'
    text += "\n"
    text += "[keybinds]\n"
    text += 'play_pause = ["KEY_SPACE", "KEY_P"]\n'
    text += 'one_entry = ["KEY_ESCAPE"]\n'
    var tables = parse_toml(text)
    var root = tables.get("", TomlSection())
    assert_equal(root.strings.get("client_identifier", ""), "abc")
    var kb = tables.get("keybinds", TomlSection())
    var pp = kb.str_arrays.get("play_pause", _empty_list())
    assert_equal(len(pp), 2)
    assert_equal(pp[0], "KEY_SPACE")
    assert_equal(pp[1], "KEY_P")
    var one = kb.str_arrays.get("one_entry", _empty_list())
    assert_equal(len(one), 1)


def test_string_escapes_roundtrip() raises:
    """Writer + reader agree on quotes, backslashes, newlines, unicode."""
    var raw = 'Björn\'s "Book" \\ vol\n2\ttab' + String(chr(1)) + "ctl"
    var encoded = _toml_string(raw)
    assert_equal(String(encoded[byte=0]), '"')
    assert_equal(String(encoded[byte=encoded.byte_length() - 1]), '"')
    var line = "title = " + encoded + "\n"
    var tables = parse_toml(line)
    assert_equal(tables[""].strings.get("title", ""), raw)


def test_toml_doc_roundtrip() raises:
    """A TomlDoc dump parses back into identical typed values."""
    var doc = TomlDoc()
    doc.add("client_identifier", "id-1")
    doc.add("font_multiplier", 1.25)
    doc.add("count", 7)
    doc.set_section("keybinds")
    var keys: List[String] = ["KEY_SPACE", "KEY_ESCAPE"]
    doc.add("play_pause", keys)
    var text = doc.dump()
    var tables = parse_toml(text)
    var root = tables.get("", TomlSection())
    assert_equal(root.strings.get("client_identifier", ""), "id-1")
    assert_equal(root.floats.get("font_multiplier", 0.0), 1.25)
    assert_equal(root.ints.get("count", 0), 7)
    var kb = tables.get("keybinds", TomlSection())
    var pp = kb.str_arrays.get("play_pause", _empty_list())
    assert_equal(len(pp), 2)
    assert_equal(pp[0], "KEY_SPACE")


def test_corrupt_raises() raises:
    """Anything outside the subset raises (callers rebuild defaults)."""
    var a = 'key = "never closed\n'
    with assert_raises():
        _ = parse_toml(a)
    var b = 'key = "ok" trailing\n'
    with assert_raises():
        _ = parse_toml(b)
    var c = "count = abc\n"
    with assert_raises():
        _ = parse_toml(c)
    var d = 'keys = ["a", "b"\n'
    with assert_raises():
        _ = parse_toml(d)
    var e = "[keybinds\n"
    with assert_raises():
        _ = parse_toml(e)


def test_nonascii_not_corrupted() raises:
    """A title with non-ASCII inside a parsed line round-trips."""
    var text = 'title = "Björns Låtar"\n'
    var tables = parse_toml(text)
    assert_equal(tables[""].strings.get("title", ""), "Björns Låtar")


def test_empty_file() raises:
    """Root table always exists, even for an empty file."""
    var tables = parse_toml("\n\n# only comments\n")
    assert_equal(len(tables), 1)


def main() raises:
    test_utf8_decode()
    print("utf8 ok")
    test_utf8_decode_4byte()
    test_utf8_decode_invalid_skipped()
    print("utf8 variants ok")
    test_scalars()
    print("scalars ok")
    test_sections_and_arrays()
    print("sections ok")
    test_string_escapes_roundtrip()
    print("escapes ok")
    test_toml_doc_roundtrip()
    print("doc roundtrip ok")
    test_corrupt_raises()
    print("corrupt ok")
    test_nonascii_not_corrupted()
    print("nonascii ok")
    test_empty_file()
    print("empty ok")
    print("All mintoml format tests passed.")
