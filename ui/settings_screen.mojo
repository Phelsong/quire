"""Quire — Settings screen (keybinds + display scaling).

Immediate-mode screen reachable from the library header. Two sections:

  1. Keybinds  — lists every configurable action with its current binding
     and a "Rebind" button. Clicking Rebind captures the next key press
     (optionally with Shift) and updates the binding. Escape cancels.
  2. Display   — a slider for the font size multiplier (0.5x–3.0x) that
     controls app-wide text scaling, plus quick preset buttons.

The screen owns an editable copy of the settings state. main.mojo reads
`font_multiplier` and `keybinds` and persists them when `save_requested`
is set. The screen never touches the config file directly (single source
of truth lives in main.mojo / resources.config).
"""

from std.collections import List, Dict

from functions.helpers import truncate_string
from functions.plex_bridge import PlexSession
from ui.icons import ICON_BACK, ICON_LOGOUT

from resources.color import Color
from ui.imui import UIContext, UIResult, Vec2, Rect

from resources.palette import (
    GREEN,
    ERROR_COLOR,
    TEXT_BRIGHT,
    TEXT_LIGHT,
    TEXT_DIM,
    TEXT_MUTED,
    ACCENT_DARK,
    BORDER_FOCUS,
    BORDER_IDLE,
    BTN_DARK_LIB,
    CARD_BG,
    INPUT_BG,
    LIBRARY_BG,
    LOGOUT_RED,
    SLIDER_BG,
    SLIDER_FILL,
    SELECTED_BG,
)

from ui import Screen

# raylib keycodes needed for key capture + reverse-name lookup. Kept in
# sync with resources/keys.mojo.
from resources.keys import (
    GAMEPAD_BUTTON_LEFT_FACE_DOWN,
    GAMEPAD_BUTTON_LEFT_FACE_LEFT,
    GAMEPAD_BUTTON_LEFT_FACE_RIGHT,
    GAMEPAD_BUTTON_LEFT_FACE_UP,
    GAMEPAD_BUTTON_LEFT_THUMB,
    GAMEPAD_BUTTON_LEFT_TRIGGER_1,
    GAMEPAD_BUTTON_LEFT_TRIGGER_2,
    GAMEPAD_BUTTON_MIDDLE,
    GAMEPAD_BUTTON_MIDDLE_LEFT,
    GAMEPAD_BUTTON_MIDDLE_RIGHT,
    GAMEPAD_BUTTON_RIGHT_FACE_DOWN,
    GAMEPAD_BUTTON_RIGHT_FACE_LEFT,
    GAMEPAD_BUTTON_RIGHT_FACE_RIGHT,
    GAMEPAD_BUTTON_RIGHT_FACE_UP,
    GAMEPAD_BUTTON_RIGHT_THUMB,
    GAMEPAD_BUTTON_RIGHT_TRIGGER_1,
    GAMEPAD_BUTTON_RIGHT_TRIGGER_2,
    GAMEPAD_SENTINEL,
    KEY_A,
    KEY_APOSTROPHE,
    KEY_B,
    KEY_BACKSLASH,
    KEY_BACKSPACE,
    KEY_C,
    KEY_COMMA,
    KEY_D,
    KEY_DELETE,
    KEY_DOWN,
    KEY_E,
    KEY_EIGHT,
    KEY_END,
    KEY_ENTER,
    KEY_EQUAL,
    KEY_ESCAPE,
    KEY_F,
    KEY_F1,
    KEY_F10,
    KEY_F11,
    KEY_F12,
    KEY_F2,
    KEY_F3,
    KEY_F4,
    KEY_F5,
    KEY_F6,
    KEY_F7,
    KEY_F8,
    KEY_F9,
    KEY_FIVE,
    KEY_FOUR,
    KEY_G,
    KEY_GRAVE,
    KEY_H,
    KEY_HOME,
    KEY_I,
    KEY_INSERT,
    KEY_J,
    KEY_K,
    KEY_L,
    KEY_LEFT,
    KEY_LEFT_ALT,
    KEY_LEFT_BRACKET,
    KEY_LEFT_CONTROL,
    KEY_LEFT_SHIFT,
    KEY_M,
    KEY_MINUS,
    KEY_N,
    KEY_NINE,
    KEY_NULL,
    KEY_O,
    KEY_ONE,
    KEY_P,
    KEY_PAGE_DOWN,
    KEY_PAGE_UP,
    KEY_PERIOD,
    KEY_Q,
    KEY_R,
    KEY_RIGHT,
    KEY_RIGHT_ALT,
    KEY_RIGHT_BRACKET,
    KEY_RIGHT_CONTROL,
    KEY_RIGHT_SHIFT,
    KEY_S,
    KEY_SEMICOLON,
    KEY_SEVEN,
    KEY_SIX,
    KEY_SLASH,
    KEY_SPACE,
    KEY_T,
    KEY_TAB,
    KEY_THREE,
    KEY_TWO,
    KEY_U,
    KEY_UP,
    KEY_V,
    KEY_W,
    KEY_X,
    KEY_Y,
    KEY_Z,
    KEY_ZERO,
)


# ---------------------------------------------------------------------------
# Ordered action list + human-readable labels (single source for the UI)
# ---------------------------------------------------------------------------


def _action_keys() -> List[String]:
    """Ordered keybind action identifiers (the single source for the UI)."""
    var keys = List[String]()
    keys.append("play_pause")
    keys.append("skip_back")
    keys.append("skip_forward")
    keys.append("prev_chapter")
    keys.append("next_chapter")
    keys.append("speed_down")
    keys.append("speed_up")
    keys.append("back_button")
    keys.append("home")
    return keys^


