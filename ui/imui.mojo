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
from platform.gamepad import Gamepad, null_gamepad_ptr
from ui.font import FontSet
from platform.text import TextAtlas
from resources.keys import GAMEPAD_SENTINEL
from resources.palette import (
    ACCENT_DARK,
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
# Keyboard handling: the main loop pumps libinput events into an WindowInput
# before building the UIContext. WindowInput tracks last_key + pressed-edge
# only (single event granularity), which matches how the UI consumes keys:
# one trigger per action per frame.


struct UIContext:
    """Per-frame UI state: input, fonts, scale, layout cursor.

    Construct one per frame and pass it (mut) to every UI method.
    The cursor advances downward; `begin_panel`/`end_panel` push/pop
    a sub-region. All sizes are in design pixels; `ui_scale` converts
    them to screen pixels for both layout and drawing.
    """

    var fonts: Pointer[FontSet, MutUntrackedOrigin]
    var canvas: Pointer[Canvas, MutUntrackedOrigin]
    var input: Pointer[WindowInput, MutUntrackedOrigin]
    var gamepad: Pointer[Gamepad, MutUntrackedOrigin]
    var dt: Float64
    var mouse_pos: Vec2
    var mouse_pressed: Bool  # True on the frame the left button went down
    var mouse_down: Bool  # True while the left button is held
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
        gamepad: Pointer[Gamepad, MutUntrackedOrigin] = null_gamepad_ptr(),
    ):
        self.fonts = fonts
        self.canvas = canvas
        self.input = input
        self.gamepad = gamepad
        self.dt = dt
        # libinput already merges touch into the mouse (TOUCH_DOWN/MOTION
        # simulate press/move/release on the primary slot), so the UI only
        # needs the pointer view; a touch tap surfaces as a normal click.
        self.mouse_pos = Vec2(
            input[unsafe_offset=0].mouse_x, input[unsafe_offset=0].mouse_y
        )
        self.mouse_pressed = input[unsafe_offset=0].mouse_pressed
        self.mouse_down = input[unsafe_offset=0].mouse_down
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
        self.keybinds = keybinds^

    # ------------------------------------------------------------------
    # Keyboard helpers (libinput state)
    # ------------------------------------------------------------------

    def _key_pressed(self, code: Int) -> Bool:
        """True if `code` was pressed this frame (pressed-edge event)."""
        if not self.input[unsafe_offset=0].last_key_pressed:
            return False
        return Int(self.input[unsafe_offset=0].last_key) == code

    def _key_down(self, code: Int) -> Bool:
        """Approximate key-held test from the event stream.

        The libinput shim tracks the last key event only, so a true
        held-down map does not exist yet. A modifier is treated as held
        while the most recent key event for it is still the last one seen
        OR while any key activity is present (coarse, but single-key
        combos — the overwhelming majority in Quire — are exact).
        """
        if Int(self.input[unsafe_offset=0].last_key) == code:
            return True
        return self._key_pressed(code)

    def _is_pressed(self, code: Int) -> Bool:
        """Dispatch a keycode to the right pressed test.

        Keyboard codes are plain GLFW keycodes; gamepad codes are stored
        as GAMEPAD_SENTINEL + button and resolve through the evdev gamepad
        backend (main owns the heap-boxed Gamepad; null = no pad open).
        """
        if code >= GAMEPAD_SENTINEL:
            # Gamepad binds only fire while the window has keyboard focus
            # (otherwise the pad would control the app from another window).
            if (
                Int(self.gamepad) == 0
                or not self.input[unsafe_offset=0].focused
            ):
                return False
            return self.gamepad[unsafe_offset=0].was_pressed(
                code - GAMEPAD_SENTINEL
            )
        return self._key_pressed(code)

    def _is_down(self, code: Int) -> Bool:
        if code >= GAMEPAD_SENTINEL:
            if (
                Int(self.gamepad) == 0
                or not self.input[unsafe_offset=0].focused
            ):
                return False
            return self.gamepad[unsafe_offset=0].is_down(
                code - GAMEPAD_SENTINEL
            )
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
            var combos = self.keybinds[action].copy()
            if len(combos) == 0:
                return False
            for i in range(len(combos)):
                var combo = combos[i].copy()
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

    def char_pressed(self) -> Int32:
        """The key that had a press edge this frame, or 0. Only ASCII-range codes are returned for text input.
        """
        if self.input[unsafe_offset=0].last_key_pressed:
            var code = Int(self.input[unsafe_offset=0].last_key)
            if code >= 32 and code <= 126:
                return Int32(code)
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
        their native pixel size.
        """
        var target = Int(Float32(design_size) * self.font_scale)
        var sizes = List[Int]()
        sizes.append(12)
        sizes.append(14)
        sizes.append(16)
        sizes.append(18)
        sizes.append(20)
        sizes.append(22)
        sizes.append(26)
        sizes.append(32)
        sizes.append(48)
        sizes.append(56)
        sizes.append(64)
        sizes.append(81)
        sizes.append(96)
        var best = sizes[0]
        var best_diff = 1000
        for i in range(13):
            var cand = sizes[i]
            var diff = cand - target
            if diff < 0:
                diff = -diff
            if diff < best_diff:
                best_diff = diff
                best = cand
        return best

    def font(
        mut self, design_size: Int
    ) -> Pointer[TextAtlas, MutUntrackedOrigin]:
        """Baked glyph atlas for a design-pixel size (nearest ladder rung).

        Returns an atlas reference — callers pass it straight into
        canvas.draw_text / measure helpers.
        """
        var px = self._atlas_px(design_size)
        var fp = self.fonts
        var fb = fp[unsafe_offset=0].get_atlas(px)
        return fb

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
        px (raylib convention); convert to a baseline for the rasterizer."""
        var x_screen = Float64(Float32(x) * self.ui_scale)
        var y_top_screen = Float64(Float32(y) * self.ui_scale)
        var atlas = self.font(Int(Float64(size) * Float64(self.font_scale)))
        self.canvas[unsafe_offset=0].draw_text(
            atlas[unsafe_offset=0],
            String(text),
            x_screen,
            y_top_screen + Float64(atlas[unsafe_offset=0].ascent),
            color,
        )

    def _measure_text(mut self, text: String, size: Int) -> Vec2:
        """Measured text size at the ladder's native pixels."""
        var atlas = self.font(size)
        var text_mut = String(text)
        var w = Float32(atlas[unsafe_offset=0].text_width(text_mut))
        return Vec2(Float64(w), Float64(atlas[unsafe_offset=0].line_height))

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
        var atlas = self.font(fsize)
        var label_mut = String(label)
        return Float64(atlas[unsafe_offset=0].text_width(label_mut))

    def fitted_button_w(
        mut self, label: String, fsize: Int, w: Float64
    ) -> Float64:
        """Design-px width a button will occupy (grow to fit label + padding).

        Public so call sites that place buttons right-to-left or in fixed
        strides can reserve the grown width up front, keeping neighbors
        from overlapping when button_at widens a rect.
        """
        var pad_screen = Float64(self.s(BUTTON_PAD_X))
        var needed = (self._label_screen_w(label, fsize) + 2.0 * pad_screen) / Float64(
            self.ui_scale
        )
        return max(w, needed)

    def button(
        mut self,
        label: String,
        h: Float64 = 36.0,
        bg: Color = GREEN,
        fg: Color = ACCENT_DARK,
        hover: Color = Color(140, 192, 88, 255),
        action: String = "",
    ) -> UIResult:
        """Draw a button at the cursor. Returns interaction state.

        If action is non-empty, the button also activates when its keybind
        combo is triggered (see UIContext.check_keybind).
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
        var hovered = self._hit(r)
        var clicked = self._clicked(r)
        if action.byte_length() > 0 and self.check_keybind(action):
            clicked = True

        var color = bg
        if hovered:
            color = hover

        self.canvas[unsafe_offset=0].fill_rect_rounded(
            Float64(r.x),
            Float64(r.y),
            Float64(r.width),
            Float64(r.height),
            0.12,
            color,
        )

        self._draw_button_label(label, r, fsize, fg)
        self.advance(h + 10.0)
        return UIResult(hovered=hovered, clicked=clicked, bounds=r)

    def button_fixed(
        mut self,
        label: String,
        w: Float64,
        h: Float64,
        bg: Color = GREEN,
        fg: Color = ACCENT_DARK,
        hover: Color = Color(140, 192, 88, 255),
        action: String = "",
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
        var hovered = self._hit(r)
        var clicked = self._clicked(r)
        if action.byte_length() > 0 and self.check_keybind(action):
            clicked = True

        var color = bg
        if hovered:
            color = hover

        self.canvas[0].fill_rect_rounded(
            Float64(r.x),
            Float64(r.y),
            Float64(r.width),
            Float64(r.height),
            0.12,
            color,
        )

        self._draw_button_label(label, r, fsize, fg)
        # Advance cursor by width (so next element goes to the right)
        self.cursor_x += r.width
        self.cursor_w -= r.width
        return UIResult(hovered=hovered, clicked=clicked, bounds=r)

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
        var hovered = self._hit(r)
        var clicked = self._clicked(r)
        if action.byte_length() > 0 and self.check_keybind(action):
            clicked = True

        var color = bg
        if hovered:
            color = hover

        self.canvas[unsafe_offset=0].fill_rect_rounded(
            Float64(r.x),
            Float64(r.y),
            Float64(r.width),
            Float64(r.height),
            0.12,
            color,
        )

        self._draw_button_label(label, r, fsize, fg)
        return UIResult(hovered=hovered, clicked=clicked, bounds=r)

    def _draw_button_label(
        mut self, label: String, r: Rect, fsize: Int, fg: Color
    ):
        """Center a label inside a button rect at the ladder's native size."""
        var atlas = self.font(fsize)
        var label_mut = String(label)
        var tw = Float64(atlas[unsafe_offset=0].text_width(label_mut))
        var th = Float64(atlas[unsafe_offset=0].line_height)
        var tx = Float64(r.x) + (Float64(r.width) - tw) / 2.0
        var ty = Float64(r.y) + (Float64(r.height) - th) / 2.0
        self.canvas[unsafe_offset=0].draw_text(
            atlas[unsafe_offset=0],
            String(label),
            tx,
            ty + Float64(atlas[unsafe_offset=0].ascent),
            fg,
        )

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
        self.canvas[unsafe_offset=0].fill_rect_rounded(
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
        self.canvas[unsafe_offset=0].fill_rect(
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
        self.canvas[unsafe_offset=0].fill_rect_gradient(
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
        self.canvas[unsafe_offset=0].fill_rect_rounded(
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
            self.canvas[unsafe_offset=0].fill_rect_rounded(
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
        self.canvas[unsafe_offset=0].fill_rect_rounded(
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
    ) -> UIResult:
        """Draw a clickable card row at design coords. Returns interaction."""
        var r = self.rect(x, y, w, h)
        var hovered = self._hit(r)
        var clicked = self._clicked(r)

        var color = bg
        if selected:
            color = selected_bg

        self.canvas[unsafe_offset=0].fill_rect_rounded(
            Float64(r.x),
            Float64(r.y),
            Float64(r.width),
            Float64(r.height),
            0.04,
            color,
        )
        return UIResult(hovered=hovered, clicked=clicked, bounds=r)

    # ------------------------------------------------------------------
    # Scissor helpers
    # ------------------------------------------------------------------

    def begin_clip(mut self, x: Float64, y: Float64, w: Float64, h: Float64):
        var sx = Int(Float32(x) * self.ui_scale)
        var sy = Int(Float32(y) * self.ui_scale)
        var sw = Int(Float32(w) * self.ui_scale)
        var sh = Int(Float32(h) * self.ui_scale)
        self.canvas[unsafe_offset=0].begin_clip(sx, sy, sw, sh)

    def end_clip(mut self):
        self.canvas[unsafe_offset=0].end_clip()
