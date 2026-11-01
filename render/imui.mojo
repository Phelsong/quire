# ui/imui.mojo — immediate-mode UI facade.
#
# one UIContext per frame,
# design-pixel layout, buttons/labels/sliders/cards. Rendering now goes
# through render/canvas.mojo (pure-Mojo rasterizer into the wl_shm frame)
# and text through the FreeType-baked atlases in ui/font.mojo. Input comes
# from the Wayland window (platform/window.mojo) via a WindowInput snapshot
# the main loop refreshes each frame.

from std.collections import Dict, List

from resources.color import Color
from render.canvas import Canvas
from platform.window import WindowInput
from platform.gamepad import Gamepad
from ui.font import FontSet
from platform.text import TextAtlas
from resources.keys import GAMEPAD_SENTINEL
from resources.palette import (
    ACCENT_DARK,
    BORDER_FOCUS,
    CARD_BG,
    GREEN,
    LIB_CARD_BG,
    SELECTED_BG,
    SLIDER_BG,
    SLIDER_FILL,
)


comptime DESIGN_W = 1200.0
comptime DESIGN_H = 1600.0

# Minimum horizontal padding (design px) between a button label and its edge.
comptime BUTTON_PAD_X = 30.0

# Atlas ladder sizes (must match FontSet fields in ui/font.mojo).
comptime ATLAS_SIZES = (12, 14, 16, 18, 20, 22, 26, 32, 48, 56, 64, 81, 96)

# ---------------------------------------------------------------------------
# Spatial navigation (gamepad dpad / arrow keys)
# ---------------------------------------------------------------------------
#
# Every interactive element registers its rect for the frame (the widget
# primitives do it internally); focus is one of those rects, held across
# frames by INDEX (draw order is deterministic, so position i names the
# same element frame to frame — and when a scrolling list shifts by one
# row, the same position names the next row, which is exactly how
# held-dpad list walking should behave).
#
# Movement: _spatial_pick scores candidates by primary-axis distance plus
# a weighted perpendicular penalty (straight columns/rows preferred; a
# row's SAVE/PLAY children win their row because their centers align
# better on the perpendicular axis). When the focused node's region has
# no candidate in a scrollable direction (the screen registers
# has-more-content hints), the engine holds focus and raises an edge
# flag the screen consumes to scroll the list — the next frame's
# registration then names the following row under the same index.
#
# All directions resolve through config keybinds (nav_up/nav_down/
# nav_left/nav_right), and select activates the focused element, so the
# whole scheme is rebinding via the settings screen like every other
# action.


comptime NAV_UP = 0
comptime NAV_DOWN = 1
comptime NAV_LEFT = 2
comptime NAV_RIGHT = 3

# Default region (region 0 = screens' non-scrolling chrome; scrolling
# lists register a distinct region id).
comptime NAV_REGION_DEFAULT = 0

# Held-nav repeat: first repeat after this long, then one step per rate.
comptime NAV_REPEAT_DELAY_S = 0.38
comptime NAV_REPEAT_RATE_S = 0.12

# Perpendicular distance is penalized this heavily in the spatial score,
# so focus prefers straight lines over diagonal jumps.
comptime NAV_PERP_WEIGHT = 2.5


def _nav_action_for(dir: Int) -> String:
    """Config action name for a nav direction (single source of naming)."""
    if dir == NAV_UP:
        return "nav_up"
    if dir == NAV_DOWN:
        return "nav_down"
    if dir == NAV_LEFT:
        return "nav_left"
    return "nav_right"


struct ScrollHint(Copyable, ImplicitlyCopyable, Movable):
    """A scroll region's has-more-content state, registered by the screen
    during draw and consumed by the engine on the NEXT frame's begin
    (hints are inherently one frame stale, which is fine — scroll state
    changes only through these edges or the wheel)."""

    var has_above: Bool
    var has_below: Bool

    def __init__(out self, has_above: Bool = False, has_below: Bool = False):
        self.has_above = has_above
        self.has_below = has_below


struct NavState(Movable):
    """Cross-frame spatial-navigation memory (heap-boxed in main; the
    UIContext borrows it through a raw pointer each frame).

    Two rect lists: cur_nodes accumulates this frame's registrations;
    at the next frame's begin they become prev_nodes — the list
    movement/focus math runs against BEFORE anything draws (draw order
    is deterministic, so index i names the same element frame to frame;
    on a list scrolled by one row it names the next row, which makes
    held-dpad list walking behave like a fixed cursor).

    focused is an index into prev_nodes (-1 = no focus yet; the first
    directional press homes onto the node nearest the window center).
    Screen switches reset focus (screens are also tracked here so a nav
    press landing on the same frame as a screen change can't move focus
    against the previous screen's geometry).
    """

    var prev_nodes: List[Rect]  # last frame's rects (movement source)
    var prev_regions: List[Int]  # region ids parallel to prev_nodes
    var prev_hints: Dict[Int, ScrollHint]  # scroll hints from last frame
    var cur_nodes: List[Rect]  # this frame's accumulating registrations
    var cur_regions: List[Int]
    var cur_hints: Dict[Int, ScrollHint]
    var prev_screen: Int  # screen prev_nodes belong to (-1 = none yet)
    var cur_screen: Int
    var focused: Int  # index into prev_nodes; -1 = unfocused
    var last_screen: Int  # most recent nav_screen (change detection)
    var last_mouse: Vec2  # pointer position last frame (device handoff)
    var activate: Bool  # select fired this frame (focus-gated by ids)
    # One edge event per frame: the direction that found no candidate
    # while the focused region had scrollable content that way.
    var edge_dir: Int  # -1 = none
    var edge_region: Int
    var repeat_t: Array[Float64, 4]  # held-repeat countdown per direction
    var have_mouse: Bool  # last_mouse valid (first frame skips the check)

    def __init__(out self):
        self.prev_nodes = List[Rect]()
        self.prev_regions = List[Int]()
        self.prev_hints = Dict[Int, ScrollHint]()
        self.cur_nodes = List[Rect]()
        self.cur_regions = List[Int]()
        self.cur_hints = Dict[Int, ScrollHint]()
        self.prev_screen = -1
        self.cur_screen = -1
        self.focused = -1
        self.last_screen = -1
        self.last_mouse = Vec2()
        self.activate = False
        self.edge_dir = -1
        self.edge_region = NAV_REGION_DEFAULT
        self.repeat_t = Array[Float64, 4](uninitialized=True)
        for i in range(4):
            self.repeat_t[i] = 0.0
        self.have_mouse = False