def _action_labels() -> List[String]:
    """Human-readable labels, indexed in parallel with _action_keys()."""
    var labels = List[String]()
    labels.append("Play / Pause")
    labels.append("Skip Back")
    labels.append("Skip Forward")
    labels.append("Previous Chapter")
    labels.append("Next Chapter")
    labels.append("Speed Down")
    labels.append("Speed Up")
    labels.append("Back")
    labels.append("Home")
    return labels^


def _action_names() -> List[String]:
    """Copy of the action identifier list (for iteration in draw)."""
    var keys = _action_keys()
    var names = List[String]()
    for i in range(len(keys)):
        names.append(keys[i])
    return names^


def _action_label(action: String) -> String:
    """Human-readable label for a keybind action, or the raw name if unknown."""
    var keys = _action_keys()
    var labels = _action_labels()
    for i in range(len(keys)):
        if keys[i] == action:
            return labels[i]
    return action


def _round(value: Float64) -> Int:
    """Round a Float64 to the nearest Int (round half up)."""
    return Int(value + 0.5)


# ---------------------------------------------------------------------------
# Reverse key lookup — keycode -> key-name string.
# Mirrors resources/keys.mojo's key_code() forward map. Used to render the
# captured key as a config-ready string ("KEY_LEFT_SHIFT+KEY_LEFT").
# ---------------------------------------------------------------------------


