# tests/test_nav_engine.mojo — drives the REAL spatial-nav engine across
# simulated frames. The dpad binds and the arrow-key binds share the same
# check_keybind path, so injected keyboard presses exercise the identical
# engine the gamepad runs. Draw calls are never made, so the font/canvas
# boxes stay dummy pointers (never dereferenced).
#
# Run: pixi run mojo -I . tests/test_nav_engine.mojo

from std.collections import Dict, List
from std.memory import alloc, Layout
from std.memory.unsafe_pointer import Pointer
from std.testing import assert_equal, assert_true, assert_false

from platform.window import WindowInput
from platform.gamepad import Gamepad, PadState, _apply_hat_bits
from platform.gamepad import _apply_stick_axes
from render.canvas import Canvas
from render.imui import (
    UIContext,
    NavState,
    Rect,
    NAV_DOWN,
    NAV_UP,
)
from ui.font import FontSet
from resources.keys import KEY_UP, KEY_DOWN, KEY_ENTER, key_combo

# List geometry shared by the simulated registrations: four rows, one
# stride of 100 screen px; scrolling slides the window while a new row
# enters at the bottom (the edge-hold + index-shift contract).


struct FrameHarness:
    """One simulated screen: heap-boxed input + nav state reused across
    frames, a rebuild-per-frame UIContext (the main-loop pattern)."""

    var input_box: Pointer[WindowInput, MutUntrackedOrigin]
    var nav_box: Pointer[NavState, MutUntrackedOrigin]
    var fonts_box: Pointer[FontSet, MutUntrackedOrigin]
    var canvas_box: Pointer[Canvas, MutUntrackedOrigin]
    var keybinds: Dict[String, List[List[Int]]]
    var scrolled_rows: Int  # simulated list scroll (rows stepped past)

    def __init__(out self):
        self.input_box = alloc(Layout[WindowInput](count=1)).unsafe_leak()
        self.input_box.unsafe_write(WindowInput())
        self.nav_box = alloc(Layout[NavState](count=1)).unsafe_leak()
        self.nav_box.unsafe_write(NavState())
        self.fonts_box = Pointer[FontSet, MutUntrackedOrigin](
            unsafe_from_address=16
        )
        self.canvas_box = Pointer[Canvas, MutUntrackedOrigin](
            unsafe_from_address=32
        )
        # The app's resolved keybinds for the nav + select actions (the
        # same combo shape main.mojo builds from Config).
        self.keybinds = _nav_keybinds()
        self.scrolled_rows = 0

    def inject_press(mut self, key: Int32):
        """Queue one key press for the next frame (the poll-side ring)."""
        self.input_box[unsafe_offset=0].queue_key_event(key, True)

    def pump(self):
        """The real loop clears the event ring each poll."""
        self.input_box[unsafe_offset=0].clear_frame_keys()

    def make_ui(self, screen: Int = 1, nav_active: Bool = True) -> UIContext:
        """One frame's UIContext (rebuilt per frame, like main)."""
        return UIContext(
            self.fonts_box,
            self.canvas_box,
            self.input_box,
            0.016,  # dt
            1200,
            1000,
            self.keybinds.copy(),
            1.0,
            1.0,
            Optional[Pointer[Gamepad, MutUntrackedOrigin]](),
            Optional[Pointer[NavState, MutUntrackedOrigin]](self.nav_box),
            screen,
            nav_active,
            True,
        )

    def register_rows(mut self, mut ui: UIContext) -> List[Int]:
        """The simulated screen's draw pass: register the 5 visible rows
        for the current simulated scroll (rows shifted off the top are
        replaced by new rows at the bottom, indices preserved) + the
        scroll-region hint the real screens register."""
        ui.nav_scroll_hint(1, self.scrolled_rows > 0, True)
        var ids = List[Int]()
        for i in range(5):
            var r = Rect(
                0.0,
                Float64(100 + i * 100),
                900.0,
                88.0,
            )
            ids.append(ui.nav_node(r, 1))
        return ids^

    def register_chrome_and_rows(mut self, mut ui: UIContext) -> List[Int]:
        """A library-like screen: one chrome control on top (region 0,
        like the search bar) above the 5 content rows (region 1)."""
        _ = ui.nav_node(Rect(0.0, 10.0, 900.0, 40.0))
        ui.nav_scroll_hint(1, self.scrolled_rows > 0, True)
        var ids = List[Int]()
        for i in range(5):
            ids.append(
                ui.nav_node(Rect(0.0, Float64(100 + i * 100), 900.0, 88.0), 1)
            )
        return ids^