def _spatial_best(nodes: List[Rect], fx: Float64, fy: Float64, dir: Int) -> Int:
    """Index within `nodes` best in `dir` from the point (fx, fy); -1
    when none.

    Score = primary-axis center distance + NAV_PERP_WEIGHT x
    perpendicular distance; strictly-ahead only (1px epsilon). Straight
    columns/rows are preferred and the nearest item of the next row wins
    when the focused column ends.
    """
    var best = -1
    var best_score = 0.0
    for i in range(len(nodes)):
        var cx = Float64(nodes[i].x) + Float64(nodes[i].width) / 2.0
        var cy = Float64(nodes[i].y) + Float64(nodes[i].height) / 2.0
        var dx = cx - fx
        var dy = cy - fy
        var primary: Float64
        var perp: Float64
        if dir == NAV_RIGHT:
            primary = dx
            perp = dy
        elif dir == NAV_LEFT:
            primary = -dx
            perp = dy
        elif dir == NAV_DOWN:
            primary = dy
            perp = dx
        else:
            primary = -dy
            perp = dx
        if primary <= 1.0:
            continue
        if perp < 0.0:
            perp = -perp
        var score = primary + NAV_PERP_WEIGHT * perp
        if best < 0 or score < best_score:
            best_score = score
            best = i
    return best


def _spatial_pick(nodes: List[Rect], from_idx: Int, dir: Int) -> Int:
    """Nearest node in `dir` from nodes[from_idx]; -1 when none."""
    var fx = Float64(nodes[from_idx].x) + Float64(nodes[from_idx].width) / 2.0
    var fy = Float64(nodes[from_idx].y) + Float64(nodes[from_idx].height) / 2.0
    return _spatial_best(nodes, fx, fy, dir)


def _spatial_center_pick(nodes: List[Rect], w: Float64, h: Float64) -> Int:
    """Node nearest the window center — the pick-up-and-play entry point."""
    var best = -1
    var best_d = 0.0
    for i in range(len(nodes)):
        var cx = Float64(nodes[i].x) + Float64(nodes[i].width) / 2.0
        var cy = Float64(nodes[i].y) + Float64(nodes[i].height) / 2.0
        var dx = cx - w / 2.0
        var dy = cy - h / 2.0
        var d = dx * dx + dy * dy
        if best < 0 or d < best_d:
            best_d = d
            best = i
    return best


def _nav_home(ns: NavState, screen_w: Int, screen_h: Int) -> Int:
    """First-press homing target.

    When the screen registered a scroll region, home onto the center-most
    node OF THE CONTENT (the list the user is about to walk); otherwise
    the window-center pick across everything."""
    var region = -1
    for entry in ns.prev_hints.items():
        region = entry.key
        break
    if region >= 0:
        var ids = List[Int]()
        var rects = List[Rect]()
        for i in range(len(ns.prev_nodes)):
            if ns.prev_regions[i] == region:
                rects.append(ns.prev_nodes[i].copy())
                ids.append(i)
        if len(rects) > 0:
            var k = _spatial_center_pick(
                rects, Float64(screen_w), Float64(screen_h)
            )
            return ids[k]
    return _spatial_center_pick(
        ns.prev_nodes, Float64(screen_w), Float64(screen_h)
    )


@always_inline
def _ladder_nearest(target: Int) -> Int:
    """Nearest baked-atlas rung for a target pixel size.

    The ladder is strictly ascending, so the nearest rung is the first one
    whose midpoint with its right neighbor the target has not passed; above
    the last midpoint the top rung (96) wins. Exact midpoints keep the
    SMALLER rung — the same first-wins-on-ties rule as the original List
    scan this replaces — and half-integer midpoints (72.5, 88.5) can never
    be hit by an Int target, so the integer bounds below match it exactly.
    Literally indexes the static ATLAS_SIZES tuple, so every subscript is
    constant-folded — no heap allocation per call.

    Range quirk kept from the old List scan: its (rung 12, diff 1000) seed
    could only be beaten by candidates < 1000 away, so a target outside
    every rung's ±1000 window (<= -988 or >= 1096) returned rung 12; the
    same guard reproduces that exactly.
    """
    if target <= -988 or target >= 1096:
        return ATLAS_SIZES[0]
    if target <= 13:  # midpoint(12, 14)
        return ATLAS_SIZES[0]
    if target <= 15:  # midpoint(14, 16)
        return ATLAS_SIZES[1]
    if target <= 17:  # midpoint(16, 18)
        return ATLAS_SIZES[2]
    if target <= 19:  # midpoint(18, 20)
        return ATLAS_SIZES[3]
    if target <= 21:  # midpoint(20, 22)
        return ATLAS_SIZES[4]
    if target <= 24:  # midpoint(22, 26)
        return ATLAS_SIZES[5]
    if target <= 29:  # midpoint(26, 32)
        return ATLAS_SIZES[6]
    if target <= 40:  # midpoint(32, 48)
        return ATLAS_SIZES[7]
    if target <= 52:  # midpoint(48, 56)
        return ATLAS_SIZES[8]
    if target <= 60:  # midpoint(56, 64)
        return ATLAS_SIZES[9]
    if target <= 72:  # midpoint(64, 81) = 72.5
        return ATLAS_SIZES[10]
    if target <= 88:  # midpoint(81, 96) = 88.5
        return ATLAS_SIZES[11]
    return ATLAS_SIZES[12]


# ---------------------------------------------------------------------------
# Minimal geometric types
# ---------------------------------------------------------------------------


struct Vec2(Copyable, ImplicitlyCopyable, Movable):
    var x: Float32
    var y: Float32

    def __init__(out self, x: Float64 = 0.0, y: Float64 = 0.0):
        self.x = Float32(x)
        self.y = Float32(y)


struct Rect(Copyable, ImplicitlyCopyable, Movable):
    var x: Float32
    var y: Float32
    var width: Float32
    var height: Float32

    def __init__(
        out self,
        x: Float64 = 0.0,
        y: Float64 = 0.0,
        w: Float64 = 0.0,
        h: Float64 = 0.0,
    ):
        self.x = Float32(x)
        self.y = Float32(y)
        self.width = Float32(w)
        self.height = Float32(h)


def _point_in_rect(px: Float64, py: Float64, r: Rect) -> Bool:
    """Local point-in-rect test"""
    var fx = Float32(px)
    var fy = Float32(py)
    if fx < r.x or fx >= r.x + r.width:
        return False
    if fy < r.y or fy >= r.y + r.height:
        return False
    return True


# ---------------------------------------------------------------------------
# Result struct
# ---------------------------------------------------------------------------


struct UIResult(Copyable, ImplicitlyCopyable, Movable):
    var hovered: Bool
    var clicked: Bool
    var bounds: Rect

    def __init__(
        out self,
        hovered: Bool = False,
        clicked: Bool = False,
        bounds: Rect = Rect(),
    ):
        self.hovered = hovered
        self.clicked = clicked
        self.bounds = bounds


# ---------------------------------------------------------------------------
# Key state helpers (libinput keyboard state)
# ---------------------------------------------------------------------------
# Keyboard handling: the main loop pumps Wayland key events into a frame-
# scoped ring inside WindowInput (platform/window.mojo). Every press the
# frame collected stays queued until the next poll clears it, so no event
# is lost when a frame runs long. The UI drains it through the helpers
# below: `key_pressed(K)` reports any press of K in the frame, and
# `char_pressed()` yields queued printable presses one call at a time.