def key_name(code: Int) -> String:
    """Resolve a keycode to its config key-name string.

    Returns "" for unrecognized codes (KEY_NULL / unmapped).
    """
    if code == KEY_SPACE:
        return "KEY_SPACE"
    elif code == KEY_ESCAPE:
        return "KEY_ESCAPE"
    elif code == KEY_ENTER:
        return "KEY_ENTER"
    elif code == KEY_TAB:
        return "KEY_TAB"
    elif code == KEY_BACKSPACE:
        return "KEY_BACKSPACE"
    elif code == KEY_INSERT:
        return "KEY_INSERT"
    elif code == KEY_DELETE:
        return "KEY_DELETE"
    elif code == KEY_LEFT:
        return "KEY_LEFT"
    elif code == KEY_RIGHT:
        return "KEY_RIGHT"
    elif code == KEY_UP:
        return "KEY_UP"
    elif code == KEY_DOWN:
        return "KEY_DOWN"
    elif code == KEY_PAGE_UP:
        return "KEY_PAGE_UP"
    elif code == KEY_PAGE_DOWN:
        return "KEY_PAGE_DOWN"
    elif code == KEY_HOME:
        return "KEY_HOME"
    elif code == KEY_END:
        return "KEY_END"
    elif code == KEY_MINUS:
        return "KEY_MINUS"
    elif code == KEY_EQUAL:
        return "KEY_EQUAL"
    elif code == KEY_COMMA:
        return "KEY_COMMA"
    elif code == KEY_PERIOD:
        return "KEY_PERIOD"
    elif code == KEY_SLASH:
        return "KEY_SLASH"
    elif code == KEY_SEMICOLON:
        return "KEY_SEMICOLON"
    elif code == KEY_APOSTROPHE:
        return "KEY_APOSTROPHE"
    elif code == KEY_LEFT_BRACKET:
        return "KEY_LEFT_BRACKET"
    elif code == KEY_RIGHT_BRACKET:
        return "KEY_RIGHT_BRACKET"
    elif code == KEY_BACKSLASH:
        return "KEY_BACKSLASH"
    elif code == KEY_GRAVE:
        return "KEY_GRAVE"
    elif code == KEY_LEFT_SHIFT:
        return "KEY_LEFT_SHIFT"
    elif code == KEY_LEFT_CONTROL:
        return "KEY_LEFT_CONTROL"
    elif code == KEY_LEFT_ALT:
        return "KEY_LEFT_ALT"
    elif code == KEY_RIGHT_SHIFT:
        return "KEY_RIGHT_SHIFT"
    elif code == KEY_RIGHT_CONTROL:
        return "KEY_RIGHT_CONTROL"
    elif code == KEY_RIGHT_ALT:
        return "KEY_RIGHT_ALT"
    elif code == KEY_F1:
        return "KEY_F1"
    elif code == KEY_F2:
        return "KEY_F2"
    elif code == KEY_F3:
        return "KEY_F3"
    elif code == KEY_F4:
        return "KEY_F4"
    elif code == KEY_F5:
        return "KEY_F5"
    elif code == KEY_F6:
        return "KEY_F6"
    elif code == KEY_F7:
        return "KEY_F7"
    elif code == KEY_F8:
        return "KEY_F8"
    elif code == KEY_F9:
        return "KEY_F9"
    elif code == KEY_F10:
        return "KEY_F10"
    elif code == KEY_F11:
        return "KEY_F11"
    elif code == KEY_F12:
        return "KEY_F12"
    elif code == KEY_ZERO:
        return "KEY_ZERO"
    elif code == KEY_ONE:
        return "KEY_ONE"
    elif code == KEY_TWO:
        return "KEY_TWO"
    elif code == KEY_THREE:
        return "KEY_THREE"
    elif code == KEY_FOUR:
        return "KEY_FOUR"
    elif code == KEY_FIVE:
        return "KEY_FIVE"
    elif code == KEY_SIX:
        return "KEY_SIX"
    elif code == KEY_SEVEN:
        return "KEY_SEVEN"
    elif code == KEY_EIGHT:
        return "KEY_EIGHT"
    elif code == KEY_NINE:
        return "KEY_NINE"
    elif code == KEY_A:
        return "KEY_A"
    elif code == KEY_B:
        return "KEY_B"
    elif code == KEY_C:
        return "KEY_C"
    elif code == KEY_D:
        return "KEY_D"
    elif code == KEY_E:
        return "KEY_E"
    elif code == KEY_F:
        return "KEY_F"
    elif code == KEY_G:
        return "KEY_G"
    elif code == KEY_H:
        return "KEY_H"
    elif code == KEY_I:
        return "KEY_I"
    elif code == KEY_J:
        return "KEY_J"
    elif code == KEY_K:
        return "KEY_K"
    elif code == KEY_L:
        return "KEY_L"
    elif code == KEY_M:
        return "KEY_M"
    elif code == KEY_N:
        return "KEY_N"
    elif code == KEY_O:
        return "KEY_O"
    elif code == KEY_P:
        return "KEY_P"
    elif code == KEY_Q:
        return "KEY_Q"
    elif code == KEY_R:
        return "KEY_R"
    elif code == KEY_S:
        return "KEY_S"
    elif code == KEY_T:
        return "KEY_T"
    elif code == KEY_U:
        return "KEY_U"
    elif code == KEY_V:
        return "KEY_V"
    elif code == KEY_W:
        return "KEY_W"
    elif code == KEY_X:
        return "KEY_X"
    elif code == KEY_Y:
        return "KEY_Y"
    elif code == KEY_Z:
        return "KEY_Z"
    # Gamepad buttons (sentinel-offset codes -> GAMEPAD_BUTTON_* names).
    elif code == GAMEPAD_SENTINEL + GAMEPAD_BUTTON_LEFT_FACE_UP:
        return "GAMEPAD_BUTTON_LEFT_FACE_UP"
    elif code == GAMEPAD_SENTINEL + GAMEPAD_BUTTON_LEFT_FACE_RIGHT:
        return "GAMEPAD_BUTTON_LEFT_FACE_RIGHT"
    elif code == GAMEPAD_SENTINEL + GAMEPAD_BUTTON_LEFT_FACE_DOWN:
        return "GAMEPAD_BUTTON_LEFT_FACE_DOWN"
    elif code == GAMEPAD_SENTINEL + GAMEPAD_BUTTON_LEFT_FACE_LEFT:
        return "GAMEPAD_BUTTON_LEFT_FACE_LEFT"
    elif code == GAMEPAD_SENTINEL + GAMEPAD_BUTTON_RIGHT_FACE_UP:
        return "GAMEPAD_BUTTON_RIGHT_FACE_UP"
    elif code == GAMEPAD_SENTINEL + GAMEPAD_BUTTON_RIGHT_FACE_RIGHT:
        return "GAMEPAD_BUTTON_RIGHT_FACE_RIGHT"
    elif code == GAMEPAD_SENTINEL + GAMEPAD_BUTTON_RIGHT_FACE_DOWN:
        return "GAMEPAD_BUTTON_RIGHT_FACE_DOWN"
    elif code == GAMEPAD_SENTINEL + GAMEPAD_BUTTON_RIGHT_FACE_LEFT:
        return "GAMEPAD_BUTTON_RIGHT_FACE_LEFT"
    elif code == GAMEPAD_SENTINEL + GAMEPAD_BUTTON_LEFT_TRIGGER_1:
        return "GAMEPAD_BUTTON_LEFT_TRIGGER_1"
    elif code == GAMEPAD_SENTINEL + GAMEPAD_BUTTON_LEFT_TRIGGER_2:
        return "GAMEPAD_BUTTON_LEFT_TRIGGER_2"
    elif code == GAMEPAD_SENTINEL + GAMEPAD_BUTTON_RIGHT_TRIGGER_1:
        return "GAMEPAD_BUTTON_RIGHT_TRIGGER_1"
    elif code == GAMEPAD_SENTINEL + GAMEPAD_BUTTON_RIGHT_TRIGGER_2:
        return "GAMEPAD_BUTTON_RIGHT_TRIGGER_2"
    elif code == GAMEPAD_SENTINEL + GAMEPAD_BUTTON_MIDDLE_LEFT:
        return "GAMEPAD_BUTTON_MIDDLE_LEFT"
    elif code == GAMEPAD_SENTINEL + GAMEPAD_BUTTON_MIDDLE:
        return "GAMEPAD_BUTTON_MIDDLE"
    elif code == GAMEPAD_SENTINEL + GAMEPAD_BUTTON_MIDDLE_RIGHT:
        return "GAMEPAD_BUTTON_MIDDLE_RIGHT"
    elif code == GAMEPAD_SENTINEL + GAMEPAD_BUTTON_LEFT_THUMB:
        return "GAMEPAD_BUTTON_LEFT_THUMB"
    elif code == GAMEPAD_SENTINEL + GAMEPAD_BUTTON_RIGHT_THUMB:
        return "GAMEPAD_BUTTON_RIGHT_THUMB"
    else:
        return ""


