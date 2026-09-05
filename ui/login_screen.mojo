from resources.color import Color
from ui.imui import Vec2

from functions.ascii import AsciiTable
from functions.helpers import format_time
from functions.plex_bridge import PlexSession
from functions.plex_oauth import start_oauth, open_browser, wait_for_auth

from resources.palette import (
    WHITE,
    LOGIN_BG,
    GREEN,
    INPUT_BG,
    TEXT_BRIGHT,
    TEXT_LIGHT,
    TEXT_DIM,
    ACCENT_DARK,
    ERROR_COLOR,
    BORDER_FOCUS,
    BORDER_IDLE,
    CARD_BG,
    FOOTER_COLOR,
    LIBRARY_BG,
    LIB_CARD_BG,
    LOGOUT_RED,
    DOWNLOAD_BLUE,
    DOWNLOADED_GREEN,
    BTN_DARK_LIB,
    PLACEHOLDER_BG,
    TEXT_MUTED,
    SELECTED_BG,
    PLAYER_BG,
    PLAYER_INFO_BG,
    SLIDER_BG,
    SLIDER_FILL,
    CHAPTER_HIGHLIGHT,
    BTN_CONTROL,
    BULLET,
    CHECKMARK,
)

from ui.widgets import TextInput, Button, Checkbox, PlexBookCard
from ui.font import FontSet
from ui.imui import UIContext, UIResult
from ui import Screen

# ---------------------------------------------------------------------------
# Login screen — OAuth PIN flow (immediate-mode UI)
# ---------------------------------------------------------------------------


struct LoginScreen:
    var status_message: String
    var status_color: Color
    var auth_complete: Bool  # Set True when OAuth succeeds, triggers transition to SelectionScreen

    def __init__(out self, screen_w: Int, screen_h: Int):
        # No retained button state — IMUI draws + handles input each frame.
        self.status_message = ""
        self.status_color = TEXT_LIGHT
        self.auth_complete = False

    def handle_mouse_click(
        mut self, mouse_pos: Vec2, mut app_state: PlexSession
    ) raises:
        # IMUI handles clicks inside draw() — this is a no-op kept for the
        # main-loop dispatch contract. The actual connect click is processed
        # in draw() via ui.button(...).clicked.
        pass

    def handle_keyboard(
        mut self, enter_pressed: Bool, mut app_state: PlexSession
    ) raises:
        """Handle key input — Enter triggers connect (key routing in main)."""
        if enter_pressed:
            self._on_connect(app_state)

    def _on_connect(mut self, mut app_state: PlexSession) raises:
        """Plex OAuth PIN flow: authenticate via browser, then hand off to SelectionScreen.
        """

        # --- Step 1: Start OAuth PIN flow ---
        self.status_message = "Starting Plex login..."
        self.status_color = TEXT_LIGHT

        var pin_result = start_oauth()
        var pin_id = pin_result.id
        var pin_code = pin_result.code
        var client_id = pin_result.client_identifier

        # Guard: PIN creation failed
        if pin_id == 0 or pin_code.byte_length() == 0:
            var err_msg = pin_result.error
            if err_msg.byte_length() == 0:
                err_msg = "Failed to create Plex PIN"
            self.status_message = err_msg
            self.status_color = ERROR_COLOR
            return

        # --- Step 2: Open browser for user to authorize ---
        _ = open_browser(pin_code, client_id)
        self.status_message = "Waiting for authorization in browser..."
        self.status_color = TEXT_LIGHT

        # --- Step 3: Poll until token arrives (blocking) ---
        var auth_result = wait_for_auth(pin_id, client_id)
        var auth_token = auth_result.auth_token

        # Guard: authorization failed or timed out
        if auth_token.byte_length() == 0:
            var expired = auth_result.expired
            var err_msg = auth_result.error
            if err_msg.byte_length() == 0:
                if expired:
                    err_msg = "Authorization timed out"
                else:
                    err_msg = "Authorization failed"
            self.status_message = err_msg
            self.status_color = ERROR_COLOR
            return

        # Store auth data for SelectionScreen to consume
        app_state.account_token = auth_token
        app_state.client_id = client_id

        self.status_message = "Authorized! Discovering servers..."
        self.status_color = GREEN
        self.auth_complete = True

    def draw(mut self, mut ui: UIContext, mut app_state: PlexSession) raises:
        """Render the OAuth-only login screen (immediate-mode)."""
        var sw_design = Float64(ui.screen_w) / Float64(ui.ui_scale)
        var sh_design = Float64(ui.screen_h) / Float64(ui.ui_scale)

        # --- Title section (centered, ~12% down) ---
        var title_y = sh_design * 0.12
        ui.move_to(0.0, title_y)
        ui.label_centered("Quire", 42, GREEN)

        # Subtitle
        ui.label_centered("Plex Audiobook Client", 22, TEXT_DIM)

        # --- Login card ---
        var card_w = sw_design * 0.70
        var card_h = sh_design * 0.35
        var card_x = (sw_design - card_w) / 2.0
        var card_y = sh_design * 0.30

        ui.card(card_x, card_y, card_w, card_h, CARD_BG, roundness=0.04)

        # Card label (inside card, centered)
        ui.move_to(card_x, card_y + 30.0)
        ui.label_centered("Sign in with your Plex account", 18, TEXT_LIGHT)

        # --- Connect button (inside card, full width minus padding) ---
        var pad = 40.0
        var btn_h = 56.0
        ui.move_to(card_x + pad, card_y + card_h * 0.55)
        # Constrain button width to card width minus padding on both sides
        ui.cursor_w = Float32(card_w - pad * 2.0) * ui.ui_scale
        var result = ui.button("CONNECT WITH PLEX", btn_h)

        if result.clicked:
            self._on_connect(app_state)

        # --- Status message (below button, centered) ---
        if self.status_message.byte_length() > 0:
            var status_y = card_y + card_h * 0.55 + btn_h + 16.0
            ui.move_to(0.0, status_y)
            ui.label_centered(self.status_message, 16, self.status_color)

        # --- Footer ---
        ui.move_to(0.0, sh_design - 30.0)
        ui.label_centered("Plex audiobook client", 12, FOOTER_COLOR)