def _nav_keybinds() -> Dict[String, List[List[Int]]]:
    """Resolved defaults for the nav + select actions."""
    var out = Dict[String, List[List[Int]]]()
    out["nav_up"] = [key_combo("KEY_UP")]
    out["nav_down"] = [key_combo("KEY_DOWN")]
    out["select"] = [key_combo("KEY_ENTER")]
    out["nav_left"] = [key_combo("KEY_LEFT")]
    out["nav_right"] = [key_combo("KEY_RIGHT")]
    return out^


def test_first_press_homes() raises:
    """The first directional press homes focus (center-most node)."""
    var h = FrameHarness()
    var ui1 = h.make_ui()
    _ = ui1.nav_focused_id()  # frame 1: registers nothing yet
    h.pump()

    var ui2 = h.make_ui()
    _ = h.register_rows(ui2)
    assert_equal(ui1.nav_focused_id(), -1)
    assert_equal(ui2.nav_focused_id(), -1)
    h.pump()

    # Frame 3: dpad down — focus homes onto the center-most row.
    h.inject_press(KEY_DOWN)
    var ui3 = h.make_ui()
    _ = h.register_rows(ui3)
    # Window center y=500; row centers 144..544 — the bottom row (544) is
    # closest, index 4.
    assert_equal(ui3.nav_focused_id(), 4)
    h.pump()


def test_walk_and_held() raises:
    """Focus walks the list; each press steps exactly once."""
    var h = FrameHarness()
    # Warm-up frame (registers become prev for the next).
    var ui1 = h.make_ui()
    _ = h.register_rows(ui1)
    h.inject_press(KEY_DOWN)
    var ui2 = h.make_ui()
    _ = h.register_rows(ui2)
    assert_equal(ui2.nav_focused_id(), 4)  # homed (center-most)
    h.pump()

    h.inject_press(KEY_UP)
    var ui3 = h.make_ui()
    _ = h.register_rows(ui3)
    assert_equal(ui3.nav_focused_id(), 3)
    h.pump()

    # No keys: focus holds.
    var ui4 = h.make_ui()
    _ = h.register_rows(ui4)
    assert_equal(ui4.nav_focused_id(), 3)
    h.pump()

    # Up again from 3: to 2.
    h.inject_press(KEY_UP)
    var ui5 = h.make_ui()
    _ = h.register_rows(ui5)
    assert_equal(ui5.nav_focused_id(), 2)
    h.pump()


def test_edge_hold_shifts_focus_with_scroll() raises:
    """At the list bottom with content below, a down-step holds focus and
    raises the edge; the screen scrolls, the next registration pass names
    the NEXT row under the same index."""
    var h = FrameHarness()
    var idx = 4
    # Walk to the bottom first.
    var ui1 = h.make_ui()
    _ = h.register_rows(ui1)
    h.inject_press(KEY_DOWN)
    var ui2 = h.make_ui()
    _ = h.register_rows(ui2)
    assert_equal(ui2.nav_focused_id(), idx)
    h.pump()

    # Down at the bottom edge: HELD + edge flag (does not escape).
    h.inject_press(KEY_DOWN)
    var ui3 = h.make_ui()
    _ = h.register_rows(ui3)
    assert_equal(ui3.nav_focused_id(), idx)
    assert_true(ui3.nav_scroll_edge(1, NAV_DOWN))
    h.pump()
    # Screen consumed the edge: simulate the scroll (content slides).
    h.scrolled_rows += 1

    # Next frame: same index now names the next row (ring follows the
    # scroll); another down-step STILL hits the edge (still at window
    # bottom) — held-dpad walks the list like a fixed cursor.
    h.inject_press(KEY_DOWN)
    var ui4 = h.make_ui()
    _ = h.register_rows(ui4)
    assert_equal(ui4.nav_focused_id(), idx)
    assert_true(ui4.nav_scroll_edge(1, NAV_DOWN))
    h.pump()


def test_activate_selects() raises:
    """Enter (the select bind) activates the focused element exactly, and
    only it."""
    var h = FrameHarness()
    var ui1 = h.make_ui()
    _ = h.register_rows(ui1)
    h.inject_press(KEY_UP)
    var ui2 = h.make_ui()
    _ = h.register_rows(ui2)
    var focused = ui2.nav_focused_id()
    assert_true(focused >= 0)
    assert_false(ui2.nav_activated(focused))
    h.pump()

    h.inject_press(KEY_ENTER)
    var ui3 = h.make_ui()
    _ = h.register_rows(ui3)
    assert_equal(ui3.nav_focused_id(), focused)
    assert_true(ui3.nav_activated(focused))
    for other in range(5):
        if other != focused:
            assert_false(ui3.nav_activated(other))
    h.pump()


