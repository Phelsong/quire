# ui/widgets.mojo — TextInput / Button / Checkbox widgets.
#
# All rendering routes through the UIContext facade (Canvas + baked glyph
# atlases); bounds come in as ui.Rect built via ui.rect() (screen px).
# `font` params on draw() are the atlas for the caller's chosen design size.

from ui.font import FontSet
from ui.plex_objects import PlexBookCard
from resources.color import Color
from resources.palette import (
    GREEN,
    TEXT_DIM,
    TEXT_BRIGHT,
    ACCENT_DARK,
    BORDER_FOCUS,
    BORDER_IDLE,
    BULLET,
    CHECKMARK,
)
from functions.helpers import truncate_string
from functions.ascii import AsciiTable
from ui.imui import Vec2, Rect, UIContext
from platform.text import TextAtlas
from render.canvas import Canvas


# ---------------------------------------------------------------------------
# TextInput widget
# ---------------------------------------------------------------------------


struct TextInput:
    var text: String
    var display_text: String  # cached masked/plain version
    var placeholder: String
    var is_password: Bool
    var is_focused: Bool
    var cursor_blink_timer: Float64
    var bounds: Rect
    var bg_color: Color
    var fg_color: Color

    def __init__(
        out self,
        text: String,
        placeholder: String,
        is_password: Bool,
        bounds: Rect,
        bg_color: Color,
        fg_color: Color,
    ):
        self.text = text
        self.placeholder = placeholder
        self.is_password = is_password
        self.is_focused = False
        self.cursor_blink_timer = 0.0
        self.bounds = bounds
        self.bg_color = bg_color
        self.fg_color = fg_color
        # Initialize display_text based on password masking
        if not self.is_password:
            self.display_text = self.text
        else:
            var masked = String()
            for _ in range(self.text.byte_length()):
                masked = masked + BULLET
            self.display_text = masked

    def _compute_display(self) -> String:
        """Compute displayed text (masked for passwords)."""
        if not self.is_password:
            return self.text
        var masked = String()
        for _ in range(self.text.byte_length()):
            masked = masked + BULLET
        return masked

    def _refresh_display(mut self):
        """Refresh display text cache after text changes."""
        self.display_text = self._compute_display()

    def handle_click(mut self, mouse_pos: Vec2):
        """Check if a mouse click hit this input; update focus."""
        if (
            mouse_pos.x >= self.bounds.x
            and mouse_pos.x < self.bounds.x + self.bounds.width
            and mouse_pos.y >= self.bounds.y
            and mouse_pos.y < self.bounds.y + self.bounds.height
        ):
            self.is_focused = True
            self.cursor_blink_timer = 0.0
        else:
            self.is_focused = False

    def handle_char(mut self, codepoint: Int, ascii: AsciiTable):
        """Append a printable character to the text."""
        if not self.is_focused:
            return
        var ch = ascii.lookup(codepoint)
        if ch.byte_length() == 0:
            return
        self.text = self.text + ch
        self._refresh_display()
        self.cursor_blink_timer = 0.0

    def handle_backspace(mut self):
        """Delete the last character."""
        if not self.is_focused:
            return
        if self.text.byte_length() > 0:
            self.text = truncate_string(self.text, self.text.byte_length() - 1)
            self._refresh_display()
            self.cursor_blink_timer = 0.0

    def handle_delete(mut self):
        """Delete character at cursor (no-op for end-cursor)."""
        pass

    def draw(
        mut self,
        mut ui: UIContext,
        design_size: Int,
        dt: Float64,
    ):
        """Render the text input each frame. Background/border are in the
        widget's own colors; text is drawn through the facade."""
        var canvas = ui.canvas

        # Background rounded rect
        canvas[unsafe_offset=0].fill_rect_rounded(
            Float64(self.bounds.x),
            Float64(self.bounds.y),
            Float64(self.bounds.width),
            Float64(self.bounds.height),
            0.08,
            self.bg_color,
        )

        # Border: green when focused, dim when idle
        var border_color = BORDER_IDLE
        if self.is_focused:
            border_color = BORDER_FOCUS
        canvas[unsafe_offset=0].outline_rect_rounded(
            Float64(self.bounds.x),
            Float64(self.bounds.y),
            Float64(self.bounds.width),
            Float64(self.bounds.height),
            0.08,
            2.0,
            border_color,
        )

        # Determine what to draw
        var draw_text_str = self.display_text
        var draw_color = self.fg_color
        if self.text.byte_length() == 0:
            draw_text_str = self.placeholder
            draw_color = TEXT_DIM

        var atlas = ui.font(design_size)
        var font_px = atlas[unsafe_offset=0].pixel_size
        var text_w = atlas[unsafe_offset=0].text_width(draw_text_str)

        # Text position: left-aligned with 12px padding, vertically centered
        # (baseline = top + ascent with half-leading correction).
        var text_x = Float64(self.bounds.x) + 12.0
        var mid = (
            Float64(self.bounds.height)
            - Float64(atlas[unsafe_offset=0].line_height)
        ) / 2.0
        var baseline = (
            Float64(self.bounds.y)
            + mid
            + Float64(atlas[unsafe_offset=0].ascent)
        )
        canvas[unsafe_offset=0].draw_text(
            atlas[unsafe_offset=0], draw_text_str, text_x, baseline, draw_color
        )

        # Blinking cursor when focused
        if self.is_focused:
            self.cursor_blink_timer += dt
            var blink_on = (self.cursor_blink_timer % 1.0) < 0.6

            if blink_on:
                var cx = text_x + Float64(text_w) + 2.0
                var cy_top = Float64(self.bounds.y) + 4.0
                var cy_bot = (
                    Float64(self.bounds.y) + Float64(self.bounds.height) - 4.0
                )
                canvas[unsafe_offset=0].fill_rect(
                    cx, cy_top, 2.0, cy_bot - cy_top, GREEN
                )