# Keys to poll during rebinding (everything a user could reasonably bind).
# Polled each frame while `rebinding_action` is set; the first one pressed
# wins. Modifiers (Shift/Ctrl/Alt) are detected via is_key_down and joined
# with "+" to form a combo spec like "KEY_LEFT_SHIFT+KEY_LEFT".
def _capture_keys() -> List[Int]:
    """Build the list of keycodes polled during rebinding (each frame)."""
    var keys = List[Int]()
    keys.append(KEY_SPACE)
    keys.append(KEY_ENTER)
    keys.append(KEY_TAB)
    keys.append(KEY_BACKSPACE)
    keys.append(KEY_INSERT)
    keys.append(KEY_DELETE)
    keys.append(KEY_LEFT)
    keys.append(KEY_RIGHT)
    keys.append(KEY_UP)
    keys.append(KEY_DOWN)
    keys.append(KEY_PAGE_UP)
    keys.append(KEY_PAGE_DOWN)
    keys.append(KEY_HOME)
    keys.append(KEY_END)
    keys.append(KEY_MINUS)
    keys.append(KEY_EQUAL)
    keys.append(KEY_COMMA)
    keys.append(KEY_PERIOD)
    keys.append(KEY_SLASH)
    keys.append(KEY_SEMICOLON)
    keys.append(KEY_APOSTROPHE)
    keys.append(KEY_LEFT_BRACKET)
    keys.append(KEY_RIGHT_BRACKET)
    keys.append(KEY_BACKSLASH)
    keys.append(KEY_GRAVE)
    keys.append(KEY_F1)
    keys.append(KEY_F2)
    keys.append(KEY_F3)
    keys.append(KEY_F4)
    keys.append(KEY_F5)
    keys.append(KEY_F6)
    keys.append(KEY_F7)
    keys.append(KEY_F8)
    keys.append(KEY_F9)
    keys.append(KEY_F10)
    keys.append(KEY_F11)
    keys.append(KEY_F12)
    keys.append(KEY_ZERO)
    keys.append(KEY_ONE)
    keys.append(KEY_TWO)
    keys.append(KEY_THREE)
    keys.append(KEY_FOUR)
    keys.append(KEY_FIVE)
    keys.append(KEY_SIX)
    keys.append(KEY_SEVEN)
    keys.append(KEY_EIGHT)
    keys.append(KEY_NINE)
    keys.append(KEY_A)
    keys.append(KEY_B)
    keys.append(KEY_C)
    keys.append(KEY_D)
    keys.append(KEY_E)
    keys.append(KEY_F)
    keys.append(KEY_G)
    keys.append(KEY_H)
    keys.append(KEY_I)
    keys.append(KEY_J)
    keys.append(KEY_K)
    keys.append(KEY_L)
    keys.append(KEY_M)
    keys.append(KEY_N)
    keys.append(KEY_O)
    keys.append(KEY_P)
    keys.append(KEY_Q)
    keys.append(KEY_R)
    keys.append(KEY_S)
    keys.append(KEY_T)
    keys.append(KEY_U)
    keys.append(KEY_V)
    keys.append(KEY_W)
    keys.append(KEY_X)
    keys.append(KEY_Y)
    keys.append(KEY_Z)
    return keys^


# ---------------------------------------------------------------------------
# SettingsScreen
# ---------------------------------------------------------------------------