def test_screen_switch_resets() raises:
    """A screen change drops focus; movement across screens is inert."""
    var h = FrameHarness()
    var ui1 = h.make_ui(screen=1)
    _ = h.register_rows(ui1)
    h.inject_press(KEY_DOWN)
    var ui2 = h.make_ui(screen=1)
    _ = h.register_rows(ui2)
    assert_true(ui2.nav_focused_id() >= 0)
    h.pump()

    h.inject_press(KEY_DOWN)
    var ui3 = h.make_ui(screen=4)  # switched this frame
    _ = h.register_rows(ui3)
    assert_equal(ui3.nav_focused_id(), -1)
    h.pump()

    # After a full frame on the new screen, navigation homes there.
    h.inject_press(KEY_DOWN)
    var ui4 = h.make_ui(screen=4)
    _ = h.register_rows(ui4)
    assert_equal(ui4.nav_focused_id(), 4)
    h.pump()


def test_pointer_moves_clear_focus() raises:
    """Mouse/touch movement hands focus back to the pointer."""
    var h = FrameHarness()
    var ui1 = h.make_ui()
    _ = h.register_rows(ui1)
    h.inject_press(KEY_UP)
    var ui2 = h.make_ui()
    _ = h.register_rows(ui2)
    assert_true(ui2.nav_focused_id() >= 0)
    h.pump()

    # Pointer moved this frame (input mirror updated like main does).
    h.input_box[unsafe_offset=0].mouse_x = 640.0
    h.input_box[unsafe_offset=0].mouse_y = 512.0
    var ui3 = h.make_ui()
    _ = h.register_rows(ui3)
    assert_equal(ui3.nav_focused_id(), -1)
    h.pump()


def test_single_tap_no_phantom_repeat() raises:
    """One press (then release) steps exactly once — no walk-on-its-own
    after the repeat delay (the sticky last-event heuristic must not
    feed the held path; the trigger is measured by fresh press events)."""
    var h = FrameHarness()
    var ui1 = h.make_ui()
    _ = h.register_rows(ui1)
    h.inject_press(KEY_DOWN)
    var ui2 = h.make_ui()
    _ = h.register_rows(ui2)
    var focused = ui2.nav_focused_id()
    assert_true(focused >= 0)
    h.pump()

    # Several quiet frames: focus must not move on its own.
    for _n in range(4):
        var uix = h.make_ui()
        _ = h.register_rows(uix)
        assert_equal(uix.nav_focused_id(), focused)
        h.pump()


def test_hat_edge_synthesis() raises:
    """The reader's edge synthesis for the hat axes: tilting into a
    direction presses (down+edge), centering releases (down cleared),
    and the rebinder's last_button tracks dpad presses."""
    var p = PadState()
    _apply_hat_bits(p, 0, -1)  # tilt UP
    assert_true((p.down[0] >> 1) & 1 == 1)  # code 1 = LEFT_FACE_UP
    assert_true((p.edge[0] >> 1) & 1 == 1)
    assert_true(Int(p.last_button) == 1)
    assert_true((p.down[0] >> 4) & 1 == 0)  # LEFT released
    _apply_hat_bits(p, 0, 0)  # centered: UP release
    assert_true((p.down[0] >> 1) & 1 == 0)
    _apply_hat_bits(p, -1, 0)  # tilt LEFT: code 4
    assert_true((p.down[0] >> 4) & 1 == 1)
    assert_true((p.edge[0] >> 4) & 1 == 1)
    assert_true(Int(p.last_button) == 4)
    _apply_hat_bits(p, 1, 0)  # slide to RIGHT: code 2, LEFT releases
    assert_true((p.down[0] >> 2) & 1 == 1)
    assert_true((p.down[0] >> 4) & 1 == 0)
    assert_true(Int(p.last_button) == 2)


def test_hat_no_repeat_edge() raises:
    """A held hat direction must not re-press on level events (rising
    edge only): re-feeding the same position keeps the edge bit from
    growing into a second press after the UI clears it."""
    var p = PadState()
    _apply_hat_bits(p, 0, -1)
    assert_true((p.edge[0] >> 1) & 1 == 1)
    # Simulate the UI's end_frame edge clear, then a redundant level event.
    p.edge[0] = 0
    _apply_hat_bits(p, 0, -1)
    assert_true((p.edge[0] >> 1) & 1 == 0)  # kept held, no new press
    _apply_hat_bits(p, 0, 0)  # release
    _apply_hat_bits(p, 0, -1)  # re-tilt presses again
    assert_true((p.edge[0] >> 1) & 1 == 1)


