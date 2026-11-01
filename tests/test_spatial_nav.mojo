# tests/test_spatial_nav.mojo — the spatial-navigation scoring functions
# (pure geometry; the engine integration is verified by the full build +
# on-device). Run: pixi run mojo -I . tests/test_spatial_nav.mojo

from std.collections import List
from std.testing import assert_equal

from render.imui import (
    Rect,
    NAV_DOWN,
    NAV_LEFT,
    NAV_RIGHT,
    NAV_UP,
    NavState,
    ScrollHint,
    _spatial_center_pick,
    _spatial_pick,
)


def _rect(x: Float64, y: Float64, w: Float64, h: Float64) -> Rect:
    return Rect(x, y, w, h)


def test_vertical_list_step() raises:
    """A vertical list walks in order with straight (perp-0) steps."""
    var nodes = List[Rect]()
    nodes.append(_rect(0, 100, 200, 50))  # 0: row A
    nodes.append(_rect(0, 160, 200, 50))  # 1: row B
    nodes.append(_rect(0, 220, 200, 50))  # 2: row C
    assert_equal(_spatial_pick(nodes, 0, NAV_DOWN), 1)
    assert_equal(_spatial_pick(nodes, 1, NAV_DOWN), 2)
    assert_equal(_spatial_pick(nodes, 1, NAV_UP), 0)
    assert_equal(_spatial_pick(nodes, 0, NAV_UP), -1)
    assert_equal(_spatial_pick(nodes, 2, NAV_DOWN), -1)


def test_row_children_win_the_row() raises:
    """From a wide row card, right picks the row's own SAVE before PLAY,
    both before the next row's far-off children (perp weighting)."""
    var nodes = List[Rect]()
    nodes.append(_rect(0, 0, 1000, 100))  # 0: row 1 (full row)
    nodes.append(_rect(700, 20, 100, 60))  # 1: row 1 SAVE
    nodes.append(_rect(860, 20, 100, 60))  # 2: row 1 PLAY
    nodes.append(_rect(0, 120, 1000, 100))  # 3: row 2 (full row)
    nodes.append(_rect(700, 140, 100, 60))  # 4: row 2 SAVE
    nodes.append(_rect(860, 140, 100, 60))  # 5: row 2 PLAY
    assert_equal(_spatial_pick(nodes, 0, NAV_RIGHT), 1)
    assert_equal(_spatial_pick(nodes, 1, NAV_RIGHT), 2)
    # Down from row 1: row 2 card (perp 0) beats row 2's SAVE/PLAY.
    assert_equal(_spatial_pick(nodes, 0, NAV_DOWN), 3)
    # Down from SAVE: the next row's own SAVE (aligned) beats its card.
    assert_equal(_spatial_pick(nodes, 1, NAV_DOWN), 4)
    # Down from PLAY: the next row's own PLAY (perp 0) beats its card.
    assert_equal(_spatial_pick(nodes, 2, NAV_DOWN), 5)
    # Up from PLAY: back to the row above? nothing above row 1's PLAY
    # column -> edge (-1).
    assert_equal(_spatial_pick(nodes, 2, NAV_UP), -1)


def test_self_and_overlaps_excluded() raises:
    """Containing/contained rects never win a step (primary <= 1)."""
    var nodes = List[Rect]()
    nodes.append(_rect(100, 100, 800, 80))  # 0: bar
    nodes.append(_rect(780, 110, 100, 60))  # 1: button inside the bar
    # From the button, right: nothing further right.
    assert_equal(_spatial_pick(nodes, 1, NAV_RIGHT), -1)
    # From the bar, right: its own button is to the right (primary > 1)
    # — the engine moves INTO the child, but activation requires exact
    # id match, so this is only a scoring observation.
    assert_equal(_spatial_pick(nodes, 0, NAV_RIGHT), 1)


def test_horizontal_row_cross() raises:
    """Left/right moves across a horizontal control row (presets)."""
    var nodes = List[Rect]()
    nodes.append(_rect(20, 300, 72, 28))  # 0: 75%
    nodes.append(_rect(102, 300, 72, 28))  # 1: 100%
    nodes.append(_rect(184, 300, 72, 28))  # 2: 125%
    assert_equal(_spatial_pick(nodes, 0, NAV_RIGHT), 1)
    assert_equal(_spatial_pick(nodes, 2, NAV_RIGHT), -1)
    assert_equal(_spatial_pick(nodes, 2, NAV_LEFT), 1)
    # A vertical neighbor far above still beats nothing (no candidates).
    assert_equal(_spatial_pick(nodes, 1, NAV_UP), -1)


def test_center_pick() raises:
    """First press homes onto the node nearest the window center."""
    var nodes = List[Rect]()
    nodes.append(_rect(20, 40, 80, 40))  # corner
    nodes.append(_rect(560, 500, 80, 40))  # near center of 1200x1000
    nodes.append(_rect(300, 100, 80, 40))
    assert_equal(_spatial_center_pick(nodes, 1200, 1000), 1)


def test_nav_state_defaults() raises:
    """A fresh NavState is unfocused with no edges or hints."""
    var ns = NavState()
    assert_equal(ns.focused, -1)
    assert_equal(ns.edge_dir, -1)
    assert_equal(ns.activate, False)
    assert_equal(len(ns.prev_nodes), 0)
    var hint = ns.prev_hints.get(1, ScrollHint())
    assert_equal(hint.has_above, False)
    assert_equal(hint.has_below, False)


def main() raises:
    test_vertical_list_step()
    test_row_children_win_the_row()
    test_self_and_overlaps_excluded()
    test_horizontal_row_cross()
    test_center_pick()
    test_nav_state_defaults()
    print("All spatial nav tests passed.")