struct SettingsScreen:
    """Settings page: keybind rebinding + display scaling.

    Owns an editable copy of the user-facing settings (font_multiplier +
    keybinds). main.mojo seeds it from Config on construction and reads
    it back when `save_requested` is True.
    """

    var font_multiplier: Float64  # 0.5 .. 3.0 (1.0 = default)
    var keybinds: Dict[String, List[String]]  # action -> key-name strings
    var scroll_offset: Float32

    # Rebinding state. When non-empty, the next captured key or gamepad
    # button replaces the slot indicated by rebinding_is_gamepad. Escape
    # cancels.
    var rebinding_action: String
    var rebinding_is_gamepad: Bool

    # Slider drag retention for the font multiplier.
    var dragging_font_slider: Bool

    # Status feedback line.
    var status_message: String
    var status_color: Color

    # Flags consumed by main.mojo.
    var save_requested: Bool  # persist font_multiplier + keybinds
    var reset_requested: Bool  # restore defaults (main.mojo reloads defaults)
    var dirty: Bool  # unsaved changes exist

    def __init__(out self, screen_w: Int, screen_h: Int):
        self.font_multiplier = 1.0
        self.keybinds = Dict[String, List[String]]()
        self.scroll_offset = 0.0
        self.rebinding_action = ""
        self.rebinding_is_gamepad = False
        self.dragging_font_slider = False
        self.status_message = ""
        self.status_color = TEXT_DIM
        self.save_requested = False
        self.reset_requested = False
        self.dirty = False

    def load_from_config(
        mut self, font_multiplier: Float64, keybinds: Dict[String, List[String]]
    ):
        """Seed editable state from the loaded Config.

        Called by main.mojo after construction / after a reset.
        """
        self.font_multiplier = font_multiplier
        if self.font_multiplier < 0.5:
            self.font_multiplier = 0.5
        if self.font_multiplier > 3.0:
            self.font_multiplier = 3.0
        # Deep-copy keybinds so edits don't mutate the caller's dict.
        self.keybinds = Dict[String, List[String]]()
        for entry in keybinds.items():
            self.keybinds[entry.key] = entry.value.copy()
        self.dirty = False
        self.status_message = ""
        self.status_color = TEXT_DIM

    def _kb_binding_display(self, action: String) -> String:
        """First keyboard binding for an action, or 'Unbound'."""
        var bindings = self.keybinds.get(action, List[String]()).copy()
        for i in range(len(bindings)):
            var b = bindings[i]
            if b.byte_length() > 0 and not b.startswith("GAMEPAD"):
                return _pretty_binding(b)
        return "Unbound"

    def _gp_binding_display(self, action: String) -> String:
        """First gamepad binding for an action, or 'Unbound'."""
        var bindings = self.keybinds.get(action, List[String]()).copy()
        for i in range(len(bindings)):
            var b = bindings[i]
            if b.byte_length() > 0 and b.startswith("GAMEPAD"):
                return _pretty_binding(b)
        return "Unbound"

    def _set_kb_binding(mut self, action: String, key_spec: String):
        """Replace the keyboard binding for an action.

        Preserves all gamepad bindings (entries starting with "GAMEPAD").
        The new keyboard spec is inserted at the front.
        """
        var preserved = List[String]()
        var existing = self.keybinds.get(action, List[String]()).copy()
        for i in range(len(existing)):
            var b = existing[i]
            if b.startswith("GAMEPAD"):
                preserved.append(b)
        var new_list = List[String]()
        new_list.append(key_spec)
        for i in range(len(preserved)):
            new_list.append(preserved[i])
        self.keybinds[action] = new_list^
        self.dirty = True

    def _set_gp_binding(mut self, action: String, key_spec: String):
        """Replace the gamepad binding for an action.

        Preserves all keyboard bindings (entries NOT starting with "GAMEPAD").
        The new gamepad spec is appended after the keyboard entries.
        """
        var preserved = List[String]()
        var existing = self.keybinds.get(action, List[String]()).copy()
        for i in range(len(existing)):
            var b = existing[i]
            if not b.startswith("GAMEPAD"):
                preserved.append(b)
        var new_list = List[String]()
        for i in range(len(preserved)):
            new_list.append(preserved[i])
        new_list.append(key_spec)
        self.keybinds[action] = new_list^
        self.dirty = True

    def _cancel_rebind(mut self):
        self.rebinding_action = ""
        self.rebinding_is_gamepad = False
        self.status_message = ""
        self.status_color = TEXT_DIM

    def _capture_key(mut self, mut ui: UIContext):
        """Capture the next pressed key or gamepad button while rebinding.

        Gated on rebinding_is_gamepad: if True, only captures gamepad buttons
        (via get_gamepad_button_pressed). If False, only captures keyboard keys
        (via is_key_pressed, with Shift as a modifier). Escape always cancels.
        """
        # Escape always cancels.
        if ui.key_pressed(KEY_ESCAPE):
            self._cancel_rebind()
            return

        # Copy the action string out of self before the mut self call so the
        # borrow checker doesn't flag the aliasing read.
        var action = String(self.rebinding_action)

        if self.rebinding_is_gamepad:
            # --- Gamepad capture only (evdev backend, main-heap-boxed) ---
            # Focus gate: ignore pad events when another window is focused.
            if Int(ui.gamepad) != 0 and ui.input[unsafe_offset=0].focused:
                var gp_button = ui.gamepad[unsafe_offset=0].last_button()
                if gp_button >= 0:
                    var gp_name = key_name(GAMEPAD_SENTINEL + Int(gp_button))
                    if gp_name.byte_length() > 0:
                        self._set_gp_binding(action, gp_name)
                        self._cancel_rebind()
                        self.status_message = (
                            "Rebound "
                            + _action_label(action)
                            + " (pad) to "
                            + _pretty_binding(gp_name)
                        )
                        self.status_color = GREEN
            return

        # --- Keyboard capture only ---
        var captured_code = 0
        var capture_keys = _capture_keys()
        for i in range(len(capture_keys)):
            var code = capture_keys[i]
            if ui.key_pressed(code):
                captured_code = code
                break

        if captured_code == 0:
            return  # Nothing pressed yet — keep waiting.

        var name = key_name(captured_code)
        if name.byte_length() == 0:
            return  # Unmapped key — ignore, keep listening.

        var spec = name
        if ui.key_down(KEY_LEFT_SHIFT) or ui.key_down(KEY_RIGHT_SHIFT):
            spec = "KEY_LEFT_SHIFT+" + name
        # Reject binding to a bare modifier (e.g. Shift alone).
        if spec == "KEY_LEFT_SHIFT":
            self.status_message = "Cannot bind Shift alone"
            self.status_color = ERROR_COLOR
            return

        self._set_kb_binding(action, spec)
        self._cancel_rebind()
        self.status_message = (
            "Rebound " + _action_label(action) + " to " + _pretty_binding(spec)
        )
        self.status_color = GREEN

    def handle_scroll(mut self, wheel_delta: Float32, screen_h: Int):
        """Scroll the keybind list."""
        var actions = _action_names()
        var item_count = len(actions)
        if item_count == 0:
            return

        var header_h = 110.0
        var section_h = 60.0  # display scaling section height
        var row_h = 56.0
        var row_gap = 8.0
        var total_height = (
            Float64(item_count) * (row_h + row_gap) - row_gap + section_h
        )
        var visible_height = Float64(screen_h) - header_h - 80.0

        if total_height <= visible_height:
            self.scroll_offset = 0.0
            return

        self.scroll_offset += wheel_delta * 40.0
        var max_scroll = Float32(total_height - visible_height)
        if self.scroll_offset < 0.0:
            self.scroll_offset = 0.0
        elif self.scroll_offset > max_scroll:
            self.scroll_offset = max_scroll

    def draw(
        mut self,
        mut ui: UIContext,
        mut app_state: PlexSession,
        mut screen: Screen,
    ) raises:
        """Render the settings screen (immediate-mode)."""
        var sw_design = Float64(ui.screen_w) / Float64(ui.ui_scale)
        var sh_design = Float64(ui.screen_h) / Float64(ui.ui_scale)

        # --- Key capture takes priority over drawing interactions ---
        if self.rebinding_action.byte_length() > 0:
            self._capture_key(ui)

        # --- Header bar ---
        var header_h = 50.0
        ui.panel_bg(0.0, 0.0, sw_design, header_h, LIBRARY_BG)

        # Back button (returns to library)
        var btn_w = sw_design * 0.15
        var btn_h = 36.0
        ui.move_to(20.0, 7.0)
        ui.cursor_w = Float32(btn_w) * ui.ui_scale
        var back_result = ui.button(
            ICON_BACK,
            btn_h,
            BTN_DARK_LIB,
            TEXT_LIGHT,
            Color(55, 64, 80, 255),
        )
        if back_result.clicked:
            screen.current = 1
            return

        # Title (centered)
        ui.move_to(0.0, 14.0)
        ui.label_centered("Settings", 22, GREEN)

        # Right-side header actions: Select Library + Logout.
        var action_w = sw_design * 0.13
        ui.move_to(sw_design - action_w * 2.0 - 30.0, 7.0)
        ui.cursor_w = Float32(action_w) * ui.ui_scale
        var select_result = ui.button(
            "SELECT LIBRARY",
            btn_h,
            BTN_DARK_LIB,
            TEXT_LIGHT,
            Color(55, 64, 80, 255),
        )
        if select_result.clicked:
            screen.current = 3
            return

        ui.move_to(sw_design - action_w - 20.0, 7.0)
        ui.cursor_w = Float32(action_w) * ui.ui_scale
        var logout_result = ui.button(
            ICON_LOGOUT,
            btn_h,
            LOGOUT_RED,
            Color(242, 217, 217, 255),
            Color(130, 50, 50, 255),
        )
        if logout_result.clicked:
            app_state.logged_in = False
            app_state.account_token = ""
            screen.current = 0
            return

        # --- Section 1: Display Scaling ---
        var section_y = header_h + 18.0
        self._draw_display_section(ui, sw_design, section_y)

        # --- Section 2: Keybinds ---
        var keybind_section_y = section_y + 90.0
        self._draw_keybind_section(ui, sw_design, sh_design, keybind_section_y)

        # --- Footer: Save / Reset buttons + status ---
        var footer_y = sh_design - 60.0
        self._draw_footer(ui, sw_design, footer_y)

    def _draw_display_section(
        mut self, mut ui: UIContext, sw_design: Float64, y: Float64
    ):
        """Font size multiplier slider + preset buttons."""
        # Section heading
        ui.move_to(20.0, y)
        ui.label("Display", 22, TEXT_BRIGHT)
        ui.spacer(4.0)
        ui.move_to(20.0, y + 32.0)
        ui.label(
            "Font size scale — affects all text in the app.",
            14,
            TEXT_DIM,
        )

        # Slider track
        var slider_x = 20.0
        var slider_y = y + 60.0
        var slider_w = sw_design - 40.0
        var slider_h = 14.0

        var slider_result = ui.slider(
            slider_x,
            slider_y,
            slider_w,
            slider_h,
            self.font_multiplier,
            vmin=0.5,
            vmax=3.0,
        )

        # Handle click + drag
        if slider_result.clicked:
            self.dragging_font_slider = True
        if not ui.mouse_down:
            self.dragging_font_slider = False
        if self.dragging_font_slider:
            var new_val = ui.slider_value_from_mouse(
                slider_result.bounds,
                ui.mouse_pos.x,
                vmin=0.5,
                vmax=3.0,
            )
            # Snap to 0.05 increments for a controlled feel.
            new_val = Float64(_round(new_val * 20.0)) / 20.0
            if new_val < 0.5:
                new_val = 0.5
            if new_val > 3.0:
                new_val = 3.0
            if new_val != self.font_multiplier:
                self.font_multiplier = new_val
                self.dirty = True

        # Value label (right-aligned above slider)
        var pct = _round(self.font_multiplier * 100.0)
        var val_text = String(pct) + "%"
        var val_meas = ui._measure_text(val_text, 16)
        var val_x = sw_design - 20.0 - ui.text_w_design(val_meas.x)
        ui.move_to(val_x, slider_y - 22.0)
        ui.label(val_text, 16, GREEN)

        # Preset buttons row
        var preset_y = slider_y + 26.0
        var presets = List[Float64]()
        presets.append(0.75)
        presets.append(1.0)
        presets.append(1.25)
        presets.append(1.5)
        presets.append(2.0)
        var preset_count = len(presets)
        var preset_w = 72.0
        var preset_gap = 10.0
        var px = 20.0
        for i in range(preset_count):
            var value = presets[i]
            var label = String(_round(value * 100.0)) + "%"
            var selected = abs(self.font_multiplier - value) < 0.001
            var bg = BTN_DARK_LIB
            if selected:
                bg = GREEN
            var fg = TEXT_LIGHT
            if selected:
                fg = ACCENT_DARK
            # Fitted width per button: labels like "125%" outgrow the 72px
            # base rect, so stride from the grown width to avoid overlap.
            var fit_w = ui.fitted_button_w(label, 22, preset_w)
            var r = ui.button_at(
                label,
                px,
                preset_y,
                preset_w,
                28.0,
                bg=bg,
                fg=fg,
                hover=Color(55, 64, 80, 255),
            )
            if r.clicked and not selected:
                self.font_multiplier = value
                self.dirty = True
            px = px + fit_w + preset_gap

    def _draw_keybind_section(
        mut self,
        mut ui: UIContext,
        sw_design: Float64,
        sh_design: Float64,
        y: Float64,
    ):
        """Scrollable list of keybind rows — keyboard + gamepad slots each."""
        # Section heading
        ui.move_to(20.0, y)
        ui.label("Keybinds", 22, TEXT_BRIGHT)
        ui.spacer(4.0)
        ui.move_to(20.0, y + 32.0)
        ui.label(
            "Click Rebind then press a key or gamepad button (Esc to cancel).",
            14,
            TEXT_DIM,
        )

        # Scrollable row area
        var list_top = y + 60.0
        var list_bottom = sh_design - 80.0
        var list_height = list_bottom - list_top

        ui.begin_clip(0.0, list_top, sw_design, list_height)

        var actions = _action_names()
        var row_h = 56.0
        var row_gap = 8.0
        var scroll_design = Float64(self.scroll_offset) / Float64(ui.ui_scale)
        var row_x = 20.0
        var row_w = sw_design - 40.0

        # Layout columns (design px fractions of row_w):
        #   action label: 0.30 | kb binding: 0.22 | kb btn: 0.08
        #   gp binding: 0.22 | gp btn: 0.08
        #   (sums to 0.90, leaving 0.10 for padding/margins)
        var label_frac = 0.28
        var kb_bind_frac = 0.24
        var btn_frac = 0.09
        var gp_bind_frac = 0.24

        var btn_w_local = row_w * btn_frac
        var btn_h_local = 32.0

        for i in range(len(actions)):
            var action = actions[i]
            var row_y = (
                list_top - scroll_design + Float64(i) * (row_h + row_gap)
            )

            # Skip off-screen rows
            if row_y + row_h < list_top:
                continue
            if row_y > list_bottom:
                break

            var is_rebinding = self.rebinding_action == action
            var bg = CARD_BG
            if is_rebinding:
                bg = SELECTED_BG

            # Row card
            var r = ui.rect(row_x, row_y, row_w, row_h)
            ui.canvas[unsafe_offset=0].fill_rect_rounded(
                Float64(r.x),
                Float64(r.y),
                Float64(r.width),
                Float64(r.height),
                0.06,
                bg,
            )
            ui.canvas[unsafe_offset=0].outline_rect_rounded(
                Float64(r.x),
                Float64(r.y),
                Float64(r.width),
                Float64(r.height),
                0.06,
                1.5,
                BORDER_FOCUS if is_rebinding else BORDER_IDLE,
            )

            # --- Action label (left) ---
            var label = _action_label(action)
            var label_x = row_x + 16.0
            var label_w = row_w * label_frac - 16.0
            ui.move_to(label_x, row_y + (row_h - 18.0) / 2.0)
            ui.cursor_w = Float32(label_w) * ui.ui_scale
            ui.label(label, 18, TEXT_BRIGHT)

            # --- Keyboard binding display ---
            var kb_bind_x = row_x + row_w * label_frac
            var kb_bind_w = row_w * kb_bind_frac
            ui.move_to(kb_bind_x, row_y + (row_h - 16.0) / 2.0)
            ui.cursor_w = Float32(kb_bind_w) * ui.ui_scale
            if is_rebinding and not self.rebinding_is_gamepad:
                ui.label("Press a key...", 14, GREEN)
            else:
                var kb_binding = self._kb_binding_display(action)
                ui.label(kb_binding, 14, TEXT_LIGHT)

            # --- KB Rebind button ---
            var kb_btn_x = kb_bind_x + kb_bind_w + 4.0
            var kb_btn_y = row_y + (row_h - btn_h_local) / 2.0
            var is_kb_rebinding = is_rebinding and not self.rebinding_is_gamepad
            var kb_btn = ui.button_at(
                "KB" if not is_kb_rebinding else "X",
                kb_btn_x,
                kb_btn_y,
                btn_w_local,
                btn_h_local,
                bg=BTN_DARK_LIB if not is_kb_rebinding else LOGOUT_RED,
                fg=TEXT_LIGHT,
                hover=Color(55, 64, 80, 255),
            )
            if kb_btn.clicked:
                if is_kb_rebinding:
                    self._cancel_rebind()
                else:
                    self.rebinding_action = action
                    self.rebinding_is_gamepad = False
                    self.status_message = "Press a key for " + label
                    self.status_color = GREEN

            # --- Gamepad binding display ---
            var gp_bind_x = kb_btn_x + btn_w_local + 8.0
            var gp_bind_w = row_w * gp_bind_frac
            ui.move_to(gp_bind_x, row_y + (row_h - 16.0) / 2.0)
            ui.cursor_w = Float32(gp_bind_w) * ui.ui_scale
            if is_rebinding and self.rebinding_is_gamepad:
                ui.label("Press a button...", 14, GREEN)
            else:
                var gp_binding = self._gp_binding_display(action)
                ui.label(gp_binding, 14, TEXT_LIGHT)

            # --- GP Rebind button ---
            var gp_btn_x = gp_bind_x + gp_bind_w + 4.0
            var gp_btn_y = row_y + (row_h - btn_h_local) / 2.0
            var is_gp_rebinding = is_rebinding and self.rebinding_is_gamepad
            var gp_btn = ui.button_at(
                "GP" if not is_gp_rebinding else "X",
                gp_btn_x,
                gp_btn_y,
                btn_w_local,
                btn_h_local,
                bg=BTN_DARK_LIB if not is_gp_rebinding else LOGOUT_RED,
                fg=TEXT_LIGHT,
                hover=Color(55, 64, 80, 255),
            )
            if gp_btn.clicked:
                if is_gp_rebinding:
                    self._cancel_rebind()
                else:
                    self.rebinding_action = action
                    self.rebinding_is_gamepad = True
                    self.status_message = "Press a gamepad button for " + label
                    self.status_color = GREEN

        ui.end_clip()

    def _draw_footer(
        mut self, mut ui: UIContext, sw_design: Float64, y: Float64
    ):
        """Save / Reset buttons + status line."""
        var btn_w = 140.0
        var btn_h = 36.0
        var gap = 12.0

        # Reset (left)
        var reset_result = ui.button_at(
            "RESET",
            20.0,
            y,
            btn_w,
            btn_h,
            bg=BTN_DARK_LIB,
            fg=TEXT_LIGHT,
            hover=Color(55, 64, 80, 255),
        )
        if reset_result.clicked:
            self.reset_requested = True

        # Save (right of reset)
        var save_bg = GREEN
        if not self.dirty:
            save_bg = Color(90, 120, 70, 255)
        var save_result = ui.button_at(
            "SAVE",
            20.0 + btn_w + gap,
            y,
            btn_w,
            btn_h,
            bg=save_bg,
            fg=ACCENT_DARK,
            hover=Color(140, 192, 88, 255),
        )
        if save_result.clicked and self.dirty:
            self.save_requested = True

        # Status message (right-aligned)
        if self.status_message.byte_length() > 0:
            var meas = ui._measure_text(self.status_message, 14)
            var sx = sw_design - 20.0 - ui.text_w_design(meas.x)
            ui.move_to(sx, y + 10.0)
            ui.label(self.status_message, 14, self.status_color)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _pretty_binding(spec: String) -> String:
    """Convert a key spec like 'KEY_LEFT_SHIFT+KEY_LEFT' to 'Shift + Left'.

    Strips the 'KEY_' prefix and humanizes modifier names. Falls back to
    the raw spec if parsing fails.
    """
    var parts = spec.split("+")
    var pretty_parts = List[String]()
    for i in range(len(parts)):
        var raw = String(parts[i])
        pretty_parts.append(_pretty_key_name(raw))
    # Join with " + "
    var result = String()
    for i in range(len(pretty_parts)):
        if i > 0:
            result = result + " + "
        result = result + pretty_parts[i]
    return result