struct UIContext:
    """Per-frame UI state: input, fonts, scale, layout cursor.

    Construct one per frame and pass it (mut) to every UI method.
    The cursor advances downward; `begin_panel`/`end_panel` push/pop
    a sub-region. All sizes are in design pixels; `ui_scale` converts
    them to screen pixels for both layout and drawing.

    Storage model (unchanged): the font ladder, Canvas, WindowInput and
    Gamepad live in heap boxes owned by main.mojo for the whole process
    lifetime; the context borrows them through raw pointers (struct
    copies of these types share COW/mask storage and have historically
    double-freed it). Consumers never touch the pointers: `canvas()`
    and `font()` return language-level reference views (single confined
    unsafe-offset deref below), and input/gamepad reads go through the
    methods at the top of the struct.
    """

    # Heap-box dependencies (main.mojo owns the boxes — see top of struct).
    # Underscore-private by convention; every external read routes through
    # the ref-returning accessors so no consumer derefs a pointer.
    var _fonts: Pointer[FontSet, MutUntrackedOrigin]
    var _canvas: Pointer[Canvas, MutUntrackedOrigin]
    var _input: Pointer[WindowInput, MutUntrackedOrigin]
    # Gamepad is optional (batch 1): None = no pad handled, gamepad binds inert.
    var _gamepad: Optional[Pointer[Gamepad, MutUntrackedOrigin]]
    var dt: Float64
    var mouse_pos: Vec2
    var mouse_pressed: Bool  # True on the frame the left button went down
    var mouse_down: Bool  # True while the left button is held
    # Touch-origin tracking (mirrors WindowInput; see its doc comment).
    # True while the active press came from a touch—used by screens that
    # scroll via drag (library list) to defer press-edge actions.
    var press_is_touch: Bool
    var touch_start: Vec2  # where the current touch drag began (screen px)
    var screen_w: Int  # Current window width (screen pixels)
    var screen_h: Int  # Current window height (screen pixels)
    var ui_scale: Float32  # screen_px = design_px * ui_scale (layout + dpi)
    var font_scale: Float32  # font_px = design_size * font_scale (no dpi, user multiplier)
    var cursor_x: Float32  # Current cursor X (screen px)
    var cursor_y: Float32  # Current cursor Y (screen px)
    var cursor_w: Float32  # Remaining width in the current panel (screen px)
    var line_h: Float32  # Height of the last element (screen px)
    var panel_stack: List[Float32]  # Saved cursor_x/w values for nesting
    var item_clicked: Bool  # True if any element consumed the click this frame
    var keybinds: Dict[String, List[List[Int]]]  # action -> resolved combos
    # char_pressed() drain cursor: next not-yet-yielded ring index (
    # frame-local — a fresh UIContext starts draining at 0). Only text
    # input consumes this.
    var char_cursor: Int
    # Spatial navigation (gamepad dpad / arrow keys). The engine state
    # lives in a NavState heap box owned by main (cross-frame); here:
    # the borrow + the frame's gate flags.
    var _nav: Optional[Pointer[NavState, MutUntrackedOrigin]]
    var nav_screen: Int  # current screen index (screen-change reset)
    var nav_active: Bool  # False while the settings rebind capture runs
    var nav_lr: Bool  # False when a screen owns left/right (player seek)

    def __init__(
        out self,
        fonts: Pointer[FontSet, MutUntrackedOrigin],
        canvas: Pointer[Canvas, MutUntrackedOrigin],
        input: Pointer[WindowInput, MutUntrackedOrigin],
        dt: Float64,
        screen_w: Int,
        screen_h: Int,
        var keybinds: Dict[String, List[List[Int]]],
        dpi_scale: Float64 = 1.0,
        font_multiplier: Float64 = 1.0,
        gamepad: Optional[Pointer[Gamepad, MutUntrackedOrigin]] = Optional[
            Pointer[Gamepad, MutUntrackedOrigin]
        ](),
        nav: Optional[Pointer[NavState, MutUntrackedOrigin]] = Optional[
            Pointer[NavState, MutUntrackedOrigin]
        ](),
        nav_screen: Int = -1,
        nav_active: Bool = True,
        nav_lr: Bool = True,
    ):
        self._fonts = fonts
        self._canvas = canvas
        self._input = input
        self._gamepad = gamepad
        self.dt = dt
        # libinput already merges touch into the mouse (TOUCH_DOWN/MOTION
        # simulate press/move/release on the primary slot), so the UI only
        # needs the pointer view; a touch tap surfaces as a normal click.
        # One confined pointer deref here; the frame snapshot fields then
        # read like plain fields for the rest of the ctor.
        ref inp = input[unsafe_offset=0]
        self.mouse_pos = Vec2(inp.mouse_x, inp.mouse_y)
        self.mouse_pressed = inp.mouse_pressed
        self.mouse_down = inp.mouse_down
        self.press_is_touch = inp.press_is_touch
        self.touch_start = Vec2(inp.touch_start_x, inp.touch_start_y)
        self.screen_w = screen_w
        self.screen_h = screen_h
        # Layout scale = min dimension ratio * dpi. Keeps UI proportional to
        # window size and crisp on HiDPI. Clamped to >= 0.5 so elements stay
        # usable on very small windows.
        var sx = Float32(screen_w) / Float32(DESIGN_W)
        var sy = Float32(screen_h) / Float32(DESIGN_H)
        var dim_scale = sx
        if sy < dim_scale:
            dim_scale = sy
        if dim_scale < 0.5:
            dim_scale = 0.5
        self.ui_scale = dim_scale * Float32(dpi_scale)
        if self.ui_scale < 0.5:
            self.ui_scale = 0.5
        # Font scale = dimension ratio only (NO dpi — the wl_shm buffer is at
        # physical resolution, so applying dpi here double-scales the baked
        # glyph atlases and makes text blurry). The user-configurable
        # font_multiplier lets users pick larger/smaller base font sizes.
        var fs = dim_scale * Float32(font_multiplier)
        if fs < 0.5:
            fs = 0.5
        self.font_scale = fs
        self.cursor_x = 0.0
        self.cursor_y = 0.0
        self.cursor_w = Float32(screen_w)
        self.line_h = 0.0
        self.panel_stack = List[Float32]()
        self.item_clicked = False
        self.char_cursor = 0
        self._nav = nav
        self.nav_screen = nav_screen
        self.nav_active = nav_active
        self.nav_lr = nav_lr
        self.keybinds = keybinds^
        # Spatial navigation consumes the frame's directional edges here —
        # before any screen draws — so widget activation flags are already
        # settled when the widgets render.
        self._nav_begin_frame()

    # ------------------------------------------------------------------
    # Dependency views — the ONLY pointer derefs in the facade
    # ------------------------------------------------------------------
    # Each access point below confines exactly one unsafe-offset deref;
    # screens/widgets consume plain views and calls instead:
    #
    #   ui.canvas().fill_rect(...)              # mutable view of boxed Canvas
    #   ref atlas = ui.font(22)                 # read-only atlas view (metrics)
    #   ui.draw_text(t, x, baseline, 22, color) # atlas resolved internally
    #
    # This toolchain supports ref-valued function returns (probed) but NOT
    # reference-typed struct fields or ref params — which is why the raw
    # pointers remain the storage and each view is minted per call.

    def canvas(mut self) -> ref[MutAnyOrigin] Canvas:
        """Mutable view into the heap-boxed Canvas (main owns the box and
        refreshes the frame pointer before each draw pass)."""
        return self._canvas[unsafe_offset=0]

    def _atlas_ptr(
        mut self, design_size: Int
    ) -> Pointer[TextAtlas, MutUntrackedOrigin]:
        """Raw ladder handle — private bridge to Canvas.draw_text, which
        (on this toolchain) cannot take reference-typed params. Use
        `font()` for anything consumers do (metrics reads)."""
        return self._fonts[unsafe_offset=0].get_atlas(
            self._atlas_px(design_size)
        )

    def font(mut self, design_size: Int) -> ref[ImmutAnyOrigin] TextAtlas:
        """Read-only view of the baked glyph atlas nearest the design size.

        Origin is immutable because atlases are baked once and only read
        (stale-slot/COW rules in ui/font.mojo) — mutation through the
        view is rejected at compile time."""
        return self._atlas_ptr(design_size)[unsafe_offset=0]

    def draw_text(
        mut self, text: String, x: Float64, y: Float64, size: Int, color: Color
    ):
        """Draw `text` with its BASELINE at screen-px (x, y), using the
        ladder atlas baked for `size`. The atlas pointer is resolved here
        (single confined deref) so consumers pass no pointers."""
        self._canvas[unsafe_offset=0].draw_text(
            self._atlas_ptr(size), text, x, y, color
        )

    def captured_gamepad_button(self) -> Int:
        """Pad button with a press edge this frame (rebinding capture), or -1.

        Returns -1 when no pad is connected (gamepad binds inert — batch 1
        semantics) or another window has keyboard focus — the same
        honor-keyboard-focus gate the keybind helpers apply."""
        if not self._gamepad:
            return -1
        if not self._input[unsafe_offset=0].focused:
            return -1
        ref pad = self._gamepad.value()[unsafe_offset=0]
        return pad.last_button()

    # ------------------------------------------------------------------
    # Spatial navigation engine (gamepad dpad / arrow keys)
    # ------------------------------------------------------------------

    def _nav_begin_frame(mut self):
        """Frame-start nav processing: swap the rect lists, reset focus
        across screen changes, read the directional keybinds (edge +
        held-repeat), and settle the activate flag.

        Runs from the ctor, once per frame, before any screen draws;
        movement math uses LAST frame's rects (draw order is
        deterministic, so index i names the same element frame to frame —
        and a list scrolled by exactly one row names the next row under
        the same index, which is the scrolling-list cursor behavior)."""
        if not self._nav:
            return
        ref ns = self._nav.value()[unsafe_offset=0]

        # Swap: last frame's registrations become the movement source;
        # cur starts empty for this frame's draws. Field-to-field moves
        # aren't expressible through the box pointer (no origin), so the
        # swap is copies — tens of small rects per frame, trivial cost.
        ns.prev_nodes = ns.cur_nodes.copy()
        ns.prev_regions = ns.cur_regions.copy()
        ns.prev_hints = ns.cur_hints.copy()
        ns.cur_nodes.clear()
        ns.cur_regions.clear()
        ns.cur_hints.clear()
        ns.prev_screen = ns.cur_screen
        ns.cur_screen = self.nav_screen

        ns.activate = False
        ns.edge_dir = -1

        # Pointer/touch movement hands focus back to the pointer: gamepad
        # focus rings must not sit under an active mouse/touch session.
        if ns.have_mouse:
            var mdx = Float64(self.mouse_pos.x) - Float64(ns.last_mouse.x)
            var mdy = Float64(self.mouse_pos.y) - Float64(ns.last_mouse.y)
            if mdx * mdx + mdy * mdy > 1.0:
                ns.focused = -1
        ns.last_mouse = self.mouse_pos
        ns.have_mouse = True

        # Same-screen gate: movement math must not run across a screen
        # change (the previous rects belong to another screen).
        if ns.prev_screen != self.nav_screen or ns.prev_screen < 0:
            ns.focused = -1
            for i in range(4):
                ns.repeat_t[i] = 0.0
            return

        # Drop focus that points past the node list (layout shrank).
        if ns.focused >= len(ns.prev_nodes):
            ns.focused = -1

        if not self.nav_active:
            # Rebind capture owns the pad this frame: navigation inert
            # (the capture consumes the press instead).
            for i in range(4):
                ns.repeat_t[i] = 0.0
            return

        # Directions this frame: edge (just pressed) and held (repeat).
        # Left/right are screen-gated (the player's base layout owns them
        # for the ±30s seeks).
        var dirs = List[Bool]()
        dirs.append(self.check_keybind("nav_up"))
        dirs.append(self.check_keybind("nav_down"))
        dirs.append(self.check_keybind("nav_left"))
        dirs.append(self.check_keybind("nav_right"))

        # The select action activates the focused element this frame.
        ns.activate = self.check_keybind("select")

        for dir in range(4):
            # Left/right honor the screen gate fully: no step, no repeat.
            if dir >= NAV_LEFT and not self.nav_lr:
                ns.repeat_t[dir] = 0.0
                continue
            if dirs[dir]:
                self._nav_step(dir)
                ns.repeat_t[dir] = NAV_REPEAT_DELAY_S
            elif self._nav_held(dir):
                var t = ns.repeat_t[dir] - self.dt
                if t <= 0.0:
                    self._nav_step(dir)
                    t = NAV_REPEAT_RATE_S
                ns.repeat_t[dir] = t
            else:
                ns.repeat_t[dir] = 0.0

    def _nav_held(self, dir: Int) -> Bool:
        """Held-state test for a nav direction's combos (gates the repeat
        cadence).

        Keyboard keys measure FRESH press events, never the sticky
        last-event heuristic: the compositor's auto-repeat refreshes held
        keys as new press events and a release ends them, so a single tap
        cannot phantom-repeat. Gamepad keys use the pad's true down-state
        (the evdev layer has no auto-repeat)."""
        try:
            ref combos = self.keybinds[_nav_action_for(dir)]
            for i in range(len(combos)):
                ref combo = combos[i]
                if len(combo) == 0:
                    continue
                var held_ok = True
                for j in range(len(combo)):
                    var code = combo[j]
                    if code >= GAMEPAD_SENTINEL:
                        if not self._is_down(code):
                            held_ok = False
                            break
                    else:
                        # keyboard: event-driven hold (auto-repeat refreshes)
                        if not self._key_pressed(code):
                            held_ok = False
                            break
                if held_ok:
                    return True
        except:
            pass
        return False

    def _nav_step(mut self, dir: Int):
        """One navigation step in `dir` from the focused node.

        Resolution order: same-region candidate; else (vertical move,
        focused node lies in a scroll region, and the screen registered
        more content that way) hold focus and raise the edge flag the
        screen consumes to scroll; else any-region candidate; else
        nothing. Unfocused: home onto the node nearest the window
        center (pick-up-and-play — the first press selects something
        sane)."""
        if not self._nav:
            return
        ref ns = self._nav.value()[unsafe_offset=0]

        if ns.focused < 0:
            if len(ns.prev_nodes) > 0:
                ns.focused = _nav_home(ns, self.screen_w, self.screen_h)
            return

        var focused_region = ns.prev_regions[ns.focused]
        var fx = (
            Float64(ns.prev_nodes[ns.focused].x)
            + Float64(ns.prev_nodes[ns.focused].width) / 2.0
        )
        var fy = (
            Float64(ns.prev_nodes[ns.focused].y)
            + Float64(ns.prev_nodes[ns.focused].height) / 2.0
        )
        var vertical = dir == NAV_UP or dir == NAV_DOWN

        # Scroll-region members stay inside their region (a row's SAVE /
        # PLAY and the next row beat far-away chrome), hold at the edge
        # when scrollable content sits beyond it, and only then escape.
        # Chrome (no hint) picks across the whole screen — free entry
        # into the content, so a walk never traps in the header.
        var move = -1
        if focused_region in ns.prev_hints:
            move = self._nav_pick(fx, fy, dir, focused_region, True)
            if move < 0 and vertical:
                # Hold the cursor for the screen to scroll; the next
                # registration pass names the next row. Dict.get is
                # non-raising (returns the default when absent).
                var hint = ns.prev_hints.get(focused_region, ScrollHint())
                var content_that_way = hint.has_above
                if dir == NAV_DOWN:
                    content_that_way = hint.has_below
                if content_that_way:
                    ns.edge_dir = dir
                    ns.edge_region = focused_region
                    return
        if move < 0:
            move = self._nav_pick(fx, fy, dir, focused_region, False)
        if move >= 0:
            ns.focused = move

    def _nav_pick(
        self, fx: Float64, fy: Float64, dir: Int, region: Int, same_only: Bool
    ) -> Int:
        """_spatial_best over the registered nodes, optionally restricted
        to one region; returns the GLOBAL node index (or -1)."""
        if not self._nav:
            return -1
        ref ns = self._nav.value()[unsafe_offset=0]
        var cands = List[Rect]()
        var cand_ids = List[Int]()
        for i in range(len(ns.prev_nodes)):
            if i == ns.focused:
                continue
            if same_only and ns.prev_regions[i] != region:
                continue
            cands.append(ns.prev_nodes[i].copy())
            cand_ids.append(i)
        if len(cands) == 0:
            return -1
        var k = _spatial_best(cands, fx, fy, dir)
        if k < 0:
            return -1
        return cand_ids[k]

    def nav_node(mut self, r: Rect, region: Int = NAV_REGION_DEFAULT) -> Int:
        """Register an interactive rect for this frame; returns its nav id
        (also valid for the manual `nav_activated`/`nav_focused` checks).
        Call exactly once per element per frame — draw order defines ids.
        A negative region means NOT focusable (disabled buttons, unwired
        stubs): nothing is registered and the -1 id never focuses or
        activates."""
        if not self._nav:
            return -1
        if region < 0:
            return -1
        ref ns = self._nav.value()[unsafe_offset=0]
        ns.cur_nodes.append(r)
        ns.cur_regions.append(region)
        return len(ns.cur_nodes) - 1

    def nav_focused(self, nav_id: Int) -> Bool:
        """True when this element holds the gamepad focus."""
        if not self._nav or nav_id < 0:
            return False
        ref ns = self._nav.value()[unsafe_offset=0]
        return ns.focused == nav_id

    def nav_focused_id(self) -> Int:
        """The focused nav id this frame (-1 = none); screens use it to
        find which of their registered nodes is focused."""
        if not self._nav:
            return -1
        ref ns = self._nav.value()[unsafe_offset=0]
        return ns.focused

    def nav_activated(self, nav_id: Int) -> Bool:
        """True when the focused element should activate this frame
        (select action: A face button / Enter)."""
        if not self._nav or nav_id < 0:
            return False
        ref ns = self._nav.value()[unsafe_offset=0]
        return ns.activate and ns.focused == nav_id

    def nav_reset(mut self):
        """Drop focus — screens call it on structural changes (overlay
        open/close, phase swap) so no stale ring survives the change."""
        if not self._nav:
            return
        ref ns = self._nav.value()[unsafe_offset=0]
        ns.focused = -1

    def nav_scroll_hint(
        mut self, region: Int, has_above: Bool, has_below: Bool
    ):
        """Register a scroll region's has-more-content state for this
        frame (consumed by the engine on the next frame's begin)."""
        if not self._nav:
            return
        ref ns = self._nav.value()[unsafe_offset=0]
        ns.cur_hints[region] = ScrollHint(has_above, has_below)

    def nav_scroll_edge(self, region: Int, dir: Int) -> Bool:
        """True when this frame's nav step hit the focused region's edge
        in `dir` and the region has scrollable content that way — the
        screen's cue to scroll (focus holds its window position; the
        index shift carries it to the next row)."""
        if not self._nav:
            return False
        ref ns = self._nav.value()[unsafe_offset=0]
        return ns.edge_dir == dir and ns.edge_region == region

    def focus_ring(mut self, r: Rect):
        """Focus outline for the spatial-nav focused element (screens call
        it for manual nodes; widget primitives draw their own)."""
        self.canvas().outline_rect_rounded(
            Float64(r.x),
            Float64(r.y),
            Float64(r.width),
            Float64(r.height),
            0.06,
            2.5,
            BORDER_FOCUS,
        )

    # ------------------------------------------------------------------
    # Keyboard helpers (libinput state)
    # ------------------------------------------------------------------

    def _key_pressed(self, code: Int) -> Bool:
        """True if `code` was pressed this frame (press-edge event)."""
        ref inp = self._input[unsafe_offset=0]
        return inp.frame_key_pressed(code)

    def _key_down(self, code: Int) -> Bool:
        """Approximate key-held test from the event stream.

        The Wayland shim queues discrete events only, so a true held-down
        map does not exist yet. A modifier is treated as held while the
        most recent key event (`last_event_key`, cross-frame) is still
        this code OR while the code had a press edge this frame (coarse,
        but single-key combos — the overwhelming majority in Quire — are
        exact).
        """
        ref inp = self._input[unsafe_offset=0]
        if Int(inp.last_event_key) == code:
            return True
        return self._key_pressed(code)

    def _is_pressed(self, code: Int) -> Bool:
        """Dispatch a keycode to the right pressed test.

        Keyboard codes are plain GLFW keycodes; gamepad codes are stored
        as GAMEPAD_SENTINEL + button and resolve through the evdev gamepad
        backend (main owns the heap-boxed Gamepad; None = no pad handled).
        """
        if code >= GAMEPAD_SENTINEL:
            # Gamepad binds only fire while the window has keyboard focus
            # (otherwise the pad would control the app from another window).
            if not self._gamepad:
                return False
            if not self._input[unsafe_offset=0].focused:
                return False
            ref pad = self._gamepad.value()[unsafe_offset=0]
            return pad.was_pressed(code - GAMEPAD_SENTINEL)
        return self._key_pressed(code)

    def _is_down(self, code: Int) -> Bool:
        if code >= GAMEPAD_SENTINEL:
            if not self._gamepad:
                return False
            if not self._input[unsafe_offset=0].focused:
                return False
            ref pad = self._gamepad.value()[unsafe_offset=0]
            return pad.is_down(code - GAMEPAD_SENTINEL)
        return self._key_down(code)

    def check_keybind(self, action: String) -> Bool:
        """Return True if any combo for this action was triggered this frame.

        A combo is a List[Int] of keycodes. The last keycode is the trigger
        (checked via the pressed edge); all preceding keys are modifiers
        that must be held down. Gamepad codes are stored as
        GAMEPAD_SENTINEL + button_code to distinguish them from keyboard
        keycodes. Returns False if the action has no combos.
        """
        try:
            ref combos = self.keybinds[action]
            if len(combos) == 0:
                return False
            for i in range(len(combos)):
                ref combo = combos[i]
                if len(combo) == 0:
                    continue
                # Last key must be pressed this frame.
                var trigger = combo[len(combo) - 1]
                if not self._is_pressed(trigger):
                    continue
                # All preceding keys must be held down.
                var modifiers_ok = True
                for j in range(len(combo) - 1):
                    if not self._is_down(combo[j]):
                        modifiers_ok = False
                        break
                if modifiers_ok:
                    return True
        except:
            pass
        return False

    def key_pressed(self, code: Int) -> Bool:
        """Public pressed-edge test (used by screens for Enter/Escape/etc)."""
        return self._key_pressed(code)

    def key_down(self, code: Int) -> Bool:
        """Held-key approximation (see _key_down notes)."""
        return self._key_down(code)

    def char_pressed(mut self) -> Int32:
        """Next printable-char press queued this frame, or 0 — one per call.

        Repeated calls drain the frame's ring in arrival order, so a burst
        typed across a slow frame arrives intact instead of collapsing to
        its last key. Non-printable presses are skipped here but stay
        visible to key_pressed(); the cursor is frame-local (a fresh
        UIContext drains from the oldest event)."""
        ref inp = self._input[unsafe_offset=0]
        for j in range(self.char_cursor, inp.key_ring_count):
            var code = Int(inp.frame_key_press(j))
            if code >= 32 and code <= 126:
                self.char_cursor = j + 1
                return Int32(code)
        self.char_cursor = inp.key_ring_count
        return 0

    # ------------------------------------------------------------------
    # Scaling helpers — convert design px to screen px
    # ------------------------------------------------------------------

    def s(mut self, design_px: Float64) -> Float32:
        """Scale a design-pixel scalar to screen pixels."""
        return Float32(design_px) * self.ui_scale

    def rect(mut self, x: Float64, y: Float64, w: Float64, h: Float64) -> Rect:
        """Build a Rect from design-pixel coordinates."""
        return Rect(
            Float64(Float32(x) * self.ui_scale),
            Float64(Float32(y) * self.ui_scale),
            Float64(Float32(w) * self.ui_scale),
            Float64(Float32(h) * self.ui_scale),
        )

    # ------------------------------------------------------------------
    # Font ladder — pick the baked atlas nearest to the target pixel size
    # ------------------------------------------------------------------

    def _atlas_px(mut self, design_size: Int) -> Int:
        """Atlas pixel size for a design-pixel font size (nearest ladder step).

        Mirrors the old Font ladder (font_12..font_96) but indexes by the
        RENDER size (design * font_scale), since the baked atlases draw at
        their native pixel size. The walk itself is `_ladder_nearest` —
        static ATLAS_SIZES subscripts, no heap allocation per call.
        """
        var target = Int(Float32(design_size) * self.font_scale)
        return _ladder_nearest(target)

    def font_px(mut self, design_size: Int) -> Float32:
        """Render font size in screen pixels (scaled by font_scale, not dpi)."""
        return Float32(design_size) * self.font_scale

    def text_w_design(mut self, measured_x: Float32) -> Float64:
        """Convert a measured text width (screen px) to design px.

        Text is measured in font_scale space (no dpi), so divide by font_scale.
        """
        return Float64(measured_x) / Float64(self.font_scale)

    def text_h_design(mut self, measured_y: Float32) -> Float64:
        """Convert a measured text height (screen px) to design px."""
        return Float64(measured_y) / Float64(self.font_scale)

    # ------------------------------------------------------------------
    # Layout cursor — vertical flow with panel push/pop
    # ------------------------------------------------------------------

    def move_to(mut self, x: Float64, y: Float64):
        """Move the cursor to a design-pixel position."""
        self.cursor_x = Float32(x) * self.ui_scale
        self.cursor_y = Float32(y) * self.ui_scale
        self.cursor_w = Float32(self.screen_w) - self.cursor_x

    def advance(mut self, h: Float64):
        """Advance the cursor downward by h design pixels."""
        var sh = Float32(h) * self.ui_scale
        self.cursor_y += sh
        self.line_h = sh

    def spacer(mut self, h: Float64):
        """Add vertical space (design px) without drawing."""
        self.cursor_y += Float32(h) * self.ui_scale

    def begin_panel(mut self, x: Float64, y: Float64, w: Float64, h: Float64):
        """Push a sub-panel at design-pixel coords. Cursor enters it."""
        self.panel_stack.append(self.cursor_x)
        self.panel_stack.append(self.cursor_w)
        self.cursor_x = Float32(x) * self.ui_scale
        self.cursor_y = Float32(y) * self.ui_scale
        self.cursor_w = Float32(w) * self.ui_scale

    def end_panel(mut self):
        """Pop the most recent panel. Restores parent cursor x/w."""
        if len(self.panel_stack) >= 2:
            self.cursor_w = self.panel_stack.pop()
            self.cursor_x = self.panel_stack.pop()

    def indent(mut self, dx: Float64):
        """Indent the cursor right by dx design px (shrinks width)."""
        var sx = Float32(dx) * self.ui_scale
        self.cursor_x += sx
        self.cursor_w -= sx

    # ------------------------------------------------------------------
    # Element helpers
    # ------------------------------------------------------------------

    def _hit(mut self, r: Rect) -> Bool:
        return _point_in_rect(
            Float64(self.mouse_pos.x), Float64(self.mouse_pos.y), r
        )

    def _clicked(mut self, r: Rect) -> Bool:
        """True if mouse was pressed inside r this frame.

        For immediate-mode we treat `mouse_pressed` (button went down)
        as the click event — drag state is tracked separately by callers.
        """
        if not self.mouse_pressed:
            return False
        if self.item_clicked:
            return False
        if self._hit(r):
            self.item_clicked = True
            return True
        return False

    def _draw_text(
        mut self, text: String, x: Float64, y: Float64, size: Int, color: Color
    ):
        """Draw text with the atlas ladder. (x, y) is the TOP-left in design
        px (raylib convention); convert to a baseline for the rasterizer.

        The atlas rung is resolved ONCE from the design size and passed to
        both the metrics read and the draw — so measurement, placement, and
        rendering all hit the identical rung this function would reach.
        """
        var x_screen = Float64(Float32(x) * self.ui_scale)
        var y_top_screen = Float64(Float32(y) * self.ui_scale)
        ref atlas = self.font(size)
        self.draw_text(
            text,
            x_screen,
            y_top_screen + Float64(atlas.ascent),
            size,
            color,
        )

    def _measure_text(mut self, text: String, size: Int) -> Vec2:
        """Measured text size at the ladder's native pixels."""
        ref atlas = self.font(size)
        var w = Float32(atlas.text_width(text))
        return Vec2(Float64(w), Float64(atlas.line_height))

    # ------------------------------------------------------------------
    # Primitive: label / text
    # ------------------------------------------------------------------

    def label(mut self, text: String, size: Int, color: Color):
        """Draw text at the cursor. Advances cursor by one line."""
        self._draw_text(
            text,
            Float64(self.cursor_x) / Float64(self.ui_scale),
            Float64(self.cursor_y) / Float64(self.ui_scale),
            size,
            color,
        )
        self.advance(Float64(size) + 4.0)

    def label_centered(mut self, text: String, size: Int, color: Color):
        """Draw centered text across the current panel width."""
        var meas = self._measure_text(text, size)
        var design_w = Float64(self.cursor_w) / Float64(self.ui_scale)
        var text_w_design = self.text_w_design(meas.x)
        var x = (
            Float64(self.cursor_x) / Float64(self.ui_scale)
            + (design_w - text_w_design) / 2.0
        )
        self._draw_text(
            text,
            x,
            Float64(self.cursor_y) / Float64(self.ui_scale),
            size,
            color,
        )
        self.advance(Float64(size) + 4.0)

    # ------------------------------------------------------------------
    # Primitive: button
    # ------------------------------------------------------------------

    def _label_screen_w(mut self, label: String, fsize: Int) -> Float64:
        """Rendered label width in screen px at the ladder's native size."""
        ref atlas = self.font(fsize)
        return Float64(atlas.text_width(label))

    def fitted_button_w(
        mut self, label: String, fsize: Int, w: Float64
    ) -> Float64:
        """Design-px width a button will occupy (grow to fit label + padding).

        Public so call sites that place buttons right-to-left or in fixed
        strides can reserve the grown width up front, keeping neighbors
        from overlapping when button_at widens a rect.
        """
        var pad_screen = Float64(self.s(BUTTON_PAD_X))
        var needed = (
            self._label_screen_w(label, fsize) + 2.0 * pad_screen
        ) / Float64(self.ui_scale)
        return max(w, needed)

    def button(
        mut self,
        label: String,
        h: Float64 = 36.0,
        bg: Color = GREEN,
        fg: Color = ACCENT_DARK,
        hover: Color = Color(140, 192, 88, 255),
        action: String = "",
        region: Int = NAV_REGION_DEFAULT,
    ) -> UIResult:
        """Draw a button at the cursor. Returns interaction state.

        If action is non-empty, the button also activates when its keybind
        combo is triggered (see UIContext.check_keybind). Region tags the
        element for spatial navigation (0 = chrome, distinct ids mark a
        screen's scrollable list).
        """
        var fsize = 22
        if h >= 40.0:
            fsize = 32
        if h >= 80.0:
            fsize = 56
        var design_w = self.fitted_button_w(
            label, fsize, Float64(self.cursor_w) / Float64(self.ui_scale)
        )
        var r = self.rect(
            Float64(self.cursor_x) / Float64(self.ui_scale),
            Float64(self.cursor_y) / Float64(self.ui_scale),
            design_w,
            h,
        )
        var result = self._interactive_button(
            label, r, fsize, bg, fg, hover, action, region
        )
        self.advance(h + 10.0)
        return result

    def button_fixed(
        mut self,
        label: String,
        w: Float64,
        h: Float64,
        bg: Color = GREEN,
        fg: Color = ACCENT_DARK,
        hover: Color = Color(140, 192, 88, 255),
        action: String = "",
        region: Int = NAV_REGION_DEFAULT,
    ) -> UIResult:
        """Draw a fixed-width button at the cursor (does not fill panel).

        If action is non-empty, the button also activates when its keybind
        combo is triggered.
        """
        var fsize = 22
        if h >= 42.0:
            fsize = 42
        if h >= 66.0:
            fsize = 56
        var fit_w = self.fitted_button_w(label, fsize, w)
        var design_x = Float64(self.cursor_x) / Float64(self.ui_scale)
        var design_y = Float64(self.cursor_y) / Float64(self.ui_scale)
        var r = self.rect(design_x, design_y, fit_w, h)
        var result = self._interactive_button(
            label, r, fsize, bg, fg, hover, action, region
        )
        # Advance cursor by width (so next element goes to the right)
        self.cursor_x += result.bounds.width
        self.cursor_w -= result.bounds.width
        return result

    def button_at(
        mut self,
        label: String,
        x: Float64,
        y: Float64,
        w: Float64,
        h: Float64,
        bg: Color = GREEN,
        fg: Color = ACCENT_DARK,
        hover: Color = Color(140, 192, 88, 255),
        action: String = "",
        region: Int = NAV_REGION_DEFAULT,
    ) -> UIResult:
        """Draw a button at an absolute design-pixel position (cursor untouched).

        If action is non-empty, the button also activates when its keybind
        combo is triggered.
        """
        var fsize = 22
        if h >= 48.0:
            fsize = 26
        if h >= 80.0:
            fsize = 56
        var fit_w = self.fitted_button_w(label, fsize, w)
        var r = self.rect(x, y, fit_w, h)
        return self._interactive_button(
            label, r, fsize, bg, fg, hover, action, region
        )

    def _interactive_button(
        mut self,
        label: String,
        r: Rect,
        fsize: Int,
        bg: Color,
        fg: Color,
        hover: Color,
        action: String,
        region: Int,
    ) -> UIResult:
        """Shared button body: spatial-nav registration + focus ring +
        select activation, then the usual hover/click/keybind handling.
        All three button entry points funnel through here."""
        var nav_id = self.nav_node(r, region)
        var focused = self.nav_focused(nav_id)
        var hovered = self._hit(r)
        var clicked = self._clicked(r)
        if focused and self.nav_activated(nav_id):
            clicked = True
            self.item_clicked = True
        if action.byte_length() > 0 and self.check_keybind(action):
            clicked = True

        var color = bg
        if hovered:
            color = hover

        self.canvas().fill_rect_rounded(
            Float64(r.x),
            Float64(r.y),
            Float64(r.width),
            Float64(r.height),
            0.12,
            color,
        )

        self._draw_button_label(label, r, fsize, fg)
        if focused:
            self.focus_ring(r)
        return UIResult(hovered=hovered, clicked=clicked, bounds=r)

    def _draw_button_label(
        mut self, label: String, r: Rect, fsize: Int, fg: Color
    ):
        """Center a label inside a button rect at the ladder's native size."""
        ref atlas = self.font(fsize)
        var tw = Float64(atlas.text_width(label))
        var th = Float64(atlas.line_height)
        var tx = Float64(r.x) + (Float64(r.width) - tw) / 2.0
        var ty = Float64(r.y) + (Float64(r.height) - th) / 2.0
        self.draw_text(label, tx, ty + Float64(atlas.ascent), fsize, fg)

    # ------------------------------------------------------------------
    # Primitive: panel / card background
    # ------------------------------------------------------------------

    def card(
        mut self,
        x: Float64,
        y: Float64,
        w: Float64,
        h: Float64,
        bg: Color = CARD_BG,
        roundness: Float64 = 0.04,
    ):
        """Draw a card background at design-pixel coords. Does not move cursor.
        """
        var r = self.rect(x, y, w, h)
        self.canvas().fill_rect_rounded(
            Float64(r.x),
            Float64(r.y),
            Float64(r.width),
            Float64(r.height),
            roundness,
            bg,
        )

    def panel_bg(
        mut self, x: Float64, y: Float64, w: Float64, h: Float64, bg: Color
    ):
        """Draw a solid rectangle background."""
        var r = self.rect(x, y, w, h)
        self.canvas().fill_rect(
            Float64(r.x), Float64(r.y), Float64(r.width), Float64(r.height), bg
        )

    def panel_bg_gradient(
        mut self,
        x: Float64,
        y: Float64,
        w: Float64,
        h: Float64,
        top: Color,
        bottom: Color,
    ):
        """Draw a vertical gradient rectangle background (design-px coords)."""
        var r = self.rect(x, y, w, h)
        self.canvas().fill_rect_gradient(
            Float64(r.x),
            Float64(r.y),
            Float64(r.width),
            Float64(r.height),
            top,
            bottom,
        )

    # ------------------------------------------------------------------
    # Primitive: slider (progress / volume)
    # ------------------------------------------------------------------

    def slider(
        mut self,
        x: Float64,
        y: Float64,
        w: Float64,
        h: Float64,
        value: Float64,
        vmin: Float64 = 0.0,
        vmax: Float64 = 1.0,
        track_bg: Color = SLIDER_BG,
        fill_bg: Color = SLIDER_FILL,
    ) -> UIResult:
        """Draw a horizontal slider at design coords. Returns interaction.

        Caller owns `value`. If `clicked` is true, compute new value from
        mouse_x via `slider_value_from_mouse`. If `hovered` and mouse_down
        (dragging), also compute new value.
        """
        var r = self.rect(x, y, w, h)
        var hovered = self._hit(r)
        var clicked = self._clicked(r)

        # Track background
        self.canvas().fill_rect_rounded(
            Float64(r.x),
            Float64(r.y),
            Float64(r.width),
            Float64(r.height),
            0.5,
            track_bg,
        )

        # Fill
        var range = vmax - vmin
        var pct = Float32(0.0)
        if range > 0.0:
            pct = Float32((value - vmin) / range)
        if pct < 0.0:
            pct = 0.0
        elif pct > 1.0:
            pct = 1.0

        if pct > 0.0:
            self.canvas().fill_rect_rounded(
                Float64(r.x),
                Float64(r.y),
                Float64(r.width) * Float64(pct),
                Float64(r.height),
                0.5,
                fill_bg,
            )

        # Handle
        var handle_r = self.s(7.0)
        var handle_x = r.x + r.width * pct
        self.canvas().fill_rect_rounded(
            Float64(handle_x - handle_r),
            Float64(r.y + r.height / 2.0 - handle_r),
            Float64(handle_r * 2.0),
            Float64(handle_r * 2.0),
            0.5,
            GREEN,
        )

        return UIResult(hovered=hovered, clicked=clicked, bounds=r)

    def slider_value_from_mouse(
        mut self, r: Rect, mouse_x: Float32, vmin: Float64, vmax: Float64
    ) -> Float64:
        """Compute a new slider value from mouse X position."""
        var pct = Float64(0.0)
        if r.width > 0.0:
            pct = Float64(mouse_x - r.x) / Float64(r.width)
        if pct < 0.0:
            pct = 0.0
        elif pct > 1.0:
            pct = 1.0
        return vmin + pct * (vmax - vmin)

    # ------------------------------------------------------------------
    # Primitive: selectable list row
    # ------------------------------------------------------------------

    def selectable_row(
        mut self,
        x: Float64,
        y: Float64,
        w: Float64,
        h: Float64,
        selected: Bool,
        bg: Color = LIB_CARD_BG,
        selected_bg: Color = SELECTED_BG,
        region: Int = NAV_REGION_DEFAULT,
    ) -> UIResult:
        """Draw a clickable card row at design coords. Returns interaction.

        Spatial-nav: the row registers itself; A (select) on the focused
        row surfaces as `clicked`."""
        var r = self.rect(x, y, w, h)
        var nav_id = self.nav_node(r, region)
        var focused = self.nav_focused(nav_id)
        var hovered = self._hit(r)
        var clicked = self._clicked(r)
        if focused and self.nav_activated(nav_id):
            clicked = True
            self.item_clicked = True

        var color = bg
        if selected:
            color = selected_bg

        self.canvas().fill_rect_rounded(
            Float64(r.x),
            Float64(r.y),
            Float64(r.width),
            Float64(r.height),
            0.04,
            color,
        )
        if focused:
            self.focus_ring(r)
        return UIResult(hovered=hovered, clicked=clicked, bounds=r)

    # ------------------------------------------------------------------
    # Scissor helpers
    # ------------------------------------------------------------------

    def begin_clip(mut self, x: Float64, y: Float64, w: Float64, h: Float64):
        var sx = Int(Float32(x) * self.ui_scale)
        var sy = Int(Float32(y) * self.ui_scale)
        var sw = Int(Float32(w) * self.ui_scale)
        var sh = Int(Float32(h) * self.ui_scale)
        self.canvas().begin_clip(sx, sy, sw, sh)

    def end_clip(mut self):
        self.canvas().end_clip()
