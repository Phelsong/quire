from resources.color import Color
from std.collections import Dict, Optional
from std.memory import alloc, Layout
from std.memory.unsafe_pointer import Pointer
from resources.imdecode import imdecode
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
from functions.ascii import AsciiTable
from functions.plex_bridge import (
    PlexSession,
    get_audiobooks,
    search_audiobooks,
    get_book_detail,
    get_book_tracks,
    get_track_chapters,
    start_play_queue,
    download_track,
    get_thumbnail_url,
    fetch_thumbnail,
    load_cached_cover,
    save_cached_cover,
    report_progress,
    mark_watched,
)

from ui.widgets import TextInput, Button, Checkbox, PlexBookCard
from ui.font import FontSet
from ui import Screen
from ui.plex_objects import PlexTrack, PlexChapter, LibraryItem, ServerItem
from ui.icons import ICON_PLAY, ICON_PAUSE, ICON_SETTINGS
from ui.player_screen import PlayerScreen


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

# ---------------------------------------------------------------------------
# Library screen — browse audiobooks (immediate-mode UI)
# ---------------------------------------------------------------------------


struct LibraryScreen:
    var books: List[PlexBookCard]
    var status_message: String
    var status_color: Color
    var scroll_offset: Float32
    var library_name: String
    var data_loaded: Bool
    var play_requested: Bool  # Set to True when PLAY is clicked
    var play_book_index: Int  # Index of the book to play
    # Download request (SAVE button). Consumed by main.mojo outside the
    # render loop: fetches the book's tracks, then streams the file into
    # the audio cache so playback prefers the local copy.
    var download_requested: Bool
    var download_book_index: Int

    # Pagination (server-side via Plex X-Plex-Container-Start/Size).
    # page is 0-based; page_size is the fetch chunk; total_size is the
    # whole-library count reported by Plex (may be 0 if unknown).
    var page: Int
    var page_size: Int
    var total_size: Int
    # Flags consumed by main.mojo to trigger a re-fetch (draw() can't call
    # load_data because it would block the render loop on the network call).
    var next_page_requested: Bool
    var prev_page_requested: Bool

    # Server-side search. When the search bar text changes, draw() sets
    # search_query_requested + pending_search_query; main.mojo consumes the
    # flag and calls run_search() (outside the render loop so the network
    # call doesn't block mid-draw). `active_search` is the query currently
    # reflected in `books` (empty = normal paginated view).
    var search_input: TextInput
    var active_search: String  # query reflected in `books` ("" = page mode)
    var search_query_requested: Bool
    var pending_search_query: String

    # Lazy per-book cover cache, keyed by rating_key. Loaded AFTER the rest
    # of the screen renders: draw() queues visible rows, and one queued
    # cover is fetched per frame (a blocking HTTP call) so the UI never
    # stalls on thumbnails. `covers_loaded` marks exhausted rows.
    var cover_pixels: Dict[String, Optional[Pointer[UInt8, MutUntrackedOrigin]]]
    var cover_sizes: Dict[String, Int]
    var cover_queue: List[String]  # rating_keys pending fetch
    var covers_done: Dict[String, Bool]  # rating_key -> fetched (or failed)

    def __init__(out self, screen_w: Int, screen_h: Int):
        self.books = List[PlexBookCard]()
        self.status_message = ""
        self.status_color = TEXT_DIM
        self.scroll_offset = 0.0
        self.library_name = "Libraries"
        self.data_loaded = False
        self.play_requested = False
        self.play_book_index = -1
        self.download_requested = False
        self.download_book_index = -1

        self.page = 0
        self.page_size = 25
        self.total_size = 0
        self.next_page_requested = False
        self.prev_page_requested = False

        self.cover_pixels = Dict[
            String, Optional[Pointer[UInt8, MutUntrackedOrigin]]
        ]()
        self.cover_sizes = Dict[String, Int]()
        self.cover_queue = List[String]()
        self.covers_done = Dict[String, Bool]()

        # Search bar: spans the area below the header. Bounds are in screen
        # px (matching ui.mouse_pos); updated each frame in draw() to track
        # DPI/window changes. Placeholder shows a hint when empty/unfocused.
        self.search_input = TextInput(
            "",
            "Search title or author...",
            False,
            Rect(0.0, 0.0, 1.0, 1.0),
            INPUT_BG,
            TEXT_BRIGHT,
        )
        self.active_search = ""
        self.search_query_requested = False
        self.pending_search_query = ""

    def load_data(mut self, app_state: PlexSession) raises:
        """Fetch audiobooks from Plex server and populate the book list.

        Uses the current page/page_size for server-side pagination via Plex's
        X-Plex-Container-Start/Size headers. Stores total_size for page count.
        Resets the search filter.
        """
        self.status_message = "Loading page " + String(self.page + 1) + "..."
        self.status_color = TEXT_DIM

        var token = app_state.server_token
        if token.byte_length() == 0:
            token = app_state.account_token

        # Guard: no token available
        if token.byte_length() == 0:
            self.status_message = "Not authenticated"
            self.status_color = ERROR_COLOR
            self.data_loaded = True
            return

        # Guard: no library selected
        if app_state.library_id.byte_length() == 0:
            self.status_message = "No library selected"
            self.status_color = ERROR_COLOR
            self.data_loaded = True
            return

        try:
            var start = self.page * self.page_size
            var result = get_audiobooks(
                app_state.server_url,
                token,
                app_state.library_id,
                start=start,
                size=self.page_size,
                client_id=app_state.client_id,
            )

            if result.error_code != 0:
                self.status_message = "Server error " + String(
                    result.error_code
                )
                self.status_color = ERROR_COLOR
            else:
                self.books = List[PlexBookCard]()
                for i in range(len(result.items)):
                    self.books.append(result.items[i].copy())

                self.total_size = result.total_size
                self.library_name = app_state.library_name
                var page_count = self._page_count()
                self.status_message = (
                    "Page "
                    + String(self.page + 1)
                    + " of "
                    + String(page_count)
                    + "  ("
                    + String(len(result.items))
                    + " books)"
                )
                self.status_color = GREEN
                # Reset scroll to top on (re)load.
                self.scroll_offset = 0.0
                # We're in page mode (no active search).
                self.active_search = ""
        except e:
            self.status_message = "Failed to load library"
            self.status_color = ERROR_COLOR

        # New book list: drop stale cover cache entries so keys are
        # re-queued for visible rows on the next frames.
        self.cover_queue = List[String]()

        self.data_loaded = True

    def _page_count(self) -> Int:
        """Total number of pages, or 1 if total_size is unknown (0)."""
        if self.total_size <= 0:
            return 1
        var pages = self.total_size // self.page_size
        if self.total_size % self.page_size != 0:
            pages += 1
        if pages < 1:
            pages = 1
        return pages

    def run_search(mut self, app_state: PlexSession, query: String) raises:
        """Fetch server-side search results for `query` and replace `books`.

        Called from main.mojo when draw() sets search_query_requested. An
        empty query clears the search and reloads the current page.
        """
        if query.byte_length() == 0:
            self.active_search = ""
            self.load_data(app_state)
            return

        self.status_message = 'Searching "' + query + '"...'
        self.status_color = TEXT_DIM

        var token = app_state.server_token
        if token.byte_length() == 0:
            token = app_state.account_token

        try:
            var result = search_audiobooks(
                app_state.server_url,
                token,
                app_state.library_id,
                query,
                client_id=app_state.client_id,
            )
            if result.error_code != 0:
                self.status_message = "Search failed (server error)"
                self.status_color = ERROR_COLOR
                return
            self.books = List[PlexBookCard]()
            for i in range(len(result.items)):
                self.books.append(result.items[i].copy())
            self.active_search = query
            self.status_message = (
                'Search "'
                + query
                + '" — '
                + String(len(self.books))
                + " results"
            )
            self.status_color = GREEN
            self.scroll_offset = 0.0
        except e:
            self.status_message = "Search failed: " + String(e)
            self.status_color = ERROR_COLOR

        # New book list: drop stale cover queue (same as load_data).
        self.cover_queue = List[String]()

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

    def _decode_cover(
        mut self, rating_key: String, image_data: List[UInt8]
    ) raises:
        """Decode thumbnail bytes and cache the RGBA pixels for blitting."""
        if image_data.byte_length() == 0:
            return

        var decoded = imdecode(image_data)
        var n = decoded.width * decoded.height * 4
        var layout = Layout[UInt8](count=n)
        self.cover_pixels[rating_key] = Optional[
            Pointer[UInt8, MutUntrackedOrigin]
        ](alloc(layout).unsafe_leak())
        for i in range(n):
            self.cover_pixels[rating_key].value()[
                unsafe_offset=i
            ] = decoded.pixels[i]
        self.cover_sizes[rating_key] = decoded.width * 1000000 + decoded.height

    def _fetch_next_cover(mut self, app_state: PlexSession) raises:
        """Fetch ONE queued cover per call (blocking HTTP).

        Called from draw() AFTER the frame's rows are drawn, so a slow
        thumbnail never delays rendering — it just appears on a later
        frame. Queue is rebuilt each frame from currently-visible rows.
        """
        # Skip entries already fetched; drop them from the queue.
        while len(self.cover_queue) > 0:
            var rating_key = self.cover_queue[0]
            if rating_key in self.covers_done:
                _ = self.cover_queue.pop(0)
                continue
            break

        if len(self.cover_queue) == 0:
            return

        var rating_key = self.cover_queue[0]
        _ = self.cover_queue.pop(0)
        self.covers_done[rating_key] = True  # only attempt each cover once

        # Find the book for this rating_key to get its thumb path.
        var thumb_path = ""
        for i in range(len(self.books)):
            if self.books[i].rating_key == rating_key:
                thumb_path = self.books[i].thumb
                break
        if thumb_path.byte_length() == 0:
            return

        var token = app_state.server_token
        if token.byte_length() == 0:
            token = app_state.account_token

        var thumb_url = get_thumbnail_url(
            app_state.server_url, thumb_path, token, 160, 160
        )
        if thumb_url.byte_length() == 0:
            return

        # Disk cache first: covers persist across sessions, so a book seen
        # before renders instantly without touching the network.
        var image_data = load_cached_cover(rating_key, 160, 160)
        if image_data.byte_length() == 0:
            image_data = fetch_thumbnail(thumb_url)
            save_cached_cover(rating_key, 160, 160, image_data)

        self._decode_cover(rating_key, image_data)

    def handle_keyboard(mut self, mut ui: UIContext, ascii: AsciiTable):
        """Route keyboard input to the search bar when it has focus.

        Called from main.mojo every frame while the library screen is active.
        Only consumes input when the search bar is focused (so ESC still works
        for screen navigation, handled in main.mojo).
        """
        if not self.search_input.is_focused:
            return

        # One character press per frame (libinput state model).
        var cp = ui.char_pressed()
        if cp != 0:
            self.search_input.handle_char(Int(cp), ascii)

        if ui.key_pressed(KEY_BACKSPACE):
            self.search_input.handle_backspace()
        elif ui.key_pressed(KEY_DELETE):
            self.search_input.handle_delete()

    def handle_scroll(mut self, wheel_delta: Float32, screen_h: Int):
        """Handle mouse wheel scrolling."""
        if len(self.books) == 0:
            return

        # Design-pixel row layout (must match draw)
        var header_h = 115.0  # header + search bar + status
        var row_h = 176.0
        var row_gap = 20.0
        var total_height = (
            Float64(len(self.books)) * (row_h + row_gap) - row_gap
        )
        var visible_height = Float64(screen_h) - header_h - 30.0

        if total_height <= visible_height:
            self.scroll_offset = 0.0
            return

        self.scroll_offset += wheel_delta * 40.0
        var max_scroll = Float32(total_height - visible_height - 100)
        if self.scroll_offset < 0.0:
            self.scroll_offset = 0.0
        elif self.scroll_offset > max_scroll:
            self.scroll_offset = max_scroll

    def draw(
        mut self,
        mut ui: UIContext,
        mut app_state: PlexSession,
        mut screen: Screen,
        mut player: PlayerScreen,
    ) raises:
        """Render the entire library screen (immediate-mode)."""
        var sw_design = Float64(ui.screen_w) / Float64(ui.ui_scale)
        var sh_design = Float64(ui.screen_h) / Float64(ui.ui_scale)

        # --- Header bar ---
        var header_h = 60.0
        ui.panel_bg(0.0, 0.0, sw_design, header_h, LIBRARY_BG)

        # Library title (centered)
        ui.move_to(0.0, 16.0)
        ui.label_centered(self.library_name, 22, GREEN)

        # Settings button (right side)
        var settings_w = sw_design * 0.12
        var btn_h = 36.0
        var settings_result = ui.button_at(
            ICON_SETTINGS,
            sw_design - settings_w - 20.0,
            7.0,
            settings_w,
            btn_h,
            BTN_DARK_LIB,
            TEXT_LIGHT,
            Color(55, 64, 80, 255),
        )
        if settings_result.clicked:
            screen.current = 4  # Settings screen
            return

        # --- Search bar ---
        # Placed below the header. Bounds in screen px (matches mouse_pos).
        var search_y = header_h + 14.0
        var search_h = 60.0
        var search_w = sw_design * 0.6
        var search_x = (sw_design - search_w) / 2.0
        var search_bounds = ui.rect(search_x, search_y, search_w, search_h)
        # Update the TextInput bounds each frame to track DPI/resize.
        self.search_input.bounds = search_bounds
        # Click focus handling: consume the click so card buttons underneath
        # don't also fire on the same press.
        if ui.mouse_pressed:
            self.search_input.handle_click(ui.mouse_pos)
            # If the click landed inside the search bar, consume it via the
            # UIContext guard so subsequent buttons don't also fire.
            if ui._hit(search_bounds):
                ui.item_clicked = True
        # Draw the search input (font size 16, design px).
        self.search_input.draw(ui, 16, ui.dt)

        # --- Status + pagination line ---
        var status_y = search_y + search_h + 4.0
        var page_count = self._page_count()

        # PREV button (left of status) — disabled on first page.
        var prev_w = 70.0
        if self.page > 0:
            var prev_result = ui.button_at(
                "PREV",
                20.0,
                status_y - 2.0,
                prev_w,
                22.0,
                BTN_DARK_LIB,
                TEXT_LIGHT,
                Color(55, 64, 80, 255),
            )
            if prev_result.clicked:
                self.prev_page_requested = True
        else:
            # Dim disabled PREV for visual consistency.
            _ = ui.button_at(
                "PREV",
                20.0,
                status_y - 2.0,
                prev_w,
                22.0,
                CARD_BG,
                TEXT_MUTED,
                CARD_BG,
            )

        # Status message (center).
        if self.status_message.byte_length() > 0:
            ui.move_to(20.0 + prev_w + 12.0, status_y)
            ui.label(self.status_message, 16, self.status_color)

        # NEXT button (right) — disabled on last page.
        var next_w = 70.0
        var next_x = sw_design - 20.0 - next_w
        if self.page + 1 < page_count and len(self.books) > 0:
            var next_result = ui.button_at(
                "NEXT",
                next_x,
                status_y - 2.0,
                next_w,
                22.0,
                BTN_DARK_LIB,
                TEXT_LIGHT,
                Color(55, 64, 80, 255),
            )
            if next_result.clicked:
                self.next_page_requested = True
        else:
            _ = ui.button_at(
                "NEXT",
                next_x,
                status_y - 2.0,
                next_w,
                22.0,
                CARD_BG,
                TEXT_MUTED,
                CARD_BG,
            )

        # --- Request a server-side search when the query changes ---
        # draw() can't run the network call (blocks the render loop); set a
        # flag for main.mojo to consume. Debounce: only request when the
        # query differs from the active search (avoids re-fetching the same
        # query every frame).
        if self.search_input.text != self.active_search:
            if not self.search_query_requested:
                self.search_query_requested = True
                self.pending_search_query = self.search_input.text

        # --- Scrollable book list (compact Plex-style rows) ---
        # Reserve the bottom strip for the now-playing bar when a book is
        # loaded (matches the bar height below).
        var bar_h = 64.0
        var has_now_playing = player.book_title.byte_length() > 0
        var list_bottom = sh_design - 10.0
        if has_now_playing:
            list_bottom = sh_design - bar_h - 6.0
        var list_top = status_y + 26.0
        var list_height = list_bottom - list_top

        ui.begin_clip(0.0, list_top, sw_design, list_height)

        var row_pad = 20.0
        var row_gap = 16.0
        var row_h = 176.0
        var inner_pad = 16.0

        # scroll_offset is in screen px; convert to design px
        var scroll_design = Float64(self.scroll_offset) / Float64(ui.ui_scale)
        var list_y_design = list_top - scroll_design

        # `books` holds either the current page or the search results.
        for i in range(len(self.books)):
            var row_y = list_y_design + Float64(i) * (row_h + row_gap)
            var book = self.books[i]

            if row_y + row_h < list_top:
                continue
            if row_y > list_bottom:
                break

            # Queue this row's cover for lazy fetch (attempt-once, dedup by
            # covers_done inside _fetch_next_cover). Linear scan is fine:
            # the queue only ever holds the visible window's keys.
            var already_queued = False
            for queued_key in self.cover_queue:
                if queued_key == book.rating_key:
                    already_queued = True
                    break
            if not already_queued:
                self.cover_queue.append(book.rating_key)

            # Row background: transparent by default (the screen gradient
            # shows through); card drawn only on hover. Canvas has no alpha
            # compositing, so "transparent" = don't paint.
            var row_w = sw_design - row_pad * 4.0
            var row_rect = ui.rect(row_pad, row_y, row_w, row_h)
            var row_hover = ui._hit(row_rect)
            if row_hover:
                ui.card(
                    row_pad, row_y, row_w, row_h, SELECTED_BG, roundness=0.06
                )

            # --- Square cover (left) ---
            var cover_size = row_h - inner_pad * 2.0
            var cover_x = row_pad + inner_pad
            var cover_y = row_y + inner_pad

            # Cached cover blit (if decoded); placeholder card otherwise.
            var has_cover = False
            if book.rating_key in self.cover_pixels:
                var cover_opt = self.cover_pixels[book.rating_key]
                if cover_opt:  # Optional truthiness: Some + non-null pointer
                    var pixels = cover_opt.value()
                    var packed = self.cover_sizes[book.rating_key]
                    var src_w = packed // 1000000
                    var src_h = packed % 1000000
                    # canvas is screen-px: scale design coords up.
                    var s = Float64(ui.ui_scale)
                    ui.canvas[unsafe_offset=0].blit_rgba(
                        pixels,
                        src_w,
                        src_h,
                        src_w * 4,
                        cover_x * s,
                        cover_y * s,
                        cover_size * s,
                        cover_size * s,
                    )
                    has_cover = True
            if not has_cover:
                ui.card(
                    cover_x,
                    cover_y,
                    cover_size,
                    cover_size,
                    PLACEHOLDER_BG,
                    roundness=0.06,
                )

            # Book info (right of cover) — vertically centered in the row.
            var info_x = cover_x + cover_size + 14.0
            var info_w = row_w - cover_size - inner_pad * 2.0 - 14.0
            var title_y = row_y + (row_h - 66.0) / 2.0

            # Title (truncated if too long)
            var title_text = book.title
            var title_meas = ui._measure_text(title_text, 16)
            if title_meas.x > Float32(info_w) * ui.font_scale:
                var max_chars = Int(info_w / 9.0)
                if max_chars > 3:
                    title_text = (
                        truncate_string(title_text, max_chars - 3) + "..."
                    )
                else:
                    title_text = truncate_string(title_text, max_chars)
            else:
                title_text = title_text

            ui.move_to(info_x, title_y)
            ui.label(title_text, 18, TEXT_BRIGHT)

            # Author
            ui.move_to(info_x, title_y + 24.0)
            ui.label(book.author, 16, TEXT_DIM)

            # Progress line
            var progress_text = "Not Started"
            if book.duration_ms > 0:
                if (
                    book.viewed_leaf_count == book.leaf_count
                    and book.leaf_count > 0
                ):
                    progress_text = "Finished"
                elif book.view_offset_ms > 0:
                    var pct = (
                        Float64(book.view_offset_ms)
                        / Float64(book.duration_ms)
                        * 100.0
                    )
                    var pct_str = String(Int(pct))
                    progress_text = (
                        pct_str
                        + "% "
                        + format_time(Float64(book.view_offset_ms) / 1000.0)
                    )
                else:
                    progress_text = format_time(
                        Float64(book.duration_ms) / 1000.0
                    )

            ui.move_to(info_x, title_y + 46.0)
            ui.label(progress_text, 14, GREEN)

            # --- Row actions (right side): SAVE + PLAY ---
            var play_w = 56.0
            var play_h = 34.0
            var save_w = 56.0
            var save_gap = 10.0
            var play_x = row_pad + row_w - inner_pad - play_w
            var play_y = row_y + (row_h - play_h) / 2.0
            var save_x = play_x - save_gap - save_w

            var save_result = ui.button_at(
                "SAVE",
                save_x,
                play_y,
                save_w,
                play_h,
                DOWNLOAD_BLUE,
                TEXT_LIGHT,
                SELECTED_BG,
            )
            if save_result.clicked:
                self.download_requested = True
                self.download_book_index = i
                ui.item_clicked = True
                ui.end_clip()
                return

            var play_result = ui.button_at(
                ICON_PLAY,
                play_x,
                play_y,
                play_w,
                play_h,
                GREEN,
                ACCENT_DARK,
                SELECTED_BG,
            )
            if play_result.clicked:
                self.play_requested = True
                # `books` holds either the page or search results; direct.
                self.play_book_index = i
                screen.current = 2
                ui.item_clicked = True
                ui.end_clip()
                return

            # Full-row click target: clicking anywhere else on a row plays
            # it. Checked AFTER the PLAY button so the button wins when both
            # contain the press; _clicked() consumes via item_clicked.
            if ui._clicked(row_rect):
                self.play_requested = True
                # `books` holds either the page or search results; direct.
                self.play_book_index = i
                screen.current = 2
                ui.item_clicked = True
                ui.end_clip()
                return

        ui.end_clip()

        # Lazy cover fetch: one blocking HTTP fetch per frame, after the
        # screen has rendered, so the UI stays responsive.
        self._fetch_next_cover(app_state)

        # ------------------------------------------------------------------
        # Now-playing bar (bottom of screen)
        # ------------------------------------------------------------------
        if not has_now_playing:
            return

        var bar_y = sh_design - bar_h
        ui.panel_bg(0, bar_y, sw_design, bar_h, PLAYER_INFO_BG)

        # Accent progress line along the bar's top edge.
        if player.duration > 0.0:
            var frac = player.current_time / player.duration
            if frac < 0.0:
                frac = 0.0
            if frac > 1.0:
                frac = 1.0
            ui.panel_bg(0, bar_y, sw_design * frac, 3.0, SLIDER_FILL)

        # Title + author (left, after cover thumb).
        var np_cover_x = row_pad + inner_pad
        var np_cover_size = bar_h - 16.0
        ui.card(
            np_cover_x,
            bar_y + 8.0,
            np_cover_size,
            np_cover_size,
            PLACEHOLDER_BG,
            roundness=0.06,
        )
        var np_text_x = np_cover_x + np_cover_size + 14.0
        var np_text_w = sw_design - np_text_x - 260.0
        var np_title = player.book_title
        var np_meas = ui._measure_text(np_title, 16)
        if np_meas.x > Float32(np_text_w) * ui.font_scale:
            var max_chars = Int(np_text_w / 9.0)
            if max_chars > 3:
                np_title = truncate_string(np_title, max_chars - 3) + "..."
            else:
                np_title = truncate_string(np_title, max_chars)
        ui.move_to(np_text_x, bar_y + 14.0)
        ui.label(np_title, 16, TEXT_BRIGHT)
        ui.move_to(np_text_x, bar_y + 36.0)
        ui.label(player.book_author, 14, TEXT_DIM)

        # Time display (right of text).
        var np_time_x = sw_design - 250.0
        ui.move_to(np_time_x, bar_y + 24.0)
        ui.label(
            format_time(player.current_time)
            + " / "
            + format_time(player.duration),
            14,
            TEXT_LIGHT,
        )

        # Play/pause toggle (far right).
        var np_btn_w = 90.0
        var np_btn_h = 34.0
        var np_btn = ui.button_at(
            ICON_PAUSE if player.is_playing else ICON_PLAY,
            sw_design - row_pad - np_btn_w,
            bar_y + (bar_h - np_btn_h) / 2.0,
            np_btn_w,
            np_btn_h,
            GREEN,
            ACCENT_DARK,
            SELECTED_BG,
        )
        if np_btn.clicked:
            player.toggle_playback()