def _pretty_key_name(raw: String) -> String:
    """Humanize a single key or gamepad button name.

    Keys:     'KEY_LEFT' -> 'Left', 'KEY_LEFT_SHIFT' -> 'Shift'
    Gamepad:  'GAMEPAD_BUTTON_RIGHT_FACE_UP' -> 'A', 'LEFT_FACE_DOWN' -> 'D-Pad Down'
    """
    # --- Gamepad buttons (prefix GAMEPAD_BUTTON_) ---
    if raw.startswith("GAMEPAD_BUTTON_"):
        var gp_body = truncate_string(
            raw, raw.byte_length() - 15
        )  # strip "GAMEPAD_BUTTON_"
        # Right face (Xbox ABXY / PlayStation symbols).
        if gp_body == "RIGHT_FACE_UP":
            return "A"
        if gp_body == "RIGHT_FACE_RIGHT":
            return "B"
        if gp_body == "RIGHT_FACE_DOWN":
            return "X"
        if gp_body == "RIGHT_FACE_LEFT":
            return "Y"
        # D-Pad.
        if gp_body == "LEFT_FACE_UP":
            return "D-Pad Up"
        if gp_body == "LEFT_FACE_RIGHT":
            return "D-Pad Right"
        if gp_body == "LEFT_FACE_DOWN":
            return "D-Pad Down"
        if gp_body == "LEFT_FACE_LEFT":
            return "D-Pad Left"
        # Triggers / bumpers.
        if gp_body == "LEFT_TRIGGER_1":
            return "L1"
        if gp_body == "LEFT_TRIGGER_2":
            return "L2"
        if gp_body == "RIGHT_TRIGGER_1":
            return "R1"
        if gp_body == "RIGHT_TRIGGER_2":
            return "R2"
        # Middle buttons.
        if gp_body == "MIDDLE_LEFT":
            return "Back"
        if gp_body == "MIDDLE":
            return "Guide"
        if gp_body == "MIDDLE_RIGHT":
            return "Start"
        # Thumbstick clicks.
        if gp_body == "LEFT_THUMB":
            return "L3"
        if gp_body == "RIGHT_THUMB":
            return "R3"
        # Unknown — return the stripped body.
        return gp_body

    if not raw.startswith("KEY_"):
        return raw
    # Strip the 4-byte "KEY_" prefix. String has no slicing in Mojo 1.0, so
    # use truncate_string to take the first (byte_length - 4) characters.
    var body = truncate_string(raw, raw.byte_length() - 4)
    # Special-case modifiers to short names.
    if body == "LEFT_SHIFT" or body == "RIGHT_SHIFT":
        return "Shift"
    if body == "LEFT_CONTROL" or body == "RIGHT_CONTROL":
        return "Ctrl"
    if body == "LEFT_ALT" or body == "RIGHT_ALT":
        return "Alt"
    if body == "LEFT_SUPER" or body == "RIGHT_SUPER":
        return "Super"
    # Strip a leading direction prefix for readability: LEFT_BRACKET -> [
    # is awkward, so keep it; but LEFT/RIGHT/UP/DOWN stay as-is.
    if body == "LEFT":
        return "Left"
    if body == "RIGHT":
        return "Right"
    if body == "UP":
        return "Up"
    if body == "DOWN":
        return "Down"
    if body == "SPACE":
        return "Space"
    if body == "ENTER":
        return "Enter"
    if body == "TAB":
        return "Tab"
    if body == "BACKSPACE":
        return "Backspace"
    if body == "ESCAPE":
        return "Esc"
    if body == "DELETE":
        return "Delete"
    if body == "INSERT":
        return "Insert"
    if body == "HOME":
        return "Home"
    if body == "END":
        return "End"
    if body == "PAGE_UP":
        return "Page Up"
    if body == "PAGE_DOWN":
        return "Page Down"
    if body == "MINUS":
        return "-"
    if body == "EQUAL":
        return "="
    if body == "COMMA":
        return ","
    if body == "PERIOD":
        return "."
    if body == "SLASH":
        return "/"
    if body == "SEMICOLON":
        return ";"
    if body == "APOSTROPHE":
        return "'"
    if body == "LEFT_BRACKET":
        return "["
    if body == "RIGHT_BRACKET":
        return "]"
    if body == "BACKSLASH":
        return "\\"
    if body == "GRAVE":
        return "`"
    # Single letters / digits: drop the word, keep the char-ish form by
    # title-casing (A stays A, ONE -> 1).
    if body == "ZERO":
        return "0"
    if body == "ONE":
        return "1"
    if body == "TWO":
        return "2"
    if body == "THREE":
        return "3"
    if body == "FOUR":
        return "4"
    if body == "FIVE":
        return "5"
    if body == "SIX":
        return "6"
    if body == "SEVEN":
        return "7"
    if body == "EIGHT":
        return "8"
    if body == "NINE":
        return "9"
    # F-keys: F1 stays F1.
    if body.startswith("F"):
        return body
    # Default: return body as-is.
    return body
