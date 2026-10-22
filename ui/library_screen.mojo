from resources.color import Color
from std.collections import Dict, Optional
from std.memory import alloc, Layout, unsafe_memcpy
from std.memory.unsafe_pointer import Pointer
from std.os import path
from std.pathlib import Path
from std.time import perf_counter

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
    get_audio_cache_dir,
    probe_server,
    report_progress,
    mark_watched,
)
from render.imui import UIContext, UIResult, Vec2, Rect
from resources.imdecode import imdecode
from resources.keys import (
    KEY_BACKSPACE,
    KEY_TAB,
    KEY_ENTER,
    KEY_DELETE,
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
from resources.plex_objects import (
    PlexTrack,
    PlexChapter,
    LibraryItem,
    ServerItem,
)
from resources.offline_library import (
    load_saved_books,
    search_saved_books,
)
from ui.widgets import TextInput, Button, Checkbox, PlexBookCard
from ui.font import FontSet
from ui import Screen
from ui.icons import ICON_PLAY, ICON_PAUSE, ICON_SETTINGS
from ui.player_screen import PlayerScreen


# Touch drag-to-scroll: movement below this (screen px) is a tap, at or
# above it is a scroll drag.
comptime TAP_SLOP_PX = 12.0

# Search debounce: the server-side search fires once the query has sat
# idle this long since the last keystroke (Enter clears the wait). 350ms
# keeps mid-word results from thrashing the server on every keystroke
# while staying under a natural pause.
comptime SEARCH_DEBOUNCE_S = 0.35

# Known-offline re-probe window: load_data calls are explicit user
# actions (login, page turn, search clear), but the reachability probe
# they trigger is allowed at most once per this many seconds since the
# last failed probe/fetch — an offline session never re-burns HTTP
# timeouts on every page turn.
comptime OFFLINE_REPROBE_S = 30.0


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
    # Delete request (DELETE button shown in place of SAVE for downloaded
    # books). Consumed by main.mojo outside the render loop: removes the
    # sidecar + cached audio files from disk.
    var delete_requested: Bool
    var delete_book_index: Int

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
    # search_query_requested + pending_search_query after an idle window
    # (typed characters re-arm the wait, Enter or focus loss ships it
    # early); main.mojo consumes the flag and calls run_search() (outside
    # the render loop so the network call doesn't block mid-draw).
    # `active_search` is the query currently reflected in `books`
    # (empty = normal paginated view).
    var search_input: TextInput
    var active_search: String  # query reflected in `books` ("" = page mode)
    var search_query_requested: Bool
    var pending_search_query: String
    # Idle since the last keystroke while the bar's text differs from the
    # last executed query (re-armed by every keystroke; the trigger is in
    # draw() because it must also fire on focus loss).
    var search_idle_timer: Float64

    # One-time sidecar backfill request: draw() raises this when it loads a
    # library; main.mojo runs sync_saved_sidecars() (network) then reloads.
    # Reset after a successful sync so it never loops.
    var sync_requested: Bool
    var sync_done: Bool

    # Touch drag-to-scroll. While a touch is down inside the list, the row
    # it started on is STAGED (not activated): dragging scrolls and cancels
    # the staging, releasing without dragging activates it. Mouse presses
    # are untouched (press-edge activation as before).
    var touch_scroll_active: Bool
    var touch_last_y: Float64  # previous frame's touch y (screen px)
    var touch_row_index: Int  # row staged by the press, -1 = none
    var touch_moved: Bool  # drag exceeded the tap threshold
    # Row index delivered by the most recent tap (valid one frame).
    var touch_tap_index: Int

    # Lazy per-book cover cache, keyed by rating_key. Loaded AFTER the rest
    # of the screen renders: draw() queues visible rows, and one queued
    # cover is fetched per frame (a blocking HTTP call) so the UI never
    # stalls on thumbnails. `covers_loaded` marks exhausted rows.
    var cover_pixels: Dict[String, Optional[Pointer[UInt8, MutUntrackedOrigin]]]
    var cover_sizes: Dict[String, Int]
    var cover_queue: List[String]  # rating_keys pending fetch
    var covers_done: Dict[String, Bool]  # rating_key -> fetched (or failed)
    # Memoized download probe (rating_key -> has cached audio file). Filled
    # lazily by _is_downloaded; recomputed from scratch per book-list load
    # is enough — a SAVE completed this session shows its badge on reload.
    var downloaded_cache: Dict[String, Bool]

    # Downloads pinned to the head of every page/search (from sidecars,
    # newest first). Refreshed by load_data; consumed by the sort pass.
    var pinned_books: List[PlexBookCard]

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
        self.delete_requested = False
        self.delete_book_index = -1
        self.touch_scroll_active = False
        self.touch_last_y = 0.0
        self.touch_row_index = -1
        self.touch_moved = False
        self.touch_tap_index = -1

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
        self.downloaded_cache = Dict[String, Bool]()
        self.pinned_books = List[PlexBookCard]()

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
        self.search_idle_timer = 0.0
        self.sync_requested = False
        self.sync_done = False

    def load_data(mut self, mut app_state: PlexSession) raises:
        """Fetch audiobooks from Plex and populate the book list.

        Offline-first: saved sidecars (downloads) are loaded BEFORE the
        server fetch. With no token/library/server they ARE the library —
        fully offline. Online they get merged into the hoist sort below the
        server page (a downloaded book shows in whatever page holds it, and
        sidecars only surface as standalone rows when the server is
        unreachable).

        Known-offline precedence (app_state.offline): the server fetch is
        skipped and the sidecar store renders immediately, subject to the
        re-probe window in _offline_probe_ok — a successful re-probe clears
        the flag and resumes the normal fetch path (server wins again).

        Uses the current page/page_size for server-side pagination via Plex's
        X-Plex-Container-Start/Size headers. Stores total_size for page count.
        Resets the search filter.
        """
        self.status_message = "Loading page " + String(self.page + 1) + "..."
        self.status_color = TEXT_DIM

        # --- Offline seed: sidecars drive pinned rows + offline fallback ---
        # `pinned_books` = every sidecar'd download, newest first. They're
        # pinned onto the head of whatever page/search loads next
        # (see _sort_books_for_display); with no server they ARE the list
        # via offline_books below.
        var saved = load_saved_books()
        var offline_books = List[PlexBookCard]()
        self.pinned_books = List[PlexBookCard]()
        for i in range(len(saved)):
            ref meta = saved[i]
            var card = meta.to_card()
            offline_books.append(card)
            self.pinned_books.append(card)
            # Sidecar rows are known-downloaded; memoize so badges and the
            # sort pass need no filesystem probe this session.
            self.downloaded_cache[meta.rating_key] = True

        # --- Known-offline short-circuit (see docstring precedence) ---
        # A failed (window-throttled) probe renders the sidecar library;
        # a successful probe cleared the flag and falls through to fetch.
        if app_state.offline and not self._offline_probe_ok(app_state):
            # The restored config knows the library name even offline.
            if app_state.library_name.byte_length() > 0:
                self.library_name = app_state.library_name
            self._show_offline_list(offline_books^)
            return

        var token = app_state.server_token
        if token.byte_length() == 0:
            token = app_state.account_token

        # Guard: no token available — offline mode.
        if token.byte_length() == 0:
            self.books = offline_books^
            self.total_size = len(self.books)
            var n = String(len(self.books))
            if len(self.books) > 0:
                self.status_message = (
                    "Offline — showing " + n + " downloaded books"
                )
                self.status_color = TEXT_DIM
            else:
                self.status_message = "Not authenticated"
                self.status_color = ERROR_COLOR
            self.scroll_offset = 0.0
            self.active_search = ""
            self.cover_queue = List[String]()
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
                # The server answered but errored: offline rows are better
                # than an empty page.
                if len(offline_books) > 0:
                    self.books = offline_books^
                    self.total_size = len(self.books)
                    self.scroll_offset = 0.0
                    self.active_search = ""
            else:
                # Server answered — reachable again: clear the offline
                # state before anything else reads it this session.
                app_state.offline = False

                # Server online — request the one-time sidecar backfill
                if not self.sync_done:
                    self.sync_requested = True

                # COW transfer: List.copy() is shallow copy-on-write, so the
                # 25 cards share storage with result.items until either side
                # mutates — no per-card copy loop.
                self.books = result.items.copy()

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
            # Server unreachable (no network, wrong URL, down): degrade to
            # the offline library instead of an error page, and flag the
            # session so later loads skip the doomed fetch entirely.
            print("[Quire] library fetch failed, using offline: " + String(e))
            app_state.mark_offline()
            self._show_offline_list(offline_books^)
            return

        # Hoist in-progress + downloaded books to the top of the list.
        self._sort_books_for_display()

        # New book list: drop stale cover cache entries so keys are
        # re-queued for visible rows on the next frames.
        self.cover_queue = List[String]()

        self.data_loaded = True

    def _show_offline_list(mut self, var books: List[PlexBookCard]) raises:
        """Render the sidecar library as the (offline) book list.

        Shared shape of the two failure paths above (no-token, fetch
        failed) — sidecars when there are any, a short status line when
        not. Consumes `books` (the caller's list moves here)."""
        self.books = books^
        self.total_size = len(self.books)
        if len(self.books) > 0:
            self.status_message = (
                "Offline — showing "
                + String(len(self.books))
                + " downloaded books"
            )
            self.status_color = TEXT_DIM
        else:
            self.status_message = "Offline — no downloaded books"
            self.status_color = TEXT_DIM
        self.scroll_offset = 0.0
        self.active_search = ""
        self.cover_queue = List[String]()
        self.data_loaded = True

    def _offline_probe_ok(mut self, mut app_state: PlexSession) -> Bool:
        """One throttled reachability probe for the known-offline state.

        Policy: a load_data call is a user action, but probing is allowed
        at most once per OFFLINE_REPROBE_S since the last failed probe or
        fetch (app_state.last_offline_probe_s) — inside that window the
        answer is False without any I/O. Outside it, one short-timeout
        probe runs: success clears the offline state and returns True
        (the caller falls through to the real fetch); failure re-arms the
        window and returns False."""
        var now = perf_counter()
        if now - app_state.last_offline_probe_s < OFFLINE_REPROBE_S:
            return False
        app_state.last_offline_probe_s = now

        var token = app_state.server_token
        if token.byte_length() == 0:
            token = app_state.account_token
        var probe = probe_server(
            app_state.server_url, token, app_state.client_id
        )
        if probe.ok:
            # Any successful server operation clears the offline flag.
            app_state.offline = False
            return True
        return False

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

    def _is_downloaded(mut self, rating_key: String) raises -> Bool:
        """True if the book's first track is cached in the audio directory.

        Mirrors the player's source-resolution probe (same extension set):
        a cached file means offline playback works. Results are memoized
        per rating_key (dict hit = no filesystem stats) because draw() calls
        this per visible row every frame."""
        if rating_key in self.downloaded_cache:
            return self.downloaded_cache[rating_key]

        var extensions = List[String]()
        extensions.append("mp3")
        extensions.append("ogg")
        extensions.append("wav")
        extensions.append("m4b")
        extensions.append("m4a")
        extensions.append("aac")
        extensions.append("flac")

        var cache_dir = get_audio_cache_dir()
        var found = False
        for i in range(len(extensions)):
            var candidate = cache_dir + "/" + rating_key + "." + extensions[i]
            if path.exists(Path(candidate)):
                found = True
                break
        self.downloaded_cache[rating_key] = found
        return found

    def _sort_books_for_display(mut self) raises:
        """Pin downloaded + in-progress books to the top of the list.

        Two parts:
        1. PIN — sidecar'd downloads (load_saved_books, newest first) are
           merged onto the head of ANY loaded page/search, deduped against
           rows already present, and removed from their old positions. So
           your downloads are always the first items regardless of which
           page Plex paginated them onto.
        2. HOIST — in-progress books already on this page rise above the
           remaining server rows (last-listened proxy: viewOffset is the
           only listen-state the listing exposes).

        Runs after load_data/run_search land a fresh `books` list.
        """
        if len(self.books) == 0 and len(self.pinned_books) == 0:
            return

        # --- Pass 1: pin sidecar'd downloads to the head ---
        # Dedup: a book both pinned and on this page keeps ONE copy (the
        # pinned one, which carries fresher offline progress).
        var seen = List[String]()
        var pinned_head = List[PlexBookCard]()
        for i in range(len(self.pinned_books)):
            var pinned = self.pinned_books[i]
            seen.append(pinned.rating_key)
            pinned_head.append(pinned)

        var rows = List[PlexBookCard]()
        for i in range(len(self.books)):
            var book = self.books[i]
            var duplicate = False
            for j in range(len(seen)):
                if seen[j] == book.rating_key:
                    duplicate = True
                    break
            if not duplicate:
                rows.append(book)

        # --- Pass 2: hoist in-progress rows within the page remainder ---
        var in_progress = List[PlexBookCard]()
        var rest = List[PlexBookCard]()
        for i in range(len(rows)):
            var book = rows[i]
            if book.view_offset_ms > 0 and (
                book.viewed_leaf_count < book.leaf_count or book.leaf_count == 0
            ):
                in_progress.append(book)
            else:
                rest.append(book)

        var hoisted = List[PlexBookCard]()
        for i in range(len(pinned_head)):
            hoisted.append(pinned_head[i])
        for i in range(len(in_progress)):
            hoisted.append(in_progress[i])
        for i in range(len(rest)):
            hoisted.append(rest[i])
        self.books = hoisted^

    def run_search(mut self, mut app_state: PlexSession, query: String) raises:
        """Fetch server-side search results for `query` and replace `books`.

        Called from main.mojo when draw() sets search_query_requested. An
        empty query clears the search and reloads the current page.

        Offline precedence: a known-offline session (app_state.offline)
        skips the server round-trip and searches the sidecar store
        directly (_search_downloaded); an unreachable server (exception)
        flags the session offline and falls back to the same filter. A
        reachable server that answers but errors keeps the existing
        error status (it is reachable — only the filter failed). A
        successful server search clears the offline flag — online results
        always win when reachable. The client-side match semantics mirror
        the server path's author fallback (case-insensitive substrings on
        title + author).
        """
        if query.byte_length() == 0:
            self.active_search = ""
            self.load_data(app_state)
            return

        self.status_message = 'Searching "' + query + '"...'
        self.status_color = TEXT_DIM

        # Known-offline: no doomed server round-trip, filter sidecars.
        if app_state.offline:
            self._search_downloaded(query)
            return

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
            # Server answered — reachable again: clear the offline state.
            app_state.offline = False
            self.books = result.items.copy()
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
            # Server unreachable mid-session: flag it so the next loads
            # skip the doomed fetch, and surface sidecar matches instead.
            print("[Quire] search failed, using offline: " + String(e))
            app_state.mark_offline()
            self._search_downloaded(query)
            return

        # Search results use the same hoist ordering as the page view.
        self._sort_books_for_display()

        # New book list: drop stale cover queue (same as load_data).
        self.cover_queue = List[String]()

    def _search_downloaded(mut self, query: String) raises:
        """Offline search fallback: client-side filter over the sidecar
        store (search_saved_books, newest-saved order preserved).

        Replaces `books` with the matches and keeps the file's status-line
        wording; an offline result set has no server pagination, so
        total_size pins to the match count (one page)."""
        var matches = search_saved_books(query)
        self.books = matches^
        self.total_size = len(self.books)
        self.active_search = query
        self.scroll_offset = 0.0
        if len(self.books) > 0:
            self.status_message = (
                "Offline — showing "
                + String(len(self.books))
                + " matches from downloaded books"
            )
            self.status_color = TEXT_DIM
        else:
            self.status_message = "Offline — no downloads match"
            self.status_color = TEXT_DIM

        # Search results use the same hoist ordering as the page view.
        self._sort_books_for_display()

        # New book list: drop stale cover queue (same as load_data).
        self.cover_queue = List[String]()

    def _decode_cover(
        mut self, rating_key: String, var image_data: List[UInt8]
    ) raises:
        """Decode thumbnail bytes and cache the RGBA pixels for blitting.

        Consumes `image_data` (the caller moves its fetch temp with `^` —
        the compressed buffer is never duplicated).
        """
        if image_data.byte_length() == 0:
            return

        var decoded = imdecode(image_data^)
        var n = decoded.width * decoded.height * 4
        var layout = Layout[UInt8](count=n)
        var dst = alloc(layout).unsafe_leak()
        # Bulk-copy the decoded RGBA buffer (one memcpy, not n byte stores).
        unsafe_memcpy(
            dest=Pointer[UInt8, MutUntrackedOrigin](
                unsafe_from_address=Int(dst)
            ),
            src=Pointer[UInt8, MutUntrackedOrigin](
                unsafe_from_address=Int(decoded.pixels.unsafe_ptr())
            ),
            count=n,
        )
        self.cover_pixels[rating_key] = Optional[
            Pointer[UInt8, MutUntrackedOrigin]
        ](Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(dst)))
        self.cover_sizes[rating_key] = decoded.width * 1000000 + decoded.height

    def _fetch_next_cover(
        mut self, app_state: PlexSession, player: PlayerScreen
    ) raises:
        """Fetch ONE queued cover per call (blocking HTTP).

        Called from main.mojo AFTER win.present(), so a slow thumbnail
        delays the next frame's input processing, never the presentation
        of the frame that just rendered. Queue is rebuilt each frame from
        currently-visible rows; the now-playing bar queues the playing
        book even when its row is off-page, resolved via player.book_thumb.
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

        # Find the book for this rating_key to get its thumb path. The
        # playing book is resolved from the player (works when paged away).
        var thumb_path = ""
        if rating_key == player.book_id:
            thumb_path = player.book_thumb
        else:
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
        # before renders instantly without touching the network. While the
        # session is known-offline the HTTP fetch is skipped (local cache
        # or placeholder) — the attempt-once covers_done bookkeeping below
        # is unchanged, so a cover missed offline can still be fetched on
        # a later online reload (same as a plain cache miss).
        var image_data = load_cached_cover(rating_key, 160, 160)
        if image_data.byte_length() == 0 and not app_state.offline:
            image_data = fetch_thumbnail(thumb_url)
            save_cached_cover(rating_key, 160, 160, image_data)

        # Move the fetch temp into the decoder — the compressed buffer is
        # never copied (imdecode takes ownership and the format decoders
        # consume it by move).
        self._decode_cover(rating_key, image_data^)

    def handle_keyboard(mut self, mut ui: UIContext, ascii: AsciiTable):
        """Route keyboard input to the search bar when it has focus.

        Called from main.mojo every frame while the library screen is
        active. Only consumes input when the search bar is focused (so
        ESC still works for screen navigation, handled in main.mojo).
        Each keystroke re-arms the search debounce.
        """
        if not self.search_input.is_focused:
            return

        # Drain EVERY printable press queued this frame — the key-event
        # ring queues all of them, so a burst typed across a slow frame
        # arrives intact instead of collapsing to its last key (the old
        # single-slot model dropped them, one char per frame). Ordering
        # across the frame is preserved between chars; a backspace is
        # applied after same-frame chars (rare: a char+backspace inside
        # one ~30ms frame nets one deleted char — the single-slot model
        # netted arbitrary survivors).
        var cp = ui.char_pressed()
        while cp != 0:
            self.search_input.handle_char(Int(cp), ascii)
            self.search_idle_timer = 0.0  # typing re-arms the debounce
            cp = ui.char_pressed()

        if ui.key_pressed(KEY_BACKSPACE):
            self.search_input.handle_backspace()
            self.search_idle_timer = 0.0

        # Enter is the escape hatch: fire the pending query immediately,
        # without waiting out the idle window (also ships a fresh edit
        # made after the last query already completed — text still
        # differs from active_search). GLFW: KEY_ENTER/KEY_RETURN share
        # code 257, matching the keybind capture path.
        if ui.key_pressed(KEY_ENTER):
            if self.search_input.text != self.active_search:
                self.search_query_requested = True
                self.pending_search_query = self.search_input.text
            self.search_idle_timer = 0.0

    def clear_teardown(mut self):
        """Drop big container state before scope exit (see main() teardown).

        The book/cover dicts hold the only strong references to decoded
        cover pixel buffers; emptying them here frees those allocations on
        this side so the implicit deinits never release shared storage
        twice. Must be idempotent-safe at exit — there is no draw after."""
        self.books = List[PlexBookCard]()
        self.pinned_books = List[PlexBookCard]()
        self.downloaded_cache = Dict[String, Bool]()
        self.covers_done = Dict[String, Bool]()
        self.cover_queue = List[String]()
        self.cover_pixels = Dict[
            String, Optional[Pointer[UInt8, MutUntrackedOrigin]]
        ]()
        self.cover_sizes = Dict[String, Int]()

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
        var max_scroll = Float32(total_height - visible_height - 300)
        if self.scroll_offset < 0.0:
            self.scroll_offset = 0.0
        elif self.scroll_offset > max_scroll:
            self.scroll_offset = max_scroll

    def _touch_in_list(
        self, ui: UIContext, list_top: Float64, list_bottom: Float64
    ) -> Bool:
        """True if the active press point is inside the scrollable list."""
        var mouse_y = Float64(ui.mouse_pos.y)
        return mouse_y >= list_top and mouse_y < list_bottom

    def _handle_touch_scroll(
        mut self,
        mut ui: UIContext,
        list_top: Float64,
        list_bottom: Float64,
        max_scroll: Float32,
        row_hit: Int,
    ) -> Bool:
        """One touch-drag scroll step; returns True if a tap should fire.

        Touch lifecycle mapped to scroll:
          press   → stage `row_hit` (touch_row_index), begin tracking
          motion  → scroll by the drag delta (1:1 finger travel); movement
                    past TAP_SLOP_PX cancels the staged row
          release → no drag = tap → True (caller activates the staged row)

        Mouse input passes straight through (returns False; mouse clicks
        keep their own press-edge path). Keys off ui.press_is_touch.
        """
        if not ui.mouse_down:
            # Release: a still-staged row that never dragged = tap.
            var was_tap = (
                self.touch_scroll_active
                and not self.touch_moved
                and self.touch_row_index >= 0
            )
            if was_tap:
                self.touch_tap_index = self.touch_row_index
            self.touch_scroll_active = False
            self.touch_row_index = -1
            self.touch_moved = False
            return was_tap

        if not ui.press_is_touch:
            return False  # mouse drag: nothing to do here

        if not self.touch_scroll_active:
            # Press starts tracking (only inside the scrollable region).
            if not self._touch_in_list(ui, list_top, list_bottom):
                return False
            self.touch_scroll_active = True
            self.touch_last_y = Float64(ui.mouse_pos.y)
            self.touch_row_index = row_hit
            self.touch_moved = False
            return False

        # Active touch drag: scroll by finger delta (screen px → design px).
        var dy_screen = Float64(ui.mouse_pos.y) - self.touch_last_y
        self.touch_last_y = Float64(ui.mouse_pos.y)
        if dy_screen != 0.0:
            var dy_design = dy_screen / Float64(ui.ui_scale)
            self.scroll_offset = Float32(
                Float64(self.scroll_offset) - dy_design
            )
        var moved_px = dy_screen if dy_screen > 0.0 else -dy_screen
        if moved_px > TAP_SLOP_PX:
            self.touch_moved = True
        if self.touch_moved:
            self._clamp_scroll(max_scroll)
        return False

    def _clamp_scroll(mut self, max_scroll: Float32):
        """Keep touch-drag scroll_offset inside [0, max_scroll]."""
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
        var btn_h = 40.0
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
        var search_h = 80.0
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
        self.search_input.draw(ui, 20, ui.dt)

        # --- Status + pagination line ---
        var status_y = search_y + search_h + 4.0
        var page_count = self._page_count()

        # PREV button (left of status) — disabled on first page.
        # Fitted width: the grown rect is what's drawn AND what the status
        # label offsets from, so they stay in sync.
        var prev_w = 70.0
        var prev_fit_w = ui.fitted_button_w("PREV", 22, prev_w)
        if self.page > 0:
            var prev_result = ui.button_at(
                "PREV",
                20.0,
                status_y - 2.0,
                prev_w,
                36.0,
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
                36.0,
                CARD_BG,
                TEXT_MUTED,
                CARD_BG,
            )

        # Status message (center).
        if self.status_message.byte_length() > 0:
            ui.move_to(20.0 + prev_fit_w + 12.0, status_y)
            ui.label(self.status_message, 16, self.status_color)

        # NEXT button (right) — disabled on last page. Right-anchored with
        # the fitted width so the grown rect stays inside the right margin.
        var next_w = 70.0
        var next_fit_w = ui.fitted_button_w("NEXT", 22, next_w)
        var next_x = sw_design - 20.0 - next_fit_w
        if self.page + 1 < page_count and len(self.books) > 0:
            var next_result = ui.button_at(
                "NEXT",
                next_x,
                status_y - 2.0,
                next_w,
                36.0,
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
                36.0,
                CARD_BG,
                TEXT_MUTED,
                CARD_BG,
            )

        # --- Server-side search: debounced request to main.mojo ---
        # (draw() can't run the network call — it blocks the render loop —
        # so a flag routes the query to main.mojo. It is a REAL debounce:
        # a time-based idle window of SEARCH_DEBOUNCE_S, re-armed by every
        # keystroke in handle_keyboard, so rapid typing sends one query
        # when the keyboard goes quiet instead of one per keystroke. Enter
        # or focus loss ships the pending query immediately; the initial
        # entry into the field never arms the timer because an unchanged
        # text never differs from active_search.)
        # The pending query is captured at fire time; main consumes the
        # flag before the next frame's keystroke processing, so a query
        # can never go stale — text changed again just pushes the fire
        # timer out while `books` keeps showing the last results.
        if self.search_input.text != self.active_search:
            if not self.search_query_requested:
                self.search_idle_timer += ui.dt
                if (
                    self.search_idle_timer >= SEARCH_DEBOUNCE_S
                    or not self.search_input.is_focused
                ):
                    self.search_query_requested = True
                    self.pending_search_query = self.search_input.text
        else:
            # Query executed (or reverted): re-arm the idle window for
            # the next edit.
            self.search_idle_timer = 0.0

        # --- Scrollable book list (compact Plex-style rows) ---
        # Reserve the bottom strip for the now-playing bar when a book is
        # loaded (matches the bar height below).
        var bar_h = 128.0
        var has_now_playing = player.book_title.byte_length() > 0
        var list_bottom = sh_design - 10.0
        if has_now_playing:
            list_bottom = sh_design - bar_h - 6.0
        # Clear the pagination row (buttons end at status_y + 34) with room
        # to spare so the first card never crowds the PREV/NEXT buttons.
        var list_top = status_y + 54.0
        var list_height = list_bottom - list_top

        # Touch drag-to-scroll scroll bounds (same row metrics as below).
        var touch_row_h = 180.0
        var touch_row_gap = 16.0
        var touch_total_h = (
            Float64(len(self.books)) * (touch_row_h + touch_row_gap)
            - touch_row_gap
        )
        var touch_max_scroll = Float32(0.0)
        if touch_total_h > Float64(list_height):
            touch_max_scroll = Float32(touch_total_h - Float64(list_height))

        # Which row (if any) is under the current press point. Computed
        # before the draw loop so the touch handler can stage it.
        var row_hit = -1
        if ui.mouse_down and ui.press_is_touch:
            var hit_design_y = (
                Float64(ui.mouse_pos.y) / Float64(ui.ui_scale)
                - list_top
                + Float64(self.scroll_offset) / Float64(ui.ui_scale)
            )
            if hit_design_y >= 0.0:
                var stride = touch_row_h + touch_row_gap
                var idx = Int(hit_design_y / stride)
                if idx >= 0 and idx < len(self.books):
                    # Must be inside the row body, not the gap.
                    if hit_design_y - Float64(idx) * stride < touch_row_h:
                        row_hit = idx

        var tap_fired = self._handle_touch_scroll(
            ui, list_top, list_bottom, touch_max_scroll, row_hit
        )

        ui.begin_clip(0.0, list_top, sw_design, list_height)

        var row_pad = 20.0
        var row_gap = 16.0
        var row_h = 180.0
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
                    row_pad, row_y, row_w, row_h, SELECTED_BG, roundness=0.08
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
                    ui.canvas().blit_rgba(
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
                    roundness=0.08,
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
            ui.label(title_text, 32, TEXT_BRIGHT)

            # Author
            ui.move_to(info_x, title_y + 40.0)
            ui.label(book.author, 20, TEXT_DIM)

            # Downloaded badge (offline copy cached) + progress line.
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

            # Hoisted rows are flagged so the ordering is explainable: a
            # downloaded book shows a DOWNLOADED tag next to its progress.
            var badge_text = progress_text
            if self._is_downloaded(book.rating_key):
                badge_text = progress_text + "  ·  DOWNLOADED"

            ui.move_to(info_x, title_y + 70.0)
            ui.label(badge_text, 14, GREEN)

            # --- Row actions (right side): SAVE/DELETE + PLAY ---
            # A downloaded book swaps SAVE for DELETE (red): one click frees
            # the disk space (sidecar + audio files). Non-downloaded rows
            # keep the blue SAVE prompt.
            var downloaded = self._is_downloaded(book.rating_key)
            var action_label = "SAVE"
            var action_color = DOWNLOAD_BLUE
            if downloaded:
                action_label = "DELETE"
                action_color = LOGOUT_RED
            var play_w = 60.0
            var play_h = 60.0
            var save_w = 60.0
            var save_gap = 40.0
            # The action button auto-widens to fit its label (see
            # imui.fitted_button_w); reserve the grown width so it doesn't
            # overlap the PLAY button.
            var save_fit_w = ui.fitted_button_w(action_label, 26, save_w)
            var play_x = row_pad + row_w - inner_pad - play_w - 100
            var play_y = row_y + (row_h - play_h) / 2.0
            var save_x = play_x - save_gap - save_fit_w

            var save_result = ui.button_at(
                action_label,
                save_x,
                play_y,
                save_w,
                play_h,
                action_color,
                TEXT_LIGHT,
                SELECTED_BG,
            )
            if save_result.clicked:
                if downloaded:
                    self.delete_requested = True
                    self.delete_book_index = i
                else:
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
            # Touch presses are excluded — they stage via the touch handler
            # (drag = scroll would otherwise open a book mid-scroll) and
            # complete as taps on release.
            var row_click_allowed = not ui.press_is_touch
            if row_click_allowed and ui._clicked(row_rect):
                self.play_requested = True
                # `books` holds either the page or search results; direct.
                self.play_book_index = i
                screen.current = 2
                ui.item_clicked = True
                ui.end_clip()
                return

        ui.end_clip()

        # Touch tap (press→release without drag) on a staged row: play it.
        # Runs after end_clip so the tap can't double-fire with the
        # mouse press-edge path above (touch never reaches that branch).
        if tap_fired:
            var tap_idx = self.touch_tap_index
            self.touch_tap_index = -1
            if tap_idx >= 0 and tap_idx < len(self.books):
                self.play_requested = True
                self.play_book_index = tap_idx
                screen.current = 2
                ui.item_clicked = True
                return

        # Queue the now-playing book's cover before the draw ends: the
        # playing book may not be among the visible rows (user paged
        # away), and covers_done dedups repeat queueing. The FETCH
        # itself moved to main.mojo (after win.present()) so a slow
        # thumbnail delays the next frame, never this one's present.
        if has_now_playing:
            var np_queued = False
            for queued_key in self.cover_queue:
                if queued_key == player.book_id:
                    np_queued = True
                    break
            if not np_queued and player.book_id not in self.covers_done:
                self.cover_queue.append(player.book_id)

        # ------------------------------------------------------------------
        # Now-playing bar (bottom of screen) — 2x row height; click the bar
        # (or album art) to open the player screen.
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
            ui.panel_bg(0, bar_y, sw_design * frac, 6.0, SLIDER_FILL)

        # Cover thumb (left) — pixels come from the shared cover cache; the
        # playing book's cover was queued above _fetch_next_cover.
        var np_cover_x = row_pad + inner_pad
        var np_cover_size = bar_h - 24.0
        var np_has_thumb = False
        if player.book_id in self.cover_pixels:
            var np_cover_opt = self.cover_pixels[player.book_id]
            if np_cover_opt:
                var np_pixels = np_cover_opt.value()
                var np_packed = self.cover_sizes[player.book_id]
                var np_src_w = np_packed // 1000000
                var np_src_h = np_packed % 1000000
                var s = Float64(ui.ui_scale)
                ui.canvas().blit_rgba(
                    np_pixels,
                    np_src_w,
                    np_src_h,
                    np_src_w * 4,
                    np_cover_x * s,
                    (bar_y + 12.0) * s,
                    np_cover_size * s,
                    np_cover_size * s,
                )
                np_has_thumb = True
        if not np_has_thumb:
            ui.card(
                np_cover_x,
                bar_y + 12.0,
                np_cover_size,
                np_cover_size,
                PLACEHOLDER_BG,
                roundness=0.06,
            )

        # Title + author (right of thumb), vertically centered.
        var np_text_x = np_cover_x + np_cover_size + 18.0
        var np_text_w = sw_design - np_text_x - 300.0
        var np_title = player.book_title
        var np_title_size = 22
        var np_meas = ui._measure_text(np_title, np_title_size)
        if np_meas.x > Float32(np_text_w) * ui.font_scale:
            var np_max_chars = Int(np_text_w / 12.0)
            if np_max_chars > 3:
                np_title = truncate_string(np_title, np_max_chars - 3) + "..."
            else:
                np_title = truncate_string(np_title, np_max_chars)
        ui.move_to(np_text_x, bar_y + 26.0)
        ui.label(np_title, np_title_size, TEXT_BRIGHT)
        ui.move_to(np_text_x, bar_y + 62.0)
        ui.label(player.book_author, 18, TEXT_DIM)

        # Time display (right of text).
        var np_time_x = sw_design - 300.0
        ui.move_to(np_time_x, bar_y + 46.0)
        ui.label(
            format_time(player.current_time)
            + " / "
            + format_time(player.duration),
            18,
            TEXT_LIGHT,
        )

        # Play/pause toggle (far right). Checked BEFORE the open-player bar
        # target below, so the button consumes its own press.
        var np_btn_w = 90.0
        var np_btn_h = 76.0
        var np_btn = ui.button_at(
            ICON_PAUSE if player.is_playing else ICON_PLAY,
            sw_design - row_pad - np_btn_w - 100.0,
            bar_y + (bar_h - np_btn_h) / 2.0,
            np_btn_w,
            np_btn_h,
            GREEN,
            ACCENT_DARK,
            SELECTED_BG,
        )
        if np_btn.clicked:
            player.toggle_playback()
            ui.item_clicked = True

        # Whole-bar click target (album art included): open the player
        # screen. Runs after the button so the button wins when both
        # contain the press (ui._clicked refuses once item_clicked is set).
        var open_rect = ui.rect(0.0, bar_y, sw_design, bar_h)
        if ui._clicked(open_rect):
            screen.current = 2
