from std.time import perf_counter
from std.memory import alloc, Layout, stack_allocation
from std.ffi import external_call
from std.logger import Logger, Level
from std.memory.unsafe_pointer import Pointer

from platform.window import Window, WindowInput
from platform.gamepad import Gamepad
from render.canvas import Canvas

from functions.plex_bridge import (
    PlexSession,
    Config,
    load_config,
    get_servers,
    probe_server,
    get_account_info,
    save_config,
    get_book_detail,
    get_book_tracks,
    download_track,
    get_audio_cache_dir,
)
from functions.ascii import AsciiTable
from resources.config import Config, load_config, save_config, LOG_LEVEL
from resources.keys import KEY_ENTER, KEY_ESCAPE, key_combo

from resources.palette import (
    BG_GRADIENT_BOTTOM,
    BG_GRADIENT_TOP,
    GREEN,
    ERROR_COLOR,
    TEXT_DIM,
)
from resources.plex_objects import LibraryItem, ServerItem, PlexBookCard
from resources.offline_library import (
    from_card,
    save_book_metadata,
    load_saved_books,
    delete_saved_book,
)
from functions.offline_sync import sync_saved_sidecars
from render.imui import UIContext, NavState
from ui import Screen
from ui.font import FontSet
from ui.library_screen import LibraryScreen
from ui.login_screen import LoginScreen
from ui.player_screen import PlayerScreen, OVERLAY_NONE
from ui.selection_screen import SelectionScreen
from ui.settings_screen import SettingsScreen

# ---------------------------------------------------------------------------

comptime SCREEN_W = 1200  # Default window width (logical pixels)
comptime SCREEN_H = 1000  # Default window height (logical pixels)

# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------


def _eprint(s: String):
    """Unbuffered teardown breadcrumb: crash-safe direct write to fd 2.

    print()/logger go through block-buffered stdout; when a segfault kills
    the process mid-teardown, buffered lines vanish — which made the
    earlier breadcrumbs lie about how far teardown got. Goes through
    writev(2): the plain write symbol collides with a stdlib declaration
    (the same trap as gamepad open→open64); writev is one atomic write.
    The iovec is a raw (base, len) word pair — struct iovec layout on
    x86_64 (void* + size_t), built as two stack Ints."""
    var mut_s = s
    var addr = Int(mut_s.as_c_string_span().ptr())
    var iov = stack_allocation[2, Int]()
    iov[unsafe_offset=0] = addr  # iov_base
    iov[unsafe_offset=1] = mut_s.byte_length()  # iov_len
    _ = external_call["writev", Int](2, iov, 1)