def test_stick_hysteresis() raises:
    """Left-stick navigation: engages past the threshold, releases below
    the lower band, and noise near the band can't re-press."""
    var p = PadState()
    _apply_stick_axes(p, 0, 14000)  # below engage (50% ≈ 16k): nothing
    assert_true((p.down[0] >> 1) & 1 == 0)
    _apply_stick_axes(p, 0, -17000)  # tilt up past the engage threshold
    assert_true((p.down[0] >> 1) & 1 == 1)
    assert_true((p.edge[0] >> 1) & 1 == 1)
    assert_true(Int(p.last_button) == 1)
    p.edge[0] = 0
    _apply_stick_axes(p, 0, -32767)  # full push: held, no new press
    assert_true((p.edge[0] >> 1) & 1 == 0)
    assert_true((p.down[0] >> 1) & 1 == 1)
    _apply_stick_axes(p, 0, -10000)  # inside the band: STILL held
    assert_true((p.down[0] >> 1) & 1 == 1)
    _apply_stick_axes(p, 0, -8000)  # below release: released
    assert_true((p.down[0] >> 1) & 1 == 0)
    assert_true(p.stick_engage == 0)
    _apply_stick_axes(p, 0, -12000)  # noise re-crossing the band: no press
    assert_true((p.edge[0] >> 1) & 1 == 0)
    assert_true((p.down[0] >> 1) & 1 == 0)
    _apply_stick_axes(p, 0, -20000)  # re-engaging past the threshold
    assert_true((p.down[0] >> 1) & 1 == 1)
    assert_true((p.edge[0] >> 1) & 1 == 1)


def test_stick_diagonal() raises:
    """A diagonal push engages both directions (two rising edges)."""
    var p = PadState()
    _apply_stick_axes(p, 20000, -20000)  # up + right
    assert_true((p.down[0] >> 1) & 1 == 1)
    assert_true((p.down[0] >> 2) & 1 == 1)
    assert_true((p.edge[0] >> 1) & 1 == 1)
    assert_true((p.edge[0] >> 2) & 1 == 1)


def test_enter_list_from_chrome() raises:
    """The stuck-in-the-header contract: homing targets content, the
    walk escapes into chrome only at the list's true top edge, and from
    chrome a directional step ENERS the list again (chrome does not
    trap the walk)."""
    var h = FrameHarness()
    var ui1 = h.make_ui()
    _ = h.register_chrome_and_rows(ui1)
    h.pump()

    # First press homes onto the center-most content row (index 5).
    h.inject_press(KEY_DOWN)
    var ui2 = h.make_ui()
    _ = h.register_chrome_and_rows(ui2)
    assert_equal(ui2.nav_focused_id(), 5)
    h.pump()

    # Climb out the top: 4 ups to row 0's top, one more escapes to chrome.
    for expect in [4, 3, 2, 1]:
        h.inject_press(KEY_UP)
        var uix = h.make_ui()
        _ = h.register_chrome_and_rows(uix)
        assert_equal(uix.nav_focused_id(), expect)
        h.pump()
    h.inject_press(KEY_UP)
    var ui_escape = h.make_ui()
    _ = h.register_chrome_and_rows(ui_escape)
    assert_equal(ui_escape.nav_focused_id(), 0)  # the chrome node
    h.pump()

    # And back in: DOWN from chrome re-enters the list at row 0 (full-mix
    # pick — a walk must never trap in the chrome).
    h.inject_press(KEY_DOWN)
    var ui_back = h.make_ui()
    _ = h.register_chrome_and_rows(ui_back)
    assert_equal(ui_back.nav_focused_id(), 1)
    h.pump()


def test_homing_prefers_content() raises:
    """First-press homing targets the scroll region's center-most node,
    not a chrome node and not an unregistered dead control."""
    var h = FrameHarness()
    var ui1 = h.make_ui()
    _ = h.register_chrome_and_rows(ui1)
    h.pump()

    h.inject_press(KEY_DOWN)
    var ui2 = h.make_ui()
    _ = h.register_chrome_and_rows(ui2)
    # Rows (region 1) occupy indices 1..5; center-most is the bottom row.
    assert_equal(ui2.nav_focused_id(), 5)
    h.pump()


def main() raises:
    test_first_press_homes()
    print("homes ok")
    test_walk_and_held()
    print("walk ok")
    test_edge_hold_shifts_focus_with_scroll()
    print("edge+scroll ok")
    test_activate_selects()
    print("activate ok")
    test_screen_switch_resets()
    print("screen reset ok")
    test_pointer_moves_clear_focus()
    print("pointer handoff ok")
    test_single_tap_no_phantom_repeat()
    print("no-phantom ok")
    test_hat_edge_synthesis()
    print("hat edges ok")
    test_hat_no_repeat_edge()
    print("hat no-repeat ok")
    test_stick_hysteresis()
    print("stick hysteresis ok")
    test_stick_diagonal()
    print("stick diagonal ok")
    test_enter_list_from_chrome()
    print("chrome entry ok")
    test_homing_prefers_content()
    print("content homing ok")
    print("All nav engine tests passed.")
