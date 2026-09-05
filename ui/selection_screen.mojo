from resources.color import Color
from resources.keys import (
    KEY_BACKSPACE,
    KEY_TAB,
    KEY_ENTER,
    KEY_DELETE,
    KEY_ESCAPE,
)
from ui.imui import UIContext, UIResult, Vec2, Rect

from functions.helpers import (
    format_time,
    truncate_string,
)
from functions.plex_bridge import (
    PlexSession,
    get_libraries,
    get_book_detail,
    get_book_tracks,
    get_track_chapters,
    start_play_queue,
    download_track,
    get_thumbnail_url,
    report_progress,
    mark_watched,
)

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

from ui import Screen
from ui.font import FontSet
from ui.imui import UIContext, UIResult
from ui.plex_objects import PlexTrack, PlexChapter, LibraryItem, ServerItem
from ui.widgets import TextInput, Button, Checkbox, PlexBookCard


# ---------------------------------------------------------------------------
# Selection screen — pick server and library (immediate-mode UI)
# ---------------------------------------------------------------------------


struct SelectionScreen:
    var phase: Int  # 0 = picking server, 1 = picking library
    var servers: List[ServerItem]
    var selected_server_idx: Int  # -1 = none selected yet
    var libraries: List[LibraryItem]
    var selected_library_idx: Int  # -1 = none selected yet
    var account_token: String
    var client_id: String
    var status_message: String
    var status_color: Color
    var scroll_offset: Float32
    var selection_complete: Bool

    def __init__(out self, screen_w: Int, screen_h: Int):
        self.phase = 0
        self.servers = List[ServerItem]()
        self.selected_server_idx = -1
        self.libraries = List[LibraryItem]()
        self.selected_library_idx = -1
        self.account_token = ""
        self.client_id = ""
        self.status_message = ""
        self.status_color = TEXT_DIM
        self.scroll_offset = 0.0
        self.selection_complete = False

    def load_servers(
        mut self,
        servers: List[ServerItem],
        account_token: String,
        client_id: String,
    ) raises:
        """Receive pre-tested server list, populate selection."""
        self.account_token = account_token
        self.client_id = client_id
        self.servers = servers.copy()
        self.status_message = "Select a server"
        self.status_color = TEXT_DIM

        # Guard: no reachable servers
        if len(self.servers) == 0:
            self.status_message = "No reachable Plex server"
            self.status_color = ERROR_COLOR
            return

        # Auto-select if only 1 server
        if len(self.servers) == 1:
            self.selected_server_idx = 0
            self.status_message = "Server: " + self.servers[0].name
            self.status_color = GREEN
            self.phase = 1
            self._load_libraries()
            return

    def _load_libraries(mut self) raises:
        """Fetch libraries from the selected server and populate the list."""
        if self.selected_server_idx < 0 or self.selected_server_idx >= len(
            self.servers
        ):
            return

        var server = self.servers[self.selected_server_idx]
        self.status_message = "Loading libraries..."
        self.status_color = TEXT_LIGHT
        self.libraries = List[LibraryItem]()

        var libraries = get_libraries(
            server.url,
            server.token,
            self.client_id,
        )
        self.libraries = libraries.copy()

        # Guard: no libraries
        if len(self.libraries) == 0:
            self.status_message = "No libraries found on server"
            self.status_color = ERROR_COLOR
            return

        # Auto-select if only 1 "artist"-type library
        var artist_count = 0
        var artist_idx = -1
        for i in range(len(self.libraries)):
            if self.libraries[i].lib_type == "artist":
                artist_count += 1
                if artist_idx == -1:
                    artist_idx = i

        if artist_count == 1 and artist_idx >= 0:
            self.selected_library_idx = artist_idx
            self._complete_selection()
            return

        self.status_message = "Select a library"
        self.status_color = TEXT_DIM

    def _complete_selection(mut self) raises:
        """Mark selection as complete after both server and library are chosen.
        """
        if self.selected_server_idx < 0 or self.selected_library_idx < 0:
            return

        var server = self.servers[self.selected_server_idx]
        var library = self.libraries[self.selected_library_idx]
        self.status_message = "Selected: " + server.name + " / " + library.title
        self.status_color = GREEN
        self.selection_complete = True

    def handle_mouse_click(
        mut self,
        mouse_pos: Vec2,
        mut app_state: PlexSession,
        mut screen: Screen,
        screen_w: Int,
        screen_h: Int,
    ) raises:
        # IMUI handles clicks inside draw() — no-op for main-loop contract.
        pass

    def handle_scroll(mut self, wheel_delta: Float32, screen_h: Int):
        """Adjust scroll offset for the card list."""
        var item_count = len(self.servers)
        if self.phase == 1:
            item_count = len(self.libraries)

        if item_count == 0:
            return

        # Design-pixel card layout constants (must match draw())
        var card_h = 72.0
        var card_gap = 10.0
        var header_h = 65.0
        # Use the same design-coordinate math as draw; scroll_offset is in
        # design pixels so it stays consistent with ui_scale.
        var total_height = Float64(item_count) * (card_h + card_gap) - card_gap
        var visible_height = Float64(screen_h) / 1.0 - header_h - 30.0

        # Convert scroll to design-pixel space: wheel_delta is already scaled
        # by dpi_scale in main.mojo. We apply the design-space factor here.
        # To keep things simple, scroll_offset is stored in screen pixels and
        # converted in draw() via ui_scale.
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
        """Render the selection screen (immediate-mode)."""
        var sw_design = Float64(ui.screen_w) / Float64(ui.ui_scale)
        var sh_design = Float64(ui.screen_h) / Float64(ui.ui_scale)

        # --- Header bar ---
        var header_h = 50.0
        ui.panel_bg(0.0, 0.0, sw_design, header_h, LIBRARY_BG)

        # Back button (fixed width in header)
        var btn_w = sw_design * 0.15
        var btn_h = 36.0
        ui.move_to(20.0, 7.0)
        ui.cursor_w = Float32(btn_w) * ui.ui_scale
        var back_result = ui.button(
            "< BACK",
            btn_h,
            BTN_DARK_LIB,
            TEXT_LIGHT,
            Color(55, 64, 80, 255),
        )
        if back_result.clicked:
            if self.phase == 1:
                self.phase = 0
                self.selected_library_idx = -1
                self.libraries = List[LibraryItem]()
                self.scroll_offset = 0.0
                self.status_message = "Select a server"
                self.status_color = TEXT_DIM
            else:
                screen.current = 0
            return

        # Title (centered)
        var title_text = "Select Server"
        if self.phase == 1:
            title_text = "Select Library"
        ui.move_to(0.0, 14.0)
        ui.label_centered(title_text, 22, GREEN)

        # --- Status line ---
        var status_y = header_h + 5.0
        if self.status_message.byte_length() > 0:
            ui.move_to(20.0, status_y)
            ui.label(self.status_message, 14, self.status_color)

        # --- Scrollable card list ---
        var list_top = status_y + 20.0
        var list_bottom = sh_design - 10.0
        var list_height = list_bottom - list_top

        ui.begin_clip(0.0, list_top, sw_design, list_height)

        var card_pad = 20.0
        var card_gap = 10.0
        var card_w = sw_design - card_pad * 2.0
        var card_h = 72.0
        var inner_pad = 12.0
        var icon_w = 44.0

        # scroll_offset is in screen px; convert to design px for layout
        var scroll_design = Float64(self.scroll_offset) / Float64(ui.ui_scale)
        var list_y_design = list_top - scroll_design

        if self.phase == 0:
            # --- Server cards ---
            for i in range(len(self.servers)):
                var card_y = list_y_design + Float64(i) * (card_h + card_gap)
                var server = self.servers[i]

                # Skip off-screen cards
                if card_y + card_h < list_top:
                    continue
                if card_y > list_bottom:
                    break

                var selected = i == self.selected_server_idx
                var row_result = ui.selectable_row(
                    card_pad, card_y, card_w, card_h, selected
                )

                if row_result.clicked:
                    self.selected_server_idx = i
                    self.phase = 1
                    self.scroll_offset = 0.0
                    self._load_libraries()
                    ui.end_clip()
                    return

                # Left icon area
                var icon_x = card_pad + inner_pad
                var icon_y = card_y + inner_pad
                ui.card(
                    icon_x,
                    icon_y,
                    icon_w,
                    card_h - inner_pad * 2.0,
                    PLACEHOLDER_BG,
                    roundness=0.08,
                )

                # Server icon
                var icon_label = "o"  # ▫
                ui.move_to(
                    icon_x, icon_y + (card_h - inner_pad * 2.0 - 16.0) / 2.0
                )
                ui.cursor_w = Float32(icon_w) * ui.ui_scale
                ui.label_centered(icon_label, 16, TEXT_DIM)

                # Server name
                var info_x = icon_x + icon_w + 12.0
                var name_y = card_y + 16.0
                var max_info_w = card_w - icon_w - inner_pad * 2.0 - 12.0 - 80.0
                var title_text_val = server.name
                var name_meas = ui._measure_text(title_text_val, 16)
                if name_meas.x > Float32(max_info_w) * ui.font_scale:
                    var max_chars = Int(max_info_w / 9.0)
                    if max_chars > 3:
                        title_text_val = (
                            truncate_string(title_text_val, max_chars - 3)
                            + "..."
                        )
                    else:
                        title_text_val = truncate_string(
                            title_text_val, max_chars
                        )

                ui.move_to(info_x, name_y)
                ui.label(title_text_val, 16, TEXT_BRIGHT)

                # Server URL subtitle
                ui.move_to(info_x, name_y + 22.0)
                var url_text = server.url
                var url_meas = ui._measure_text(url_text, 14)
                if url_meas.x > Float32(max_info_w) * ui.font_scale:
                    var max_chars = Int(max_info_w / 8.0)
                    if max_chars > 3:
                        url_text = (
                            truncate_string(url_text, max_chars - 3) + "..."
                        )
                    else:
                        url_text = truncate_string(url_text, max_chars)
                ui.label(url_text, 16, TEXT_DIM)

                # Right badge
                var badge_text = "Owned"
                var badge_color = GREEN
                if not server.is_owned:
                    badge_text = "Shared"
                    badge_color = TEXT_DIM

                var badge_meas = ui._measure_text(badge_text, 12)
                var badge_x = (
                    card_pad
                    + card_w
                    - inner_pad
                    - ui.text_w_design(badge_meas.x)
                )
                var badge_y = (
                    card_y + (card_h - ui.text_h_design(badge_meas.y)) / 2.0
                )
                ui.move_to(badge_x, badge_y)
                ui.label(badge_text, 16, badge_color)

        elif self.phase == 1:
            # --- Library cards ---
            for i in range(len(self.libraries)):
                var card_y = list_y_design + Float64(i) * (card_h + card_gap)
                var library = self.libraries[i]

                if card_y + card_h < list_top:
                    continue
                if card_y > list_bottom:
                    break

                var selected = i == self.selected_library_idx
                var row_result = ui.selectable_row(
                    card_pad, card_y, card_w, card_h, selected
                )

                if row_result.clicked:
                    self.selected_library_idx = i
                    self._complete_selection()
                    ui.end_clip()
                    return

                # Left icon area
                var icon_x = card_pad + inner_pad
                var icon_y = card_y + inner_pad
                ui.card(
                    icon_x,
                    icon_y,
                    icon_w,
                    card_h - inner_pad * 2.0,
                    PLACEHOLDER_BG,
                    roundness=0.08,
                )

                # Library icon
                var icon_label = "M"  # ♫
                if library.lib_type != "artist":
                    icon_label = "d"  # ▼
                ui.move_to(
                    icon_x, icon_y + (card_h - inner_pad * 2.0 - 16.0) / 2.0
                )
                ui.cursor_w = Float32(icon_w) * ui.ui_scale
                ui.label_centered(icon_label, 16, TEXT_DIM)

                # Library title
                var info_x = icon_x + icon_w + 12.0
                var name_y = card_y + 16.0
                var max_info_w = (
                    card_w - icon_w - inner_pad * 2.0 - 12.0 - 100.0
                )
                var title_text_val = library.title
                var name_meas = ui._measure_text(title_text_val, 16)
                if name_meas.x > Float32(max_info_w) * ui.font_scale:
                    var max_chars = Int(max_info_w / 9.0)
                    if max_chars > 3:
                        title_text_val = (
                            truncate_string(title_text_val, max_chars - 3)
                            + "..."
                        )
                    else:
                        title_text_val = truncate_string(
                            title_text_val, max_chars
                        )

                ui.move_to(info_x, name_y)
                ui.label(title_text_val, 16, TEXT_BRIGHT)

                # Library type subtitle
                ui.move_to(info_x, name_y + 22.0)
                ui.label(library.lib_type, 16, TEXT_DIM)

                # Right badge
                var badge_text = library.title
                var badge_color = GREEN
                if library.lib_type != "artist":
                    badge_text = library.lib_type
                    badge_color = TEXT_DIM

                var badge_meas = ui._measure_text(badge_text, 12)
                var badge_x = (
                    card_pad
                    + card_w
                    - inner_pad
                    - ui.text_w_design(badge_meas.x)
                )
                var badge_y = (
                    card_y + (card_h - ui.text_h_design(badge_meas.y)) / 2.0
                )
                ui.move_to(badge_x, badge_y)
                ui.label(badge_text, 16, badge_color)

        ui.end_clip()
