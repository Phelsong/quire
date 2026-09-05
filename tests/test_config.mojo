"""Tests for resources.config and resources.keys — keybinds, combos, and Config.

Run with: pixi run test  (mojo test_config.mojo)
"""

from std.testing import assert_equal, assert_true, assert_false

from resources.config import Config
from resources.keys import key_code, key_combo


def test_default_keybinds() raises:
    """Config() should populate the default keybind actions."""
    var cfg = Config()
    var keys = cfg.get_keybinds("play_pause")
    assert_equal(len(keys), 2)
    assert_equal(keys[0], "KEY_SPACE")

    var skip = cfg.get_keybinds("skip_back")
    assert_equal(len(skip), 2)
    assert_equal(skip[0], "KEY_LEFT")

    # Unknown action returns empty list, not a crash.
    var missing = cfg.get_keybinds("nonexistent")
    assert_equal(len(missing), 0)


def test_default_combo_keybinds() raises:
    """Prev/next chapter should default to Shift+Arrow combos."""
    var cfg = Config()
    var prev = cfg.get_keybinds("prev_chapter")
    assert_equal(len(prev), 1)
    assert_equal(prev[0], "KEY_LEFT_SHIFT+KEY_LEFT")

    var next = cfg.get_keybinds("next_chapter")
    assert_equal(len(next), 1)
    assert_equal(next[0], "KEY_LEFT_SHIFT+KEY_RIGHT")


def test_set_keybind() raises:
    """Set_keybind should overwrite an action's key list."""
    var cfg = Config()
    cfg.set_keybind("play_pause", ["KEY_ENTER", "KEY_KP_ENTER"])
    var keys = cfg.get_keybinds("play_pause")
    assert_equal(len(keys), 2)
    assert_equal(keys[0], "KEY_ENTER")
    assert_equal(keys[1], "KEY_KP_ENTER")


def test_set_combo_keybind() raises:
    """Set_keybind should accept combo specs in the list."""
    var cfg = Config()
    cfg.set_keybind("play_pause", ["KEY_SPACE", "KEY_LEFT_CONTROL+KEY_P"])
    var keys = cfg.get_keybinds("play_pause")
    assert_equal(len(keys), 2)
    assert_equal(keys[0], "KEY_SPACE")
    assert_equal(keys[1], "KEY_LEFT_CONTROL+KEY_P")


def test_key_code_resolution() raises:
    """Key_code should resolve known names and return 0 for unknown."""
    assert_equal(key_code("KEY_SPACE"), 32)
    assert_equal(key_code("KEY_ESCAPE"), 256)
    assert_equal(key_code("KEY_LEFT"), 263)
    assert_equal(key_code("KEY_RIGHT"), 262)
    assert_equal(key_code("KEY_LEFT_SHIFT"), 340)
    assert_equal(key_code("KEY_LEFT_CONTROL"), 341)
    assert_equal(key_code("KEY_MINUS"), 45)
    assert_equal(key_code("KEY_EQUAL"), 61)
    assert_equal(key_code("KEY_ENTER"), 257)

    # Unknown name → KEY_NULL (0)
    assert_equal(key_code("KEY_FROBNICATE"), 0)
    assert_equal(key_code(""), 0)


def test_key_combo_single_key() raises:
    """A single-key spec (no +) should return a one-element list."""
    var combo = key_combo("KEY_SPACE")
    assert_equal(len(combo), 1)
    assert_equal(combo[0], 32)


def test_key_combo_two_keys() raises:
    """A two-key combo like KEY_LEFT_SHIFT+KEY_LEFT should resolve to [340, 263].
    """
    var combo = key_combo("KEY_LEFT_SHIFT+KEY_LEFT")
    assert_equal(len(combo), 2)
    assert_equal(combo[0], 340)  # modifier (held down)
    assert_equal(combo[1], 263)  # trigger (pressed)


def test_key_combo_unknown_rejected() raises:
    """If any part of a combo is unknown, the entire combo is rejected."""
    var combo = key_combo("KEY_LEFT_SHIFT+KEY_FROBNICATE")
    assert_equal(len(combo), 0)

    combo = key_combo("KEY_FROBNICATE+KEY_LEFT")
    assert_equal(len(combo), 0)


def test_keybinds_resolved_to_combos() raises:
    """Full pipeline: Config keybinds → key_combo() → List[Int] keycodes."""
    var cfg = Config()
    var play_spec = cfg.get_keybinds("play_pause")
    var play_combo = key_combo(play_spec[0])
    assert_equal(len(play_combo), 1)
    assert_equal(play_combo[0], 32)

    var prev_spec = cfg.get_keybinds("prev_chapter")
    var prev_combo = key_combo(prev_spec[0])
    assert_equal(len(prev_combo), 2)
    assert_equal(prev_combo[0], 340)  # KEY_LEFT_SHIFT
    assert_equal(prev_combo[1], 263)  # KEY_LEFT


def test_config_copy() raises:
    """Config.copy() should deep-copy the keybinds dict."""
    var original = Config()
    original.set_keybind("play_pause", ["KEY_ENTER"])

    var copy = original.copy()
    # Mutate the copy — original must be unaffected.
    copy.set_keybind("play_pause", ["KEY_TAB"])

    var orig_keys = original.get_keybinds("play_pause")
    var copy_keys = copy.get_keybinds("play_pause")
    assert_equal(orig_keys[0], "KEY_ENTER")
    assert_equal(copy_keys[0], "KEY_TAB")


def test_default_font_multiplier() raises:
    """Config() should default font_multiplier to 1.0."""
    var cfg = Config()
    assert_equal(cfg.font_multiplier, 1.0)


def main() raises:
    test_default_keybinds()
    test_default_combo_keybinds()
    test_set_keybind()
    test_set_combo_keybind()
    test_key_code_resolution()
    test_key_combo_single_key()
    test_key_combo_two_keys()
    test_key_combo_unknown_rejected()
    test_keybinds_resolved_to_combos()
    test_config_copy()
    test_default_font_multiplier()
    print("All config tests passed.")