# ---------------------------------------------------------------------------
# Button widget
# ---------------------------------------------------------------------------


struct Button:
    var label: String
    var bounds: Rect
    var is_hovered: Bool
    var is_disabled: Bool
    var bg_color: Color
    var fg_color: Color
    var hover_color: Color

    def __init__(
        out self,
        label: String,
        bounds: Rect,
        bg_color: Color,
        fg_color: Color,
        hover_color: Color,
        is_disabled: Bool = False,
    ):
        self.label = label
        self.bounds = bounds
        self.is_hovered = False
        self.is_disabled = is_disabled
        self.bg_color = bg_color
        self.fg_color = fg_color
        self.hover_color = hover_color

    def update_hover(mut self, mouse_pos: Vec2):
        """Track hover state each frame."""
        self.is_hovered = (
            mouse_pos.x >= self.bounds.x
            and mouse_pos.x < self.bounds.x + self.bounds.width
            and mouse_pos.y >= self.bounds.y
            and mouse_pos.y < self.bounds.y + self.bounds.height
        )

    def check_click(self, mouse_pos: Vec2) -> Bool:
        """Return True if button was clicked."""
        if self.is_disabled:
            return False
        return (
            mouse_pos.x >= self.bounds.x
            and mouse_pos.x < self.bounds.x + self.bounds.width
            and mouse_pos.y >= self.bounds.y
            and mouse_pos.y < self.bounds.y + self.bounds.height
        )

    def draw(mut self, mut ui: UIContext, design_size: Int):
        """Render the button through the facade."""
        var canvas = ui.canvas
        var color = self.bg_color
        if self.is_disabled:
            color = Color(80, 100, 60, 255)
        elif self.is_hovered:
            color = self.hover_color

        canvas[0].fill_rect_rounded(
            Float64(self.bounds.x),
            Float64(self.bounds.y),
            Float64(self.bounds.width),
            Float64(self.bounds.height),
            0.12,
            color,
        )

        # Label centered in button
        var atlas = ui.font(design_size)
        var label_mut = String(self.label)
        var text_w = atlas[0].text_width(label_mut)
        var text_x = (
            Float64(self.bounds.x)
            + (Float64(self.bounds.width) - Float64(text_w)) / 2.0
        )
        var mid = (
            Float64(self.bounds.height) - Float64(atlas[0].line_height)
        ) / 2.0
        var baseline = Float64(self.bounds.y) + mid + Float64(atlas[0].ascent)

        var fg = self.fg_color
        if self.is_disabled:
            fg = TEXT_DIM
        canvas[0].draw_text(atlas[0], self.label, text_x, baseline, fg)


# ---------------------------------------------------------------------------
# Checkbox widget
# ---------------------------------------------------------------------------


struct Checkbox:
    var is_checked: Bool
    var bounds: Rect

    def __init__(out self, is_checked: Bool, bounds: Rect):
        self.is_checked = is_checked
        self.bounds = bounds

    def handle_click(mut self, mouse_pos: Vec2) -> Bool:
        """Toggle on click. Returns True if toggled."""
        if (
            mouse_pos.x >= self.bounds.x
            and mouse_pos.x < self.bounds.x + self.bounds.width
            and mouse_pos.y >= self.bounds.y
            and mouse_pos.y < self.bounds.y + self.bounds.height
        ):
            self.is_checked = not self.is_checked
            return True
        return False

    def draw(mut self, mut ui: UIContext, design_size: Int):
        """Render checkbox through the facade."""
        var canvas = ui.canvas
        # Outer box
        canvas[0].fill_rect_rounded(
            Float64(self.bounds.x),
            Float64(self.bounds.y),
            Float64(self.bounds.width),
            Float64(self.bounds.height),
            0.15,
            Color(22, 24, 28, 255),
        )
        canvas[0].outline_rect_rounded(
            Float64(self.bounds.x),
            Float64(self.bounds.y),
            Float64(self.bounds.width),
            Float64(self.bounds.height),
            0.15,
            1.5,
            BORDER_IDLE,
        )

        if self.is_checked:
            # Filled green background
            canvas[0].fill_rect_rounded(
                Float64(self.bounds.x) + 3.0,
                Float64(self.bounds.y) + 3.0,
                Float64(self.bounds.width) - 6.0,
                Float64(self.bounds.height) - 6.0,
                0.1,
                GREEN,
            )

            # Checkmark centered in box
            var atlas = ui.font(design_size)
            var check_mut = String(CHECKMARK)
            var check_w = atlas[0].text_width(check_mut)
            var cx = (
                Float64(self.bounds.x)
                + (Float64(self.bounds.width) - Float64(check_w)) / 2.0
            )
            var mid = (
                Float64(self.bounds.height) - Float64(atlas[0].line_height)
            ) / 2.0
            var baseline = (
                Float64(self.bounds.y) + mid + Float64(atlas[0].ascent)
            )
            canvas[0].draw_text(atlas[0], CHECKMARK, cx, baseline, ACCENT_DARK)


# ---------------------------------------------------------------------------
# Book widget — PlexBookCard is defined in ui/plex_objects.mojo