def main() raises:
    # Audio is handled by the native AudioBackend (pa_simple via libpulse);
    # it creates/destroys its own device connection per stream. Nothing to
    # initialize here.
    var logger = Logger[LOG_LEVEL]()

    logger.info("opening window")
    # Open a native Wayland window (xdg-shell + wl_shm)
    var win = Window.open("Quire", SCREEN_W, SCREEN_H)
    logger.info("window opened")
    var cur_w = win.frame.width
    var cur_h = win.frame.height

    # Build ASCII lookup table for character input
    var ascii = AsciiTable()
    ascii.init()

    # Load glyph atlases at the ladder sizes (FreeType shim), baked
    # directly into a heap box. UIContext holds a raw pointer; FontSet
    # value copies double-freed the shared atlas mask/List pointers
    # (TCMalloc crash on frame 1), so copies are avoided entirely.
    var dpi_for_bake = 1.0  # wl_shm buffer is physical px; scale == 1 for now
    var fonts_box = alloc(Layout[FontSet](count=1)).unsafe_leak()
    fonts_box.unsafe_write(
        FontSet()
    )  # first-time init: alloc gives uninitialized memory; ptr[i]= destroys old pointee first
    logger.info("fonts load...")
    fonts_box[unsafe_offset=0].load(
        "assets/CaskaydiaCoveNerdFontMono-Regular.ttf", dpi_for_bake
    )
    logger.info("fonts loaded")

    # Load user font multiplier from config (1.0 = default size)
    var font_multiplier = Float64(1.0)
    var keybinds = Dict[String, List[List[Int]]]()
    # String-form keybinds kept for the settings screen editor (action ->
    # key-name strings). The resolved Int combos above feed UIContext.
    var cfg_keybinds = Dict[String, List[String]]()
    try:
        var cfg = load_config()
        font_multiplier = cfg.font_multiplier
        if font_multiplier < 0.5:
            font_multiplier = 0.5
        if font_multiplier > 3.0:
            font_multiplier = 3.0
        # Resolve config keybind specs to keycode combos. Each spec like
        # "KEY_LEFT_SHIFT+KEY_LEFT" becomes [340, 263]. A single key like
        # "KEY_SPACE" becomes [32]. Unknown keys yield an empty combo
        # (treated as "no keybind" by UIContext.check_keybind).
        for entry in cfg.keybinds.items():
            var combos = List[List[Int]]()
            for spec in entry.value:
                combos.append(key_combo(spec))
            keybinds[entry.key] = combos^
            cfg_keybinds[entry.key] = entry.value.copy()
    except:
        logger.warning("failed to load config")

    # Fallback: if config load failed or saved config had no keybinds,
    # populate with defaults so input works on first run / after corruption.
    if len(keybinds) == 0:
        var defaults = Config()
        font_multiplier = defaults.font_multiplier
        for entry in defaults.keybinds.items():
            var combos = List[List[Int]]()
            for spec in entry.value:
                combos.append(key_combo(spec))
            keybinds[entry.key] = combos^
            cfg_keybinds[entry.key] = entry.value.copy()

    # Create app state and login screen
    var app_state = PlexSession()
    var screen = Screen()
    var login = LoginScreen(cur_w, cur_h)
    var library = LibraryScreen(cur_w, cur_h)
    var player = PlayerScreen(cur_w, cur_h)
    var selection = SelectionScreen(cur_w, cur_h)
    var settings = SettingsScreen(cur_w, cur_h)
    settings.load_from_config(font_multiplier, cfg_keybinds)
    var was_logged_in = False

    # --- Try to restore saved session ---
    # If we have a valid saved config, skip login and go directly to library.
    #
    # Offline precedence: the saved session is restored even when the
    # server is unreachable — config.json + the sidecar store are enough
    # to run the library fully offline. The test is a SHORT-timeout
    # identity probe (~2.5s, not test_server's 30s scalar) and a failed
    # probe only flags the session offline (see PlexSession.offline);
    # the first-frame transition then loads sidecars immediately.
    try:
        var saved = load_config()
        var saved_token = saved.account_token
        var saved_server_url = saved.server_url
        var saved_library_id = saved.library_id

        if (
            saved_token.byte_length() > 0
            and saved_server_url.byte_length() > 0
            and saved_library_id.byte_length() > 0
        ):
            # Test if the saved server is still reachable
            var saved_server_token = saved.server_token
            var saved_client_id = saved.client_id
            if saved_client_id.byte_length() == 0:
                saved_client_id = saved.client_identifier
            var test_token = saved_server_token
            if test_token.byte_length() == 0:
                test_token = saved_token

            var test_result = probe_server(
                saved_server_url,
                test_token,
                saved_client_id,
            )
            var server_ok = test_result.ok

            # Restore session from saved config — reachable or not.
            app_state.account_token = saved_token
            app_state.server_token = saved_server_token
            app_state.client_id = saved_client_id
            app_state.server_url = saved_server_url
            app_state.server_name = saved.server_name
            app_state.machine_id = saved.machine_id
            app_state.library_id = saved_library_id
            app_state.library_name = saved.library_name
            app_state.username = saved.username
            app_state.logged_in = True
            if not server_ok:
                # Probe failed — flag the session; load_data short-circuits
                # to the sidecar store until a re-probe succeeds. Token/url
                # assignment above mirrors the reachable case exactly.
                app_state.mark_offline()

            # was_logged_in stays False so the transition logic fires
            # on the first frame (loads library data)
            screen.current = 1  # Skip to library screen

            # Populate SelectionScreen with saved server/library data
            # so the back button from Library goes to a populated screen
            var saved_server = ServerItem()
            saved_server.name = app_state.server_name
            saved_server.url = app_state.server_url
            saved_server.token = app_state.server_token
            saved_server.machine_id = app_state.machine_id
            saved_server.is_owned = True
            selection.servers.append(saved_server)
            selection.selected_server_idx = 0
            var saved_library = LibraryItem()
            saved_library.key = app_state.library_id
            saved_library.title = app_state.library_name
            saved_library.lib_type = "artist"
            selection.libraries.append(saved_library)
            selection.selected_library_idx = 0
            selection.phase = 1  # Show library selection phase
            selection.account_token = app_state.account_token
            selection.client_id = app_state.client_id
            selection.status_message = (
                "Selected: "
                + app_state.server_name
                + " / "
                + app_state.library_name
            )
            selection.status_color = GREEN
    except:
        pass  # Config load failure — start fresh with login

    var prev_time = perf_counter()

    # Heap boxes the facade borrows (pointers must stay valid for the whole
    # run, so allocate once — never per-frame). Canvas is constructed
    # IN PLACE in its box — Canvas.copy() was implicated in the TCMalloc
    # double-free crashes.
    var canvas_box = alloc(Layout[Canvas](count=1)).unsafe_leak()
    canvas_box.unsafe_write(
        Canvas(
            win.pixels(), win.frame.width, win.frame.height, win.frame.stride
        )
    )
    var state_box = alloc(Layout[WindowInput](count=1)).unsafe_leak()
    state_box.unsafe_write(win.input.copy())

    # Gamepad: evdev reader thread (hhd virtual "Xbox Elite" or any pad with
    # a dpad). Heap-boxed; UIContext reads it through a raw pointer. If the
    # user has no pad, open() returns False and the UI treats gamepad binds
    # as inert.
    var pad = Gamepad()
    var pad_ok = pad.open()
    if not pad_ok:
        logger.info("gamepad: no pad found (gamepad binds inert)")
    var pad_box = alloc(Layout[Gamepad](count=1)).unsafe_leak()
    pad_box.unsafe_write(pad^)

    # Spatial navigation state (gamepad dpad + arrow keys): heap-boxed,
    # same pattern as the boxes above (the engine needs cross-frame rect
    # memory; UIContext is rebuilt every frame and borrows the box).
    var nav_box = alloc(Layout[NavState](count=1)).unsafe_leak()
    nav_box.unsafe_write(NavState())

    # Main loop — poll libinput + Wayland events, dispatch, render to the
    # wl_shm buffer, present. The window.poll() close signal exits.
    var frame_n = 0
    var keep_going = True
    while keep_going:
        # Delta time (seconds, monotonic)
        var now = perf_counter()
        var dt = now - prev_time
        prev_time = now

        # --- Input handling ---

        # IMUI handles clicks inside each screen's draw() method — no
        # separate click dispatch is needed. Keyboard routing below only
        # covers retained-state paths (search typing).

        # --- Pagination requests from the library screen ---
        # draw() sets next_page_requested/prev_page_requested; we re-fetch
        # here (outside the render loop) so the network call doesn't block
        # mid-draw.
        if screen.current == 1:
            if library.next_page_requested:
                library.next_page_requested = False
                library.page += 1
                try:
                    library.load_data(app_state)
                except:
                    pass
            elif library.prev_page_requested:
                library.prev_page_requested = False
                if library.page > 0:
                    library.page -= 1
                    try:
                        library.load_data(app_state)
                    except:
                        pass

            # --- One-time sidecar backfill (offline-library completeness) ---
            # The library raises sync_requested when the server is online
            # and backfill hasn't happened this session. Backfilling writes
            # sidecars for audio-on-disk books the store predates; a reload
            # then includes them as fully-searchable offline rows.
            if library.sync_requested:
                library.sync_requested = False
                try:
                    var backfilled = sync_saved_sidecars(app_state)
                    library.sync_done = True
                    if backfilled > 0:
                        print(
                            "[Quire] sidecar backfill wrote ",
                            backfilled,
                            " sidecars",
                        )
                        # Bring the new offline rows into this load.
                        try:
                            library.load_data(app_state)
                        except:
                            pass
                except e:
                    print("[Quire] sidecar backfill failed: " + String(e))

            # --- Download (SAVE) request from the library screen ---
            # Fetches the book's track list then streams the file into the
            # audio cache. Runs outside the render loop: both network calls
            # block, so the UI must not be mid-draw.
            if library.download_requested:
                library.download_requested = False
                var dl_idx = library.download_book_index
                library.download_book_index = -1
                if dl_idx >= 0 and dl_idx < len(library.books):
                    var dl_book = library.books[dl_idx]
                    try:
                        var dl_detail = get_book_detail(
                            app_state.server_url,
                            app_state.server_token,
                            dl_book.rating_key,
                        )
                        var dl_tracks = get_book_tracks(
                            app_state.server_url,
                            app_state.server_token,
                            dl_book.rating_key,
                        )
                        if (
                            len(dl_tracks) > 0
                            and dl_tracks[0].file_key.byte_length() > 0
                        ):
                            var dl_path = download_track(
                                app_state.server_url,
                                app_state.server_token,
                                dl_tracks[0].file_key,
                                dl_book.rating_key,
                                app_state.client_id,
                            )
                            if dl_path.byte_length() > 0:
                                library.status_message = (
                                    "Saved: " + dl_book.title
                                )
                                library.status_color = GREEN
                                # Refresh the badge memo: the row renders
                                # its DOWNLOADED tag from this dict, and a
                                # stale False would hide a fresh save.
                                library.downloaded_cache[
                                    dl_book.rating_key
                                ] = True
                                # Persist the offline sidecar: title/
                                # author/thumb/etc. so the library can
                                # show this book with no server at all.
                                try:
                                    var now_ms = Int(
                                        perf_counter()
                                    )  # monotonic; only ordering matters
                                    var meta = from_card(dl_book, now_ms)
                                    save_book_metadata(meta)
                                    # Pin the fresh download onto the head
                                    # of the current list right away.
                                    library.pinned_books.insert(
                                        0, meta.to_card()
                                    )
                                except e:
                                    print(
                                        "[Quire] sidecar save failed: ",
                                        e,
                                    )
                                # Hoist the fresh download immediately —
                                # same ordering pass as a page reload.
                                try:
                                    library._sort_books_for_display()
                                except:
                                    pass
                            else:
                                library.status_message = (
                                    "Download failed: " + dl_book.title
                                )
                                library.status_color = ERROR_COLOR
                        else:
                            library.status_message = (
                                "No tracks found for: " + dl_book.title
                            )
                            library.status_color = ERROR_COLOR
                    except e:
                        library.status_message = "Download error: " + String(e)
                        library.status_color = ERROR_COLOR

            # --- Delete request from the library screen ---
            # Frees the book's local copy (sidecar + audio cache files).
            # Filesystem-only: no network, but still handled outside the
            # render loop (mirrors the SAVE request above) so draw() stays
            # non-blocking.
            if library.delete_requested:
                library.delete_requested = False
                var del_idx = library.delete_book_index
                library.delete_book_index = -1
                if del_idx >= 0 and del_idx < len(library.books):
                    var del_book = library.books[del_idx]
                    # delete_saved_book swallows per-file failures itself
                    # (never raises); its return value reports whether
                    # anything was actually on disk.
                    var removed = delete_saved_book(
                        del_book.rating_key, get_audio_cache_dir()
                    )
                    if removed:
                        # Refresh the badge memo so the row flips back to
                        # SAVE this frame, and drop the card from the pinned
                        # head (a deleted book isn't "recently saved" anymore).
                        library.downloaded_cache[del_book.rating_key] = False
                        var kept = List[PlexBookCard]()
                        for j in range(len(library.pinned_books)):
                            if (
                                library.pinned_books[j].rating_key
                                != del_book.rating_key
                            ):
                                kept.append(library.pinned_books[j])
                        library.pinned_books = kept^
                        library.status_message = "Deleted: " + del_book.title
                        library.status_color = GREEN
                        try:
                            library._sort_books_for_display()
                        except:
                            pass
                    else:
                        library.status_message = (
                            "Nothing saved for: " + del_book.title
                        )
                        library.status_color = ERROR_COLOR

            # --- Server-side search request from the library screen ---
            # draw() sets search_query_requested + pending_search_query when
            # the search bar text changes; run the query here so the network
            # call doesn't block mid-draw.
            if library.search_query_requested:
                library.search_query_requested = False
                var query = library.pending_search_query
                try:
                    library.run_search(app_state, query)
                except:
                    pass

        # --- Library-list request from the selection screen ---
        # draw() sets libraries_requested when a server card is picked; run
        # the get_libraries fetch here (outside the render loop — mirror of
        # search_query_requested above) so the network call doesn't block
        # mid-draw. Failures land in the selection screen's status line
        # (load_libraries guards internally).
        if screen.current == 3:
            if selection.libraries_requested:
                selection.libraries_requested = False
                try:
                    selection.load_libraries()
                except:
                    pass

        # --- Settings screen save / reset requests ---
        # draw() sets save_requested / reset_requested; we persist (or
        # restore defaults) here, outside the render loop. On save, the
        # resolved keybind combos and font_multiplier are rebuilt so the
        # change takes effect this session.
        if screen.current == 4:
            if settings.reset_requested:
                settings.reset_requested = False
                var fresh = Config()
                font_multiplier = fresh.font_multiplier
                cfg_keybinds = fresh.keybinds.copy()
                keybinds = Dict[String, List[List[Int]]]()
                for entry in cfg_keybinds.items():
                    var combos = List[List[Int]]()
                    for spec in entry.value:
                        combos.append(key_combo(spec))
                    keybinds[entry.key] = combos^
                settings.load_from_config(font_multiplier, cfg_keybinds)
                settings.status_message = "Reset to defaults"
                settings.status_color = GREEN

            if settings.save_requested:
                settings.save_requested = False
                font_multiplier = settings.font_multiplier
                cfg_keybinds = settings.keybinds.copy()
                # Rebuild resolved combos for UIContext.check_keybind.
                keybinds = Dict[String, List[List[Int]]]()
                for entry in cfg_keybinds.items():
                    var combos = List[List[Int]]()
                    for spec in entry.value:
                        combos.append(key_combo(spec))
                    keybinds[entry.key] = combos^
                # Persist to config file (best-effort).
                try:
                    var cfg = load_config().copy()
                    cfg.font_multiplier = font_multiplier
                    cfg.keybinds = cfg_keybinds.copy()
                    save_config(cfg)
                    settings.dirty = False
                    settings.status_message = "Saved"
                    settings.status_color = GREEN
                except:
                    settings.status_message = "Save failed"
                    settings.status_color = ERROR_COLOR

        # Escape key — navigation (frame's queued key events, press edge)
        # NOTE: library (1) has no escape-back on purpose — the Selection
        # screen is reachable only via the Settings screen's SELECT LIBRARY
        # button, so a stray Esc can't bounce the user out of the library.
        # Gamepad B (RIGHT_FACE_RIGHT, the back_button bind) mirrors Esc.
        var back_now = win.input.frame_key_pressed(KEY_ESCAPE)
        if (
            not back_now
            and win.input.focused
            and pad_ok
            and pad_box[unsafe_offset=0].was_pressed(6)
        ):
            back_now = True  # gamepad B face button
        if back_now:
            if screen.current == 3:
                if selection.phase == 1:
                    # Mirror the selection screen's BACK click: lift back
                    # to the server list, not out to login.
                    selection.phase = 0
                    selection.selected_library_idx = -1
                    selection.libraries = List[LibraryItem]()
                    selection.scroll_offset = 0.0
                    selection.status_message = "Select a server"
                    selection.status_color = TEXT_DIM
                else:
                    # Selection screen: back to login
                    screen.current = 0
            elif screen.current == 2:
                # Player → Library, stop audio
                player.stop_and_unload_stream()
                screen.current = 1
            elif screen.current == 4:
                # Settings → Library
                screen.current = 1

        # --- Auth complete → Selection screen transition ---
        if login.auth_complete and screen.current == 0:
            screen.current = 3  # SelectionScreen
            # Guarded: get_servers is the one unguarded network call in
            # the frame loop — offline it raised straight through and
            # killed the process. Failures land in the selection screen's
            # status line (same error-string shape as load_servers').
            var fetch_ok = False
            var servers = List[ServerItem]()
            try:
                var fetched = get_servers(
                    app_state.account_token,
                    app_state.client_id,
                )
                servers = fetched^
                fetch_ok = True
            except e:
                selection.status_message = String(e)
                selection.status_color = ERROR_COLOR

            if fetch_ok:
                var server_count = len(servers)

                # Guard: no servers found
                if server_count == 0:
                    selection.status_message = "No Plex servers found"
                    selection.status_color = ERROR_COLOR
                else:
                    try:
                        selection.load_servers(
                            servers,
                            app_state.account_token,
                            app_state.client_id,
                        )
                    except e:
                        selection.status_message = String(e)
                        selection.status_color = ERROR_COLOR
            login.auth_complete = False

        # --- Selection complete → Library screen transition ---
        if selection.selection_complete and screen.current == 3:
            # Populate app_state from selected server and library
            var server = selection.servers[selection.selected_server_idx]
            var library_item = selection.libraries[
                selection.selected_library_idx
            ]

            app_state.server_token = server.token
            app_state.server_url = server.url
            app_state.server_name = server.name
            app_state.machine_id = server.machine_id
            app_state.library_id = library_item.key
            app_state.library_name = library_item.title

            # Try to get username from Plex account, fall back to "User"
            var username = "User"
            try:
                var account_info = get_account_info(
                    app_state.account_token,
                    app_state.client_id,
                )
                if account_info.username.byte_length() > 0:
                    username = account_info.username
            except:
                pass  # Non-critical — default to "User"
            app_state.username = username

            app_state.logged_in = True

            # Save config (best-effort — non-critical if it fails)
            try:
                var cfg = Config()
                cfg.account_token = app_state.account_token
                cfg.server_token = server.token
                cfg.client_id = app_state.client_id
                cfg.server_url = server.url
                cfg.server_name = server.name
                cfg.machine_id = server.machine_id
                cfg.library_id = library_item.key
                cfg.library_name = library_item.title
                cfg.username = username
                cfg.client_identifier = app_state.client_id
                save_config(cfg)
            except:
                pass  # Config save failure is non-critical

            selection.selection_complete = False

        # --- Login transition (logged_in flag set by selection flow) ---
        if app_state.logged_in and not was_logged_in:
            # Just logged in — load library data and switch screens
            try:
                library.load_data(app_state)
            except e:
                pass  # Error already stored in library.status_message
            screen.current = 1
            was_logged_in = True
        elif not app_state.logged_in:
            was_logged_in = False

        # --- Play request transition (library -> player) ---
        if library.play_requested and screen.current == 2:
            var book_idx = library.play_book_index
            if book_idx >= 0 and book_idx < len(library.books):
                try:
                    player.load_book(library.books[book_idx], app_state)
                except e:
                    pass  # Proceed with basic card data
            library.play_requested = False
            library.play_book_index = -1

        # --- Rendering ---
        # Build the per-frame UI context: captures mouse, dt, fonts, and
        # computes ui_scale from window size + DPI. All screens use design
        # UIContext borrows the heap-boxed Canvas + InputState (main owns the
        # backing storage; the facade only holds raw pointers for the frame).
        # Boxes are allocated ONCE (loop-invariant); only the InputState
        # mirror is refreshed per frame. Copying Canvas/FontSet every frame
        # leaked heap blocks and (worse) shared atlas masks got freed twice.
        state_box.unsafe_write(win.input.copy())

        # Double-buffering: present() swaps frame/back roles when it commits.
        # The mmap addresses travel WITH the Frame structs, so after a swap
        # the drawing buffer changed — refresh the Canvas box to the current
        # draw buffer every frame (cheap struct move, no pixel copies).
        canvas_box[unsafe_offset=0] = Canvas(
            win.pixels(), win.frame.width, win.frame.height, win.frame.stride
        )

        # Compositor requested a new size: rebuild the framebuffer + canvas
        # (the UI scale recalculator derives from the UIContext ctor below).
        if win.pending_resize:
            var rw = win.pending_resize_w
            var rh = win.pending_resize_h
            if rw < 1:
                rw = 1
            if rh < 1:
                rh = 1
            win.rebuild_frame(rw, rh)
            cur_w = rw
            cur_h = rh
            canvas_box[unsafe_offset=0] = Canvas(
                win.pixels(),
                win.frame.width,
                win.frame.height,
                win.frame.stride,
            )
            win.pending_resize = False

        var ui = UIContext(
            fonts_box,
            canvas_box,
            state_box,
            dt,
            Int(cur_w),
            Int(cur_h),
            keybinds.copy(),
            1.0,
            font_multiplier,
            Optional[Pointer[Gamepad, MutUntrackedOrigin]](pad_box),
            Optional[Pointer[NavState, MutUntrackedOrigin]](nav_box),
            screen.current,
            # Rebind capture owns the pad while the settings screen waits
            # for a button (nav must not eat the press being captured).
            not (
                screen.current == 4
                and settings.rebinding_action.byte_length() > 0
            ),
            # The player screen's base layout owns left/right for the ±30s
            # seeks; overlays (chapter drawer / popovers) hand them back.
            screen.current != 2 or player.overlay_mode != OVERLAY_NONE,
        )

        # Library search input consumes keystrokes via the UI context.
        library.handle_keyboard(ui, ascii)

        # Login Enter-to-connect runs AFTER the UI context consumed the
        # frame's nav edges: a dpad/gamepad-focused connect button must
        # not double-fire the OAuth flow (its activation fires at draw
        # time), so plain-Enter only connects when nothing is focused.
        if screen.current == 0:
            login.handle_keyboard(
                win.input.frame_key_pressed(KEY_ENTER)
                and ui.nav_focused_id() < 0,
                app_state,
            )

        canvas_box[unsafe_offset=0].clear_gradient(
            BG_GRADIENT_TOP, BG_GRADIENT_BOTTOM
        )

        # Per-frame playback update runs on EVERY screen: the now-playing
        # bar on the library screen controls playback, so the ffmpeg pipe
        # must keep being pumped (PCM feed + time advance) even while the
        # player screen isn't visible — otherwise pressing play there
        # spawns a stream but no audio ever flows.
        player.update_playback(dt)
        if player.is_playing:
            player.progress_sync_timer = player.progress_sync_timer + dt
            player._sync_progress()

        if screen.current == 0:
            login.draw(ui, app_state)
        elif screen.current == 1:
            canvas_box[unsafe_offset=0].clear_gradient(
                BG_GRADIENT_TOP, BG_GRADIENT_BOTTOM
            )
            # Wheel scroll: win.input.wheel_delta accumulates wl_pointer axis
            # events inside poll(). Consume it for the card list.
            if win.input.wheel_delta != 0.0:
                library.handle_scroll(
                    Float32(win.input.wheel_delta), Int(cur_h)
                )
                win.input.wheel_delta = 0.0
            library.draw(ui, app_state, screen, player)
        elif screen.current == 2:
            canvas_box[unsafe_offset=0].clear_gradient(
                BG_GRADIENT_TOP, BG_GRADIENT_BOTTOM
            )
            # Wheel scroll drives the chapter drawer when it is open
            # (handle_scroll no-ops otherwise); consume the accumulated delta.
            if win.input.wheel_delta != 0.0:
                player.handle_scroll(Float32(win.input.wheel_delta), Int(cur_h))
                win.input.wheel_delta = 0.0

            # Progress sync timer — increment when playing, sync periodically
            if (
                not player.is_playing
                and player.current_time > 0.0
                and (player.duration > 0.0)
            ):
                # Not playing but has position — check if near end for watched mark
                var remaining = player.duration - player.current_time
                if remaining < 1.0:
                    player._mark_track_watched()

            player.draw(ui, screen)
        elif screen.current == 3:
            canvas_box[unsafe_offset=0].clear_gradient(
                BG_GRADIENT_TOP, BG_GRADIENT_BOTTOM
            )
            selection.draw(ui, app_state, screen)
        elif screen.current == 4:
            canvas_box[unsafe_offset=0].clear_gradient(
                BG_GRADIENT_TOP, BG_GRADIENT_BOTTOM
            )
            settings.draw(ui, app_state, screen)

        win.present()

        # Lazy cover fetch — deliberately AFTER present: the fetch (HTTP
        # timeout, disk read, imdecode) can stall the NEXT frame's input
        # processing, but it no longer delays this frame's presentation.
        # draw() queued the visible rows + the now-playing art above; the
        # blit of already-decoded covers still happens in the row loop.
        # Library-screen parity: only library.draw() fetched before.
        if screen.current == 1:
            library._fetch_next_cover(app_state, player)

        # Clear the gamepad pressed-edge mask (edge true for exactly one
        # frame, mirroring the keyboard pending_clear model).
        pad_box[unsafe_offset=0].end_frame()

        # Compositor event pump; False = close requested.
        if not win.poll():
            keep_going = False
        frame_n += 1

    # Cleanup (fonts live in the heap box after the move)
    player.stop_and_unload_stream()
    _eprint("\n[td] player stopped\n")
    pad_box[unsafe_offset=0].close()
    _eprint("[td] gamepad closed\n")
    win.close()
    _eprint("[td] window closed\n")
    fonts_box[unsafe_offset=0].unload()
    _eprint("[td] fonts unloaded\n")

    # Clear the keybind dictionaries BEFORE scope-exit deinits run.
    #
    # Their List[String]/List[List[Int]] values share COW storage with
    # copies held by Config values (save_config) and SettingsScreen
    # (load_from_config). Letting the implicit deinits release that shared
    # storage on this toolchain segfaults in List.__deinit__ at scope exit
    # (X-button close → same crash every time). Explicitly emptying the
    # dicts here releases main's references first, leaving a single owner
    # per allocation — the same "control the teardown" rule the heap-boxed
    # Canvas/FontSet already follow above.
    library.clear_teardown()
    settings.clear_keybinds()
    cfg_keybinds.clear()
    keybinds.clear()
    _eprint("[td] containers cleared\n")

    # Everything the OS must not inherit is closed; every container whose
    # implicit deinit has shown itself unsafe (or whose identity is
    # unclear through inlining) has been explicitly released. Whatever
    # remains in main's frame — screens' remaining List[String] state,
    # COW-shared Config copies, the Python interop runtime — still segfaults
    # in List.__deinit__ when the frame unwinds. All real resources
    # ( Wayland, audio, file descriptors, fonts) are already released, so
    # the remaining teardown is pure memory hygiene at process exit: let
    # the kernel reclaim it. _exit skips the unwind entirely; the exit code
    # 0 preserves the app's success semantics.
    _eprint("[td] clean exit\n")
    _ = external_call["_exit", NoneType](0)
