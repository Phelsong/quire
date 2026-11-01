# tests/test_encoding.mojo — UTF-8 safety of the byte-encoding helpers.
#
# Regression tests for the search crash: _percent_encode / _shell_quote /
# write_ascii used to walk raw byte indices and abort uncatchably
# ("String span index ... does not lie on a codepoint boundary") on the
# first multi-byte UTF-8 character in a search query, file path, or
# image caption. Run: pixi run mojo -I . tests/test_encoding.mojo

from std.testing import assert_equal, assert_true

from functions.helpers import _shell_quote
from functions.plex_bridge import _percent_encode
from resources.imencode import write_ascii


def test_ascii_unchanged() raises:
    """Unreserved pass through, reserved encode, spaces stay %20."""
    assert_equal(_percent_encode("aZ0-._~"), "aZ0-._~")
    assert_equal(_percent_encode("hello world"), "hello%20world")
    assert_equal(
        _percent_encode("So I'm a Spider?"),
        "So%20I%27m%20a%20Spider%3F",
    )


def test_multibyte_query_survives() raises:
    """The old crash: one accented char must encode, not abort."""
    assert_equal(_percent_encode("spéncer"), "sp%C3%A9ncer")
    assert_equal(_percent_encode("café"), "caf%C3%A9")
    # Curly quote + ellipsis (3-byte codepoints).
    assert_equal(_percent_encode("it’s…"), "it%E2%80%99s%E2%80%A6")
    # Astral-plane (4-byte codepoint).
    assert_equal(_percent_encode("🦆"), "%F0%9F%A6%86")


def test_shell_quote_multibyte() raises:
    """Apostrophes escape, non-ASCII passes through verbatim."""
    assert_equal(_shell_quote("it's"), "'it'\\''s'")
    assert_equal(_shell_quote("café"), "'café'")


def test_write_ascii_strips_non_ascii() raises:
    """Non-ASCII collapses to '?' instead of aborting."""
    var buf = List[UInt8]()
    write_ascii(buf, "aé")
    assert_equal(len(buf), 2)
    assert_equal(Int(buf[0]), 97)
    assert_equal(Int(buf[1]), 0x3F)


def main() raises:
    test_ascii_unchanged()
    print("ascii ok")
    test_multibyte_query_survives()
    print("multibyte ok")
    test_shell_quote_multibyte()
    print("shell quote ok")
    test_write_ascii_strips_non_ascii()
    print("write_ascii ok")
    print("All encoding tests passed.")
