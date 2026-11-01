from std.os import makedirs, path
from std.pathlib import Path
from std.collections import List, Dict, Optional
from std.memory.unsafe_pointer import Pointer
from std.memory import alloc, dealloc, Layout, ThinAllocation, unsafe_memcpy
from std.math import max
from std.time import perf_counter
from resources.color import Color
from resources.imdecode import imdecode
from resources.keys import (
    KEY_BACKSPACE,
    KEY_TAB,
    KEY_ENTER,
    KEY_DELETE,
    KEY_ESCAPE,
)
from render.imui import (
    DESIGN_W,
    UIContext,
    UIResult,
    Vec2,
    Rect,
    NAV_DOWN,
    NAV_UP,
)

from functions.helpers import (
    format_time,
    truncate_string,
    truncate_to_width,
    split_wrap_chars,
)
from functions.audio_pipe import AudioPipe, ChunkResult, HttpHeader
from platform.audio_backend import AudioBackend
from resources.offline_library import (
    update_saved_progress,
    load_saved_books,
)
from resources.plex_api_types import BookDetail
from functions.plex_bridge import (
    PlexSession,
    get_book_detail,
    get_book_tracks,
    get_track_chapters,
    start_play_queue,
    get_playback_decision,
    download_track,
    get_audio_cache_dir,
    get_thumbnail_url,
    report_progress,
    mark_watched,
    mark_unwatched,
    fetch_thumbnail,
    load_cached_cover,
    save_cached_cover,
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

from ui.widgets import TextInput, Button, Checkbox, PlexBookCard
from ui.font import FontSet
from ui import Screen
from ui.icons import (
    ICON_PLAY,
    ICON_PAUSE,
    ICON_PAUSE_CIRCLE,
    ICON_CHEV_LEFT,
    ICON_CHEV_RIGHT,
    ICON_SKIP_BACK,
    ICON_SKIP_FORWARD,
    ICON_LAYERS,
    ICON_INFO,
    ICON_TUNE,
    ICON_LIST,
    ICON_HEADPHONES,
    ICON_CLOSE,
)

# ---------------------------------------------------------------------------
# Player screen — layout1 redesign (assets/quire-layout1.png)
#
# Minimal single-view layout: centered title header, icon rails on the left
# (chapter drawer / settings / info toggles) and right (±30s / circled play),
# a large centered cover, and two bottom seek bars — book above, chapter
# below, flanked by chapter-skip chevrons. Overlays are mutually exclusive;
# a click outside a floating card closes it.
# ---------------------------------------------------------------------------


# Overlay panels (mutually exclusive — one drawer/popover at a time).
comptime OVERLAY_NONE = 0
comptime OVERLAY_CHAPTERS = 1
comptime OVERLAY_SETTINGS = 2
comptime OVERLAY_INFO = 3

# Seconds skipped by the right-rail double-chevron buttons.
comptime SKIP_SECONDS = 30.0

# Chapter drawer metrics (design px) — shared by draw() and handle_scroll()
# so the-scroll clamp matches the painted geometry exactly.
comptime DRAWER_W = 520.0
comptime DRAWER_TOP = 140.0
comptime DRAWER_MIN_H = 240.0
comptime DRAWER_TITLE_ROW = 72.0
comptime DRAWER_PAD_BOTTOM = 16.0

# Chapter drawer row metrics (design px) — two-line row: title, then times.
comptime CHAPTER_ROW_H = 76.0

# Cover art request size (square, source px). Higher than display size so
# the blit stays sharp when the window is large or DPI-scaled up.
comptime COVER_PX = 600


struct PlayerScreen:
    var book_id: String
    var book_title: String
    var book_author: String
    var book_thumb: String  # Plex thumb path (library bar cover queueing)
    var book_narrator: String
    var book_series: String
    var book_publisher_year: String
    var book_genres: String
    var book_description: String
    var book_duration: Float64

    # Playback state
    var is_playing: Bool
    var current_time: Float64
    var duration: Float64
    var speed: Float64
    var volume: Float64

    # Tracks and chapters
    var tracks: List[PlexTrack]
    var chapters: List[PlexChapter]
    var current_chapter_idx: Int
    var chapter_scroll_offset: Float32

    # Slider drag state (retained — owned by screen, not UI)
    var progress_dragging: Bool
    var chapter_dragging: Bool
    var volume_dragging: Bool

    # Audio playback (native Mojo AudioBackend + AudioPipe).
    # AudioPipe spawns ffmpeg via popen and feeds f32le PCM into a persistent
    # heap buffer; Mojo reads its C address and the backend copies it into its
    # ring buffer (writer thread drains to pa_simple) — zero per-float FFI
    # crossings.
    var audio_backend: AudioBackend
    var has_stream: Bool
    var pipe: AudioPipe
    var pipe_loaded: Bool
    var stream_source: String
    var stream_is_local: Bool
    # advance normalized playback time independent of speed (atempo already
    # changed the audio rate; frames_fed / sample_rate is wall-clock time).
    var frames_fed_since_restart: Int

    # Play queue tracking for Plex progress reporting
    var play_queue_id: Int
    var play_queue_items: Dict[String, Int]

    # Progress sync state
    var progress_sync_timer: Float64
    var progress_sync_interval: Float64
    # Minimum silence after a FAILED push before the next attempt: a
    # down/slow server must not get a blocking HTTP retry per frame.
    var progress_sync_retry_delay: Float64
    var current_track_rating_key: String

    # Stored session data for playback URL resolution
    var server_url: String
    var token: String
    var client_id: String

    # Play request flag
    var play_requested: Bool
    var play_book_index: Int

    # Cover art pixels (decoded RGBA bytes via resources.imdecode; no GPU
    # textures — blit_rgba swaps to the canvas BGRX layout).
    var cover_pixels: Optional[Pointer[UInt8, MutUntrackedOrigin]]
    var cover_w: Int
    var cover_h: Int
    var has_cover: Bool
    var cover_loaded: Bool

    # Layout1 overlay state (mutually exclusive panels).
    var overlay_mode: Int  # OVERLAY_NONE / CHAPTERS / SETTINGS / INFO
    var overlay_armed: Bool  # click-outside armed after a toggle click

    def __init__(out self, screen_w: Int, screen_h: Int):
        self.book_id = ""
        self.book_title = ""
        self.book_author = ""
        self.book_thumb = ""
        self.book_narrator = ""
        self.book_series = ""
        self.book_publisher_year = ""
        self.book_genres = ""
        self.book_description = ""
        self.book_duration = 0.0

        self.is_playing = False
        self.current_time = 0.0
        self.duration = 0.0
        self.speed = 1.0
        self.volume = 0.8

        self.tracks = List[PlexTrack]()
        self.chapters = List[PlexChapter]()
        self.current_chapter_idx = -1
        self.chapter_scroll_offset = 0.0
        self.overlay_mode = OVERLAY_NONE
        self.overlay_armed = False

        self.progress_dragging = False
        self.chapter_dragging = False
        self.volume_dragging = False

        # Audio: uncreated AudioBackend (valid only when has_stream=True).
        # The AudioPipe is created lazily on first start so we don't spawn
        # ffmpeg until a book is opened.
        self.audio_backend = AudioBackend()
        self.has_stream = False
        self.pipe = AudioPipe()
        self.pipe_loaded = True  # native struct — always ready, no lazy import
        self.stream_source = ""
        self.stream_is_local = False
        self.frames_fed_since_restart = 0

        self.play_queue_id = 0
        self.play_queue_items = Dict[String, Int]()
        self.progress_sync_timer = 0.0
        self.progress_sync_interval = 5.0
        self.progress_sync_retry_delay = 1.0
        self.current_track_rating_key = ""
        self.server_url = ""
        self.token = ""
        self.client_id = ""

        self.play_requested = False
        self.play_book_index = -1

        self.cover_pixels = Optional[
            Pointer[UInt8, MutUntrackedOrigin]
        ]()  # overwritten before any blit
        self.cover_w = 0
        self.cover_h = 0
        self.has_cover = False
        self.cover_loaded = False

        self.overlay_mode = OVERLAY_NONE
        self.overlay_armed = False

    def load_book(
        mut self, book: PlexBookCard, mut app_state: PlexSession
    ) raises:
        """Load a book into the player. Every server call below is
        independently guarded — a failure keeps what's already loaded and
        falls through instead of aborting, so stream preparation ALWAYS
        runs (a downloaded book plays with no server at all).

        Precedence, field by field:
          title/author  — the library card (always available, even offline)
          duration      — card -> server detail -> track sum -> sidecar
          cover         — server thumb path (sidecars/cache fill offline)
          resume point  — server detail/track offsets -> sidecar
                          view_offset_ms (only when the server couldn't
                          answer for this load)
          publish year  — server detail -> sidecar
        A failed fetch marks the session offline (app_state.mark_offline)
        so later loads skip the doomed round-trips; a successful one
        clears the flag."""
        # Unload previous cover art before loading a new book
        if self.has_cover:
            var old_pixels = self.cover_pixels.take()
            dealloc(
                ThinAllocation(unsafe_owned_ptr=old_pixels).unsafe_with_layout(
                    Layout[UInt8](count=self.cover_w * self.cover_h * 4)
                )
            )
            self.has_cover = False
        self.cover_loaded = False

        self.book_id = book.rating_key
        self.book_title = book.title
        self.book_author = book.author
        self.book_thumb = ""
        self.book_narrator = ""
        self.book_series = ""
        self.book_publisher_year = ""
        self.book_genres = ""
        self.book_description = ""
        self.duration = Float64(book.duration_ms) / 1000.0
        self.book_duration = self.duration
        self.current_time = 0.0
        self.is_playing = False
        self.speed = 1.0
        self.volume = 0.8
        self.frames_fed_since_restart = 0
        self.current_chapter_idx = -1
        self.chapter_scroll_offset = 0.0
        self.progress_dragging = False
        self.chapter_dragging = False
        self.volume_dragging = False
        self.tracks = List[PlexTrack]()
        self.chapters = List[PlexChapter]()
        self.play_queue_id = 0
        self.play_queue_items = Dict[String, Int]()

        var token = app_state.server_token
        if token.byte_length() == 0:
            token = app_state.account_token
        self.server_url = app_state.server_url
        self.token = token
        self.client_id = app_state.client_id

        # --- Sidecar for this book (local, cheap, read up front) ---
        # Written on every player unload (update_saved_progress), so it
        # carries the freshest offline-known resume point + listing data.
        # Matched by index in `saved_books` — SavedBookMetadata is
        # Movable-only, so a copy is hand-work the index avoids.
        var sidecar_idx = -1
        var saved_books = load_saved_books()
        for i in range(len(saved_books)):
            if saved_books[i].rating_key == book.rating_key:
                sidecar_idx = i
                break
        var have_sidecar = sidecar_idx >= 0

        # --- Book detail (server) — skipped only when known-offline ---
        var detail = BookDetail()
        var detail_ok = False
        if not app_state.offline:
            try:
                detail = get_book_detail(
                    app_state.server_url,
                    token,
                    book.rating_key,
                    app_state.client_id,
                )
                detail_ok = True
                # Successful server operation: clear the offline flag.
                app_state.offline = False
            except e:
                print(
                    "[player] book detail fetch failed (offline?): " + String(e)
                )
                app_state.mark_offline()

        # Cover art: prefer the server thumb path; when the detail fetch
        # didn't answer the card's thumb path fills the gap.
        var thumb_path = detail.thumb
        if not detail_ok:
            thumb_path = book.thumb
        try:
            self._load_cover(thumb_path, app_state)
            self.book_thumb = thumb_path
        except e:
            # DIAGNOSTIC: cover art is decorative, but surface why it failed.
            print("cover load failed:", e)

        if detail.rating_key.byte_length() > 0:
            self.book_narrator = ""
            self.book_series = ""

            if detail.year > 0:
                self.book_publisher_year = String(detail.year)
            else:
                self.book_publisher_year = ""

            var genres_text = String("")
            for i in range(len(detail.genres)):
                if i > 0:
                    genres_text = genres_text + ", "
                genres_text = genres_text + detail.genres[i]
            self.book_genres = genres_text

            self.book_description = detail.summary
            self.current_time = Float64(detail.view_offset_ms) / 1000.0

            # The book-detail API has the authoritative duration. The library
            # listing may report 0 for duration_ms, so prefer detail's value
            # and fall back to the book-card value.
            if detail.duration_ms > 0:
                self.duration = Float64(detail.duration_ms) / 1000.0
                self.book_duration = self.duration

        # --- Track list (server) — skipped only when known-offline ---
        var tracks_ok = False
        if not app_state.offline:
            try:
                var tracks = get_book_tracks(
                    app_state.server_url,
                    token,
                    book.rating_key,
                    app_state.client_id,
                )
                # COW transfer: shares track storage with the API result
                # until one side mutates — no per-track copy loop.
                self.tracks = tracks.copy()
                tracks_ok = True
            except e:
                print(
                    "[player] track list fetch failed (offline?): " + String(e)
                )
                app_state.mark_offline()

        for i in range(len(self.tracks)):
            try:
                var track_chapters = get_track_chapters(
                    app_state.server_url,
                    token,
                    self.tracks[i].rating_key,
                    app_state.client_id,
                )
                for j in range(len(track_chapters)):
                    var chapter = track_chapters[j]
                    chapter.is_current = False
                    self.chapters.append(chapter)
            except e:
                # Per-track chapters are optional metadata — keep playing.
                print(
                    "[player] chapter fetch failed for track "
                    + self.tracks[i].rating_key
                    + ": "
                    + String(e)
                )

        # Fallback: if neither the book card nor the detail API provided a
        # duration, derive it from the sum of track durations.
        if self.duration <= 0.0 and len(self.tracks) > 0:
            var total_ms = 0
            for i in range(len(self.tracks)):
                total_ms += self.tracks[i].duration_ms
            if total_ms > 0:
                self.duration = Float64(total_ms) / 1000.0
                self.book_duration = self.duration

        # --- Sidecar gap fills (last resort — server data preferred) ---
        if have_sidecar:
            ref fill = saved_books[sidecar_idx]
            if self.duration <= 0.0 and fill.duration_ms > 0:
                self.duration = Float64(fill.duration_ms) / 1000.0
                self.book_duration = self.duration
            if self.book_publisher_year.byte_length() == 0 and fill.year > 0:
                self.book_publisher_year = String(fill.year)

        # Restore listen position from track-level progress. Plex stores
        # playback progress on individual tracks (leaves), not on the album.
        # The album-level viewOffset (detail.view_offset_ms) is typically 0.
        #
        # Strategy:
        #   1. Find the first track with a non-zero viewOffset (in-progress).
        #      Position = sum of prior track durations + that track's viewOffset.
        #   2. If no track has a non-zero viewOffset but viewed_leaf_count > 0,
        #      some tracks are completed. Resume at the start of the first
        #      unwatched track (sum of durations of all viewed tracks).
        #   3. Otherwise leave current_time at 0 (fresh start).
        if len(self.tracks) > 0:
            var total_ms = 0
            for i in range(len(self.tracks)):
                total_ms += self.tracks[i].duration_ms

            var cumulative_ms = 0
            var found_progress = False
            for i in range(len(self.tracks)):
                var track = self.tracks[i]
                if (
                    track.view_offset_ms > 0
                    and track.view_offset_ms < track.duration_ms
                ):
                    # This track is in-progress. Position = all prior tracks
                    # fully listened + offset into this track.
                    self.current_time = (
                        Float64(cumulative_ms + track.view_offset_ms) / 1000.0
                    )
                    found_progress = True
                    break
                cumulative_ms += track.duration_ms

            if not found_progress and detail.viewed_leaf_count > 0:
                # Tracks completed but none in-progress — resume at the start
                # of the first unwatched track.
                var viewed = detail.viewed_leaf_count
                if viewed > len(self.tracks):
                    viewed = len(self.tracks)
                var resume_ms = 0
                for i in range(viewed):
                    resume_ms += self.tracks[i].duration_ms
                # A fully-viewed book restarts from the beginning. Resuming
                # at "sum of all durations" would spawn ffmpeg past EOF,
                # which produces no audio and lands on the end-of-stream
                # path — the start-at-the-end bug.
                if viewed < len(self.tracks) and resume_ms < total_ms:
                    self.current_time = Float64(resume_ms) / 1000.0
                else:
                    self.current_time = 0.0
            elif not found_progress and detail.view_offset_ms > 0:
                # Album-level offset only (single-track or edge case).
                self.current_time = Float64(detail.view_offset_ms) / 1000.0

        # Offline resume: when the server couldn't answer for this load
        # (detail or tracks failed or skipped), the sidecar's last-known
        # position is the resume point — it was written at the previous
        # unload. A position at/after the duration means the book was
        # finished; spawn-at-EOF has no audio, so treat it as fresh start.
        if (not detail_ok or not tracks_ok) and have_sidecar:
            ref resume = saved_books[sidecar_idx]
            if (
                self.current_time <= 0.0
                and resume.view_offset_ms > 0
                and (
                    resume.duration_ms <= 0
                    or resume.view_offset_ms < resume.duration_ms
                )
            ):
                self.current_time = Float64(resume.view_offset_ms) / 1000.0

        if len(self.chapters) == 0 and self.duration > 0.0:
            var full_chapter = PlexChapter()
            full_chapter.id = 0
            full_chapter.index = 1
            full_chapter.tag = self.book_title
            full_chapter.start_time_ms = 0
            full_chapter.end_time_ms = Int(self.duration * 1000.0)
            full_chapter.is_current = True
            self.chapters.append(full_chapter)
            self.current_chapter_idx = 0

        # Play queue (server): progress-reporting targets. Skipped offline;
        # a failed queue costs nothing here — reporting just falls back to
        # the no-play-queue-item path in _sync_progress.
        if not app_state.offline:
            try:
                var pq_result = start_play_queue(
                    app_state.server_url,
                    token,
                    app_state.machine_id,
                    book.rating_key,
                    app_state.client_id,
                )
                self.play_queue_id = pq_result.play_queue_id

                for i in range(len(pq_result.items)):
                    var pq_rating_key = pq_result.items[i].rating_key
                    var pq_item_id = pq_result.items[i].play_queue_item_id
                    self.play_queue_items[pq_rating_key] = pq_item_id
            except e:
                print("[player] play queue unavailable: " + String(e))

        if len(self.tracks) > 0:
            self.current_track_rating_key = self.tracks[0].rating_key
        else:
            self.current_track_rating_key = book.rating_key

        self.progress_sync_timer = 0.0
        self._prepare_stream()

    def _ensure_pipe(mut self):
        """No-op: the native AudioPipe is constructed in __init__.

        Kept as a hook so callers don't need to know the pipe is always ready.
        """
        return

    def _prepare_stream(mut self) raises:
        """Decide the stream source (local file or Plex HTTP URL) WITHOUT
        starting playback. Sets stream_source/stream_is_local so the first
        PLAY press can spawn ffmpeg. Falls back to download_track when no
        direct source is available."""
        # Tear down any existing stream + pipe.
        self._stop_stream()

        # 1) Prefer an already-downloaded local file.
        var extensions = List[String]()
        extensions.append("mp3")
        extensions.append("ogg")
        extensions.append("wav")
        extensions.append("m4b")
        extensions.append("m4a")
        extensions.append("aac")
        extensions.append("flac")

        for i in range(len(extensions)):
            var candidate = (
                get_audio_cache_dir() + "/" + self.book_id + "." + extensions[i]
            )
            if path.exists(Path(candidate)):
                self.stream_source = candidate
                self.stream_is_local = True
                self.has_stream = False  # stream created on first PLAY
                return

        # 2) Use the Plex playback decision stream URL (HTTP). ffmpeg reads
        #    HTTP directly — no download needed for the streaming path.
        if len(self.tracks) > 0 and self.tracks[0].rating_key.byte_length() > 0:
            try:
                # Decision endpoint resolves by METADATA path (/library/metadata/N);
                # part paths (/library/parts/...) are rejected with 400 by PMS.
                var decision = get_playback_decision(
                    self.server_url,
                    self.token,
                    "/library/metadata/" + self.tracks[0].rating_key,
                    "quire-" + self.client_id,
                    self.client_id,
                )
                if decision.stream_url.byte_length() > 0:
                    # Append the Plex token to the stream URL so ffmpeg can
                    # authenticate without separate header handling for the
                    # query-string auth scheme.
                    var url = decision.stream_url
                    var sep = "?"
                    if url.find("?") >= 0:
                        sep = "&"
                    self.stream_source = (
                        url + sep + "X-Plex-Token=" + self.token
                    )
                    self.stream_is_local = False
                    self.has_stream = False
                    return
            except e:
                pass  # Decision endpoint unavailable — fall through.

        # 2b) Decision failed or returned nothing: stream the part file
        #     directly. Plex serves the raw file over HTTP at its part key;
        #     ffmpeg decodes any container/codec it holds (m4b, flac, ...).
        if len(self.tracks) > 0 and self.tracks[0].file_key.byte_length() > 0:
            var sep = "?"
            if self.tracks[0].file_key.find("?") >= 0:
                sep = "&"
            self.stream_source = (
                self.server_url
                + self.tracks[0].file_key
                + sep
                + "X-Plex-Token="
                + self.token
            )
            self.stream_is_local = False
            self.has_stream = False
            return

        # 3) Fallback: download the track to a local file. This blocks the UI
        #    but guarantees a playable source for formats ffmpeg can't stream.
        if len(self.tracks) > 0 and self.tracks[0].file_key.byte_length() > 0:
            var local_path = download_track(
                self.server_url,
                self.token,
                self.tracks[0].file_key,
                self.book_id,
                self.client_id,
            )
            if local_path.byte_length() > 0:
                self.stream_source = local_path
                self.stream_is_local = True
                self.has_stream = False
                return

        # No source available — playback will use time simulation.
        self.stream_source = ""
        self.stream_is_local = False
        self.has_stream = False

    def _build_stream_headers(mut self) -> Optional[List[HttpHeader]]:
        """Build the extra HTTP headers list for ffmpeg. The X-Plex-Token is
        already in the stream URL query string, so no extra headers are
        needed. Kept as a hook for future header injection."""
        return None

    def _start_stream(mut self, seek_s: Float64) raises -> Bool:
        """Spawn ffmpeg (via AudioPipe) and create the audio backend stream.
        Does NOT start playback — the caller decides when to start.
        Returns True if the stream is ready to be fed PCM."""
        if self.stream_source.byte_length() == 0:
            return False

        self._ensure_pipe()
        if not self.pipe_loaded:
            return False

        # Stop any existing stream + pipe before (re)starting.
        self._stop_stream()

        # Spawn ffmpeg reading the source at the requested seek + speed.
        var headers = self._build_stream_headers()
        try:
            if not self.pipe.start(
                self.stream_source,
                seek_s,
                self.speed,
                self.stream_is_local,
                headers,
            ):
                return False
        except:
            return False

        # Create the backend stream matching ffmpeg's output format:
        # 44100 Hz, 32-bit float, stereo.
        self.has_stream = self.audio_backend.create()
        if not self.has_stream:
            return False

        self.audio_backend.set_volume(self.volume)
        self.frames_fed_since_restart = 0
        return True

    def _restart_stream_at(mut self, seek_s: Float64) raises -> Bool:
        """Restart ffmpeg at a new position (seek) or speed. Keeps the same
        audio backend stream — we just pause it, respawn the pipe, and resume
        feeding PCM. Returns True on success."""
        if not self.pipe_loaded or self.stream_source.byte_length() == 0:
            return False

        try:
            if not self.pipe.restart(seek_s, self.speed):
                self.has_stream = False
                return False
        except:
            self.has_stream = False
            return False

        # If we don't have a backend stream yet (e.g. user changed speed
        # before first PLAY), create one now.
        if not self.has_stream:
            self.has_stream = self.audio_backend.create()
            if self.has_stream:
                self.audio_backend.set_volume(self.volume)

        self.frames_fed_since_restart = 0
        return self.has_stream

    def _stop_stream(mut self):
        """Stop the backend stream and terminate the ffmpeg pipe."""
        if self.has_stream:
            self.audio_backend.close()
            self.has_stream = False
        if self.pipe_loaded:
            self.pipe.stop()
        self.frames_fed_since_restart = 0

    def _load_cover(
        mut self, thumb_path: String, app_state: PlexSession
    ) raises:
        """Load cover art from the Plex thumbnail API.

        Fetched at COVER_PX so a full-window cover stays sharp on HiDPI;
        cached on disk at the requested size."""
        if self.cover_loaded:
            return

        if thumb_path.byte_length() == 0:
            self.cover_loaded = True
            return

        var token = app_state.server_token
        if token.byte_length() == 0:
            token = app_state.account_token

        var thumb_url = get_thumbnail_url(
            app_state.server_url,
            thumb_path,
            token,
            COVER_PX,
            COVER_PX,
        )

        if thumb_url.byte_length() == 0:
            self.cover_loaded = True
            return

        # Disk cache first — cached bytes work with no server at all.
        var image_data = load_cached_cover(self.book_id, COVER_PX, COVER_PX)
        # The HTTP fetch doubles as the cache fill; while the session is
        # known-offline it is skipped (placeholder renders instead, same
        # one-attempt-per-load bookkeeping via cover_loaded below).
        if image_data.byte_length() == 0 and not app_state.offline:
            image_data = fetch_thumbnail(thumb_url)
            save_cached_cover(self.book_id, COVER_PX, COVER_PX, image_data)

        if image_data.byte_length() == 0:
            self.cover_loaded = True
            return

        # Move the fetch temp into the decoder (ownership transfer).
        var decoded = imdecode(image_data^)
        self.cover_w = decoded.width
        self.cover_h = decoded.height

        # Bulk-copy RGBA pixels into the layout-allocated pixel buffer the
        # Canvas rasterizer blits directly (one memcpy, not n byte stores).
        var n = self.cover_w * self.cover_h * 4
        var layout = Layout[UInt8](count=n)
        var dst = alloc(layout).unsafe_leak()
        unsafe_memcpy(
            dest=Pointer[UInt8, MutUntrackedOrigin](
                unsafe_from_address=Int(dst)
            ),
            src=Pointer[UInt8, MutUntrackedOrigin](
                unsafe_from_address=Int(decoded.pixels.unsafe_ptr())
            ),
            count=n,
        )
        self.cover_pixels = Optional[Pointer[UInt8, MutUntrackedOrigin]](
            Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(dst))
        )

        self.has_cover = True

        self.cover_loaded = True

    def stop_and_unload_stream(mut self):
        """Stop the backend stream and terminate ffmpeg.

        Cover art is intentionally KEPT: the library's now-playing bar
        thumbnails it (self.cover_pixels[book_id]) for as long as a book is
        loaded, and reloading it on every player-screen entry would refetch
        + redecode ~600px of JPEG for no benefit. It is freed by load_book()
        (book swap) or deinit — not by leaving the player screen."""
        self.is_playing = False

        # DIAGNOSTIC: the forced progress push runs a Python (httpx) call
        # immediately before process teardown — bisecting the close crash
        # by removing it. The timer-based sync during playback already
        # reported the position; losing the final <15s of progress on a
        # quit is the acceptable cost of this experiment.
        # self._sync_progress(force=True)

        self._stop_stream()

        # Persist the resume point to the offline sidecar (no-op for books
        # without one) so an offline library reopen resumes here.
        try:
            update_saved_progress(self.book_id, Int(self.current_time * 1000.0))
        except:
            pass

    def handle_scroll(mut self, wheel_delta: Float32, screen_h: Int):
        """Scroll the chapter drawer (design-pixel space).

        Only the open chapter drawer scrolls; scrolling at any other time is
        a no-op. Uses the same shared drawer geometry draw() paints, so the
        scroll clamp can never disagree with the visible window."""
        if self.overlay_mode != OVERLAY_CHAPTERS or len(self.chapters) == 0:
            return

        var card = self._chapter_drawer_rect(
            Float64(DESIGN_W), Float64(screen_h)
        )
        var visible_height = (
            Float64(card.height) - DRAWER_TITLE_ROW - DRAWER_PAD_BOTTOM
        )
        var total_height = Float64(len(self.chapters)) * CHAPTER_ROW_H
        if total_height <= visible_height:
            self.chapter_scroll_offset = 0.0
            return

        self.chapter_scroll_offset += wheel_delta * 30.0
        var max_scroll = Float32(total_height - visible_height)
        if self.chapter_scroll_offset < 0.0:
            self.chapter_scroll_offset = 0.0
        elif self.chapter_scroll_offset > max_scroll:
            self.chapter_scroll_offset = max_scroll

    def _update_current_chapter(mut self):
        """Update current_chapter_idx based on current_time (seconds)."""
        self.current_chapter_idx = -1
        for i in range(len(self.chapters)):
            self.chapters[i].is_current = False

        var current_ms = Int(self.current_time * 1000.0)
        for i in range(len(self.chapters)):
            var chap = self.chapters[i]
            if current_ms >= chap.start_time_ms and (
                chap.end_time_ms <= 0 or current_ms < chap.end_time_ms
            ):
                self.current_chapter_idx = i
                self.chapters[i].is_current = True
                break

        var track_idx = self._find_current_track_index()
        if track_idx >= 0 and track_idx < len(self.tracks):
            if (
                self.tracks[track_idx].rating_key
                != self.current_track_rating_key
            ):
                self.current_track_rating_key = self.tracks[
                    track_idx
                ].rating_key

    def _chapter_start_sec(self) -> Float64:
        """Start time (seconds) of the current chapter, or 0.0."""
        if self.current_chapter_idx < 0 or self.current_chapter_idx >= len(
            self.chapters
        ):
            return 0.0
        return (
            Float64(self.chapters[self.current_chapter_idx].start_time_ms)
            / 1000.0
        )

    def _chapter_end_sec(self) -> Float64:
        """End time (seconds) of the current chapter, or whole-book duration."""
        if self.current_chapter_idx < 0 or self.current_chapter_idx >= len(
            self.chapters
        ):
            return self.duration
        var chap = self.chapters[self.current_chapter_idx]
        var end_ms = chap.end_time_ms
        if end_ms <= 0:
            end_ms = Int(self.duration * 1000.0)
        var end_sec = Float64(end_ms) / 1000.0
        if end_sec <= self._chapter_start_sec():
            return self.duration
        return end_sec

    def _find_current_track_index(mut self) -> Int:
        """Find the index of the track that contains the current playback position.
        """
        if len(self.tracks) == 0:
            return -1

        var current_ms = Int(self.current_time * 1000.0)
        var cumulative_ms = 0
        for i in range(len(self.tracks)):
            var track = self.tracks[i]
            if current_ms < cumulative_ms + track.duration_ms:
                return i
            cumulative_ms = cumulative_ms + track.duration_ms

        return len(self.tracks) - 1

    def toggle_playback(mut self) raises:
        """Toggle play/pause. Mirrors the player screen's play/pause button:
        first PLAY after load spawns the stream, later toggles resume/pause.

        Public so other screens (library now-playing bar) can control
        playback without duplicating backend wiring.
        """
        self.is_playing = not self.is_playing
        if self.is_playing:
            # First PLAY after load: spawn ffmpeg + create the backend
            # stream, then start playback. Subsequent plays just resume.
            if not self.has_stream:
                var ok = self._start_stream(self.current_time)
                if ok:
                    self.audio_backend.play()
            else:
                self.audio_backend.play()
        else:
            if self.has_stream:
                self.audio_backend.pause()
        # A play/pause press is a deliberate state change — flush the
        # position now instead of waiting out the 15s timer.
        self._sync_progress(force=True)

    def _sync_progress(mut self, force: Bool = False):
        """Report playback progress to the Plex server (best-effort).

        force=True bypasses the 15s timer — used when the player is being
        torn down (screen exit), so the final position always lands."""
        if self.server_url.byte_length() == 0 or self.token.byte_length() == 0:
            return
        if self.current_track_rating_key.byte_length() == 0:
            return
        if not force and self.progress_sync_timer < self.progress_sync_interval:
            return

        var pushed = False
        try:
            # Compute offset relative to the current track, not the whole book.
            # Plex expects `time` as the position within the specific track
            # (rating_key), and `duration` as that track's duration.
            var track_idx = self._find_current_track_index()
            var time_ms = Int(self.current_time * 1000.0)
            var track_duration_ms = Int(self.duration * 1000.0)
            if track_idx >= 0 and track_idx < len(self.tracks):
                var offset_into_track_ms = 0
                for i in range(track_idx):
                    offset_into_track_ms += self.tracks[i].duration_ms
                time_ms = time_ms - offset_into_track_ms
                if time_ms < 0:
                    time_ms = 0
                track_duration_ms = self.tracks[track_idx].duration_ms

            var state = "stopped"
            if self.is_playing:
                state = "playing"
            elif self.current_time > 0.0:
                state = "paused"

            var pq_item_id = self.play_queue_items.get(
                self.current_track_rating_key, 0
            )

            var track_key = "/library/metadata/" + self.current_track_rating_key

            pushed = report_progress(
                self.server_url,
                self.token,
                self.current_track_rating_key,
                track_key,
                time_ms,
                track_duration_ms,
                state,
                pq_item_id,
                self.client_id,
            )
        except:
            pass

        # Reset the timer on success; on a failed push (down server), park
        # the timer just below the threshold so the next attempt comes
        # progress_sync_retry_delay of accumulated dt later — a retry
        # every 1s instead of the per-frame blocking HTTP a hiccup used
        # to produce. Deliberate state changes still force a push
        # (toggle_playback → force=True bypasses the timer).
        if pushed:
            self.progress_sync_timer = 0.0
        else:
            var retry_at = (
                self.progress_sync_interval - self.progress_sync_retry_delay
            )
            if retry_at < 0.0:
                retry_at = 0.0
            self.progress_sync_timer = retry_at

    def _mark_track_watched(mut self):
        """Mark the current track as watched on the Plex server (best-effort).
        """
        if self.server_url.byte_length() == 0 or self.token.byte_length() == 0:
            return
        if self.current_track_rating_key.byte_length() == 0:
            return

        try:
            _ = mark_watched(
                self.server_url,
                self.token,
                self.current_track_rating_key,
                self.client_id,
            )
        except:
            pass

    def reset_progress(mut self) raises:
        """Reset the whole book's progress and push it to Plex.

        Unscrobbles every track (clears the watched flags) and reports a
        zero position on the current track, so the album-level progress
        (viewOffset/viewedLeafCount) returns to Not Started. Local state
        rewinds to 0:00 — but playback is NOT started here; the caller
        decides whether to resume playing.
        """
        if self.server_url.byte_length() == 0 or self.token.byte_length() == 0:
            return

        # Stop feeding audio first — a live ffmpeg stream would keep
        # advancing current_time and the next _sync_progress would push
        # the old position right back.
        var was_playing = self.is_playing
        self.is_playing = False
        if self.has_stream:
            self.audio_backend.pause()

        # 1) Clear watched on every track (unscrobble is idempotent — a
        #    track that was never watched just no-ops).
        for i in range(len(self.tracks)):
            try:
                _ = mark_unwatched(
                    self.server_url,
                    self.token,
                    self.tracks[i].rating_key,
                    self.client_id,
                )
            except:
                pass

        # 2) Zero the position on the current track so the album-level
        #    viewOffset clears too.
        if self.current_track_rating_key.byte_length() > 0:
            var track_idx = self._find_current_track_index()
            var track_duration_ms = Int(self.duration * 1000.0)
            if track_idx >= 0 and track_idx < len(self.tracks):
                track_duration_ms = self.tracks[track_idx].duration_ms
            var track_key = "/library/metadata/" + self.current_track_rating_key
            var pq_item_id = self.play_queue_items.get(
                self.current_track_rating_key, 0
            )
            try:
                _ = report_progress(
                    self.server_url,
                    self.token,
                    self.current_track_rating_key,
                    track_key,
                    0,  # time: back to the start
                    track_duration_ms,
                    "stopped",
                    pq_item_id,
                    self.client_id,
                )
            except:
                pass

        # 3) Rewind local state.
        self.current_time = 0.0
        self.frames_fed_since_restart = 0
        self.progress_sync_timer = 0.0
        self._update_current_chapter()

        # Rewind the local mirror of track progress so a same-session
        # re-open of this book resumes from 0 without a server round-trip.
        for i in range(len(self.tracks)):
            self.tracks[i].view_offset_ms = 0

        # If the user was listening, restart the stream at 0:00.
        if was_playing and self.has_stream:
            var ok = self._restart_stream_at(0.0)
            if ok:
                self.audio_backend.play()
                self.is_playing = True

    def _previous_chapter(mut self):
        """Go to the previous chapter, or restart current if >3s in."""
        if len(self.chapters) == 0:
            return
        if self.current_chapter_idx < 0:
            self.current_chapter_idx = 0
            self.current_time = Float64(self.chapters[0].start_time_ms) / 1000.0
            self._update_current_chapter()
            return
        var current_chapter = self.chapters[self.current_chapter_idx]
        var chap_start_sec = Float64(current_chapter.start_time_ms) / 1000.0
        if self.current_time - chap_start_sec > 3.0:
            self.current_time = chap_start_sec
        elif self.current_chapter_idx > 0:
            self.current_chapter_idx -= 1
            self.current_time = (
                Float64(self.chapters[self.current_chapter_idx].start_time_ms)
                / 1000.0
            )
        else:
            self.current_time = 0.0
        self._update_current_chapter()

    def _next_chapter(mut self):
        """Go to the next chapter."""
        if len(self.chapters) == 0:
            return
        if self.current_chapter_idx < len(self.chapters) - 1:
            self.current_chapter_idx += 1
            self.current_time = (
                Float64(self.chapters[self.current_chapter_idx].start_time_ms)
                / 1000.0
            )
        else:
            self.current_time = self.duration
        self._update_current_chapter()

    def _seek_to_current(mut self) raises:
        """Restart the ffmpeg pipe at self.current_time. Called after any
        seek operation (chapter nav, ±30s, progress bar release). If playback
        hasn't started yet (no stream), this is a no-op — the next PLAY will
        spawn ffmpeg at the current position."""
        if not self.has_stream or not self.pipe_loaded:
            return
        var was_playing = self.is_playing
        if was_playing:
            self.audio_backend.pause()
        var ok = self._restart_stream_at(self.current_time)
        if ok and was_playing:
            self.audio_backend.play()

    def _set_overlay(mut self, mut ui: UIContext, mode: Int):
        """Open one overlay (or close everything). Mutually exclusive.

        Reopening the same mode closes it — a toggle, so a rail icon is its
        own dismiss control. Switching modes resets the slide animation
        (instant appearance of the new panel) and drops the spatial-nav
        focus (the node set changes completely under the new panel)."""
        if self.overlay_mode == mode:
            self.overlay_mode = OVERLAY_NONE
        else:
            self.overlay_mode = mode
        self.overlay_armed = True
        self.chapter_scroll_offset = 0.0
        ui.nav_reset()

    def _skip(mut self, seconds: Float64) raises:
        """Skip by signed seconds, clamped and streamed consistently."""
        self.current_time = self.current_time + seconds
        if self.current_time < 0.0:
            self.current_time = 0.0
        if self.current_time > self.duration:
            self.current_time = self.duration
        self._update_current_chapter()
        self._seek_to_current()

    def _skip_30_back(mut self) raises:
        self._skip(-SKIP_SECONDS)

    def _skip_30_forward(mut self) raises:
        self._skip(SKIP_SECONDS)

    def _speed_label(self) -> String:
        """Return the display label for the current playback speed.
        Formats to 2 decimal places (e.g. '1.05x', '0.50x', '2.00x')."""
        var whole = Int(self.speed)
        var frac = self.speed - Float64(whole)
        # Two-digit fractional part, rounded to nearest 0.05.
        var frac_hundred = Int((frac * 100.0) + 0.5)
        var d1 = frac_hundred // 10
        var d2 = frac_hundred % 10
        return String(whole) + "." + String(d1) + String(d2) + "x"

    def _change_speed(mut self, delta: Float64) raises:
        """Adjust speed by `delta` in 0.05 increments, clamped to [0.5, 2.0].
        Pitch-correct: restarts ffmpeg with a new atempo filter rather than
        shifting pitch."""
        var new_speed = self.speed + delta
        # Round to nearest 0.05 to avoid float drift from repeated taps.
        new_speed = new_speed * 20.0 + 0.5
        new_speed = Float64(Int(new_speed)) / 20.0
        if new_speed < 0.5:
            new_speed = 0.5
        if new_speed > 2.0:
            new_speed = 2.0
        if new_speed == self.speed:
            return
        self.speed = new_speed
        # Restart the ffmpeg pipe at the current position with the new speed.
        # atempo requires a fresh process. Latency ~100-300ms (acceptable).
        if self.has_stream and self.pipe_loaded:
            var was_playing = self.is_playing
            if was_playing:
                self.audio_backend.pause()
            var ok = self._restart_stream_at(self.current_time)
            if ok and was_playing:
                self.audio_backend.play()
                self.is_playing = True
            elif not ok:
                self.has_stream = False

    def update_playback(mut self, dt: Float64) raises:
        """Per-frame playback update — called from the main loop.
        Pulls PCM from the ffmpeg pipe and feeds the audio backend's ring
        buffer. Advances normalized playback time from frames fed (not
        wall-clock, since atempo already changed the audio rate). Handles
        end-of-stream."""
        if not self.has_stream:
            # No active stream — fall back to time simulation when playing.
            if self.is_playing and self.duration > 0.0:
                self.current_time = self.current_time + dt * self.speed
                if self.current_time >= self.duration:
                    self.current_time = self.duration
                    self.is_playing = False
                    self._mark_track_watched()
                self._update_current_chapter()
            return

        # The backend's ring buffer absorbs jitter; feed it whenever there is
        # room for another chunk. When needs_data() returns False, the writer
        # thread still has a chunk's worth of PCM queued.
        if self.audio_backend.needs_data():
            # Pull one chunk of PCM from the native pipe. read_chunk()
            # returns typed f32 samples + frame count; has_data() gates use
            # (AudioPipe owns the memory).
            var chunk: ChunkResult
            try:
                chunk = self.pipe.read_chunk()
            except:
                chunk = ChunkResult()
            if chunk.has_data():
                self.audio_backend.write_pcm(chunk.samples, chunk.frame_count)
                # Advance normalized time by the frames actually fed. This is
                # wall-clock playback time (atempo already resampled the audio).
                self.frames_fed_since_restart = (
                    self.frames_fed_since_restart + chunk.frame_count
                )
                if not self.progress_dragging:
                    self.current_time = self.current_time + (
                        Float64(chunk.frame_count) / 44100.0
                    )

        # End-of-stream: ffmpeg exited and the pipe hit EOF.
        if self.pipe.reached_end() and not self.progress_dragging:
            if self.frames_fed_since_restart > 0:
                # Real end of audio: snap to the book's end and mark watched.
                self.is_playing = False
                self.current_time = self.duration
                self._mark_track_watched()
            else:
                # ffmpeg exited without producing ANY audio (seek past EOF,
                # dead URL, bad container). Treating that as "finished" is
                # how a book got permanently stuck at the end. Fail loud:
                # keep the position, stop, and surface the error.
                self.is_playing = False
                self.has_stream = False
                print(
                    "[player] stream ended with no audio at "
                    + String(self.current_time)
                    + "s — source likely bad; not marking watched"
                )

        self._update_current_chapter()

    def draw(
        mut self,
        mut ui: UIContext,
        mut screen: Screen,
    ) raises:
        """Render the layout1 player screen (assets/quire-layout1.png).

        Single-pass immediate mode: layout, input, and drawing share the same
        rectangles. Paint order matters — the cover is drawn FIRST and the
        controls last, so narrow windows that push the cover under the
        rails still leave every control visible/clickable:
          cover    — centered art (bottom layer)
          header   — back chevron, centered title, stub icons top-right
          bottom   — book bar, then chapter bar with < > skip flanks
          rails    — left toggles, right ±30s / play (must survive squish)
          overlays — floating panels on top of everything
        """
        var sw_design = Float64(ui.screen_w) / Float64(ui.ui_scale)
        var sh_design = Float64(ui.screen_h) / Float64(ui.ui_scale)

        # While an overlay is open the rails are covered by the floating
        # panel — skip them so hidden controls can't be clicked through it.
        var overlay_open = self.overlay_mode != OVERLAY_NONE

        # Compute the bottom-bar zone early so the cover can avoid it.
        var bottom_top = self._bottom_bars_top(sw_design, sh_design)
        self._draw_cover(ui, sw_design, sh_design, bottom_top)

        self._draw_header(ui, sw_design, screen)
        self._draw_bottom_bars(ui, sw_design, sh_design)
        if not overlay_open:
            self._draw_left_rail(ui, sw_design, bottom_top)
            self._draw_right_rail(ui, sw_design, bottom_top)

        # Floating panels on top of everything; also handle click-outside.
        self._draw_overlays(ui, sw_design, sh_design)

    # ------------------------------------------------------------------
    # Header — back chevron, centered title, stub icons top-right
    # ------------------------------------------------------------------

    def _draw_header(
        mut self,
        mut ui: UIContext,
        sw_design: Float64,
        mut screen: Screen,
    ) raises:
        """Top bar: back chevron (left), centered title, stub icons (right).

        The stub icons render but are not yet wired — global settings and
        listening history are future work. They are drawn dimmed so the
        clickable (back) control stays visually distinct.
        """
        var margin = 24.0

        # Back chevron — ghost button top-left.
        var back_size = 88.0
        var back_result = ui.button_at(
            ICON_CHEV_LEFT,
            margin,
            10.0,
            back_size,
            back_size,
            PLAYER_BG,
            TEXT_LIGHT,
            Color(30, 60, 74, 255),
            action="back_button",
        )
        if back_result.clicked:
            self.stop_and_unload_stream()
            screen.current = 1
            return

        # Centered title (layout1 mock: bold page-style title).
        var title = self.book_title
        if title.byte_length() == 0:
            title = "Now Playing"
        var title_size = 26
        var title_meas = ui._measure_text(title, title_size)
        var max_title_w = sw_design * 0.62
        if title_meas.x > Float32(max_title_w) * ui.font_scale:
            var max_chars = Int(max_title_w / 12.0)
            if max_chars < 8:
                max_chars = 8
            title = truncate_string(title, max_chars - 3) + "..."
            title_meas = ui._measure_text(title, title_size)
        var title_x = (sw_design - ui.text_w_design(title_meas.x)) / 2.0
        ui.move_to(title_x, 24.0)
        ui.label(title, title_size, TEXT_BRIGHT)

        # Top-right stubs — global settings + history (not implemented).
        # Not focusable (region -1): dead controls must not collect a
        # spatial-nav walk in the header.
        var stub_size = 80.0
        var stub_y = 8.0
        var stub_gap = 16.0
        var stubs_x = sw_design - margin - 2.0 * stub_size - stub_gap
        var list_stub = ui.button_at(
            ICON_LIST,
            stubs_x,
            stub_y,
            stub_size,
            stub_size,
            PLAYER_BG,
            TEXT_DIM,
            Color(30, 60, 74, 255),
            region=-1,
        )
        var head_x = stubs_x + stub_size + stub_gap
        var headphones_stub = ui.button_at(
            ICON_HEADPHONES,
            head_x,
            stub_y,
            stub_size,
            stub_size,
            PLAYER_BG,
            TEXT_DIM,
            Color(30, 60, 74, 255),
            region=-1,
        )
        if list_stub.clicked or headphones_stub.clicked:
            pass  # stubs: global settings / history — wired in a later pass

    # ------------------------------------------------------------------
    # Bottom bars — book progress (upper), chapter progress (lower, flanked)
    # ------------------------------------------------------------------

    # ------------------------------------------------------------------
    # Bottom bars — book progress (upper), chapter progress (lower, flanked)
    # ------------------------------------------------------------------

    def _bottom_bars_top(
        self, sw_design: Float64, sh_design: Float64
    ) -> Float64:
        """Design-px y where the bottom-bars zone begins (upper bar's top).

        Shared by draw() and _draw_cover so the cover can stop above the
        bars without duplicating the geometry constants."""
        var margin = 28.0
        var bar_h = 12.0
        var bar_gap = 40.0
        var skip_h = 112.0
        var lower_y = sh_design - margin - skip_h - bar_gap
        return lower_y - bar_gap - bar_h

    def _draw_bottom_bars(
        mut self, mut ui: UIContext, sw_design: Float64, sh_design: Float64
    ) raises:
        """Two seek bars at the window bottom.

        Upper bar = whole-book progress. Lower bar = position inside the
        current chapter, flanked by < > chapter-skip chevrons. Time labels
        sit between the bars: elapsed / remaining on the book bar.
        """
        var margin = 28.0
        var bar_h = 12.0
        var bar_gap = 40.0
        var label_h = 26.0
        var skip_w = 112.0
        var skip_h = 112.0

        var lower_y = sh_design - margin - skip_h - bar_gap
        var upper_y = lower_y - bar_gap - bar_h
        var upper_w = sw_design * 0.60
        var upper_x = (sw_design - upper_w) / 2.0

        # --- Book progress bar (upper, shorter, centered) ---
        var book_result = ui.slider(
            upper_x,
            upper_y,
            upper_w,
            bar_h,
            self.current_time,
            0.0,
            max(self.duration, 1.0),
        )
        if book_result.clicked:
            self.progress_dragging = True
        if self.progress_dragging and ui.mouse_down:
            self.current_time = ui.slider_value_from_mouse(
                book_result.bounds, ui.mouse_pos.x, 0.0, self.duration
            )
            self._update_current_chapter()
        elif not ui.mouse_down:
            if self.progress_dragging and self.has_stream and self.pipe_loaded:
                var was_playing = self.is_playing
                if was_playing:
                    self.audio_backend.pause()
                var ok = self._restart_stream_at(self.current_time)
                if ok and was_playing:
                    self.audio_backend.play()
            self.progress_dragging = False

        # Elapsed / remaining labels tucked between the bars (book tracker,
        # right-aligned to the upper bar).
        var label_size = 16
        var time_text = (
            format_time(self.current_time)
            + "  /  "
            + format_time(max(self.duration - self.current_time, 0.0))
        )
        var time_meas = ui._measure_text(time_text, label_size)
        ui.move_to(
            upper_x + upper_w - ui.text_w_design(time_meas.x),
            upper_y - label_h - 8.0,
        )
        ui.label(time_text, label_size, TEXT_MUTED)

        # --- Chapter bar (lower, centered, chevron flanks) ---
        var chap_x = margin + skip_w + 32.0
        var chap_w = sw_design - 2.0 * (margin + skip_w + 32.0)
        var chap_y = lower_y

        var chap_start = self._chapter_start_sec()
        var chap_end = self._chapter_end_sec()
        var chap_dur = chap_end - chap_start
        if chap_dur < 0.0:
            chap_dur = 0.0
        var chap_pos = self.current_time - chap_start
        if chap_pos < 0.0:
            chap_pos = 0.0
        if chap_pos > chap_dur:
            chap_pos = chap_dur

        # Chapter tracker: elapsed / total for this chapter, right-aligned
        # above the chapter bar (mirrors the book tracker's placement).
        var chap_text = format_time(chap_pos) + "  /  " + format_time(chap_dur)
        var chap_time_meas = ui._measure_text(chap_text, label_size)
        ui.move_to(
            chap_x + chap_w - ui.text_w_design(chap_time_meas.x),
            chap_y - label_h - 8.0,
        )
        ui.label(chap_text, label_size, TEXT_MUTED)

        var chap_result = ui.slider(
            chap_x,
            chap_y,
            chap_w,
            bar_h,
            chap_pos,
            0.0,
            max(chap_dur, 0.001),
        )
        if chap_result.clicked:
            self.chapter_dragging = True
        if self.chapter_dragging and ui.mouse_down:
            var new_pos = ui.slider_value_from_mouse(
                chap_result.bounds, ui.mouse_pos.x, 0.0, chap_dur
            )
            self.current_time = chap_start + new_pos
            if self.current_time < 0.0:
                self.current_time = 0.0
            if self.current_time > self.duration:
                self.current_time = self.duration
            self._update_current_chapter()
        elif not ui.mouse_down:
            if self.chapter_dragging and self.has_stream and self.pipe_loaded:
                var was_playing = self.is_playing
                if was_playing:
                    self.audio_backend.pause()
                var ok = self._restart_stream_at(self.current_time)
                if ok and was_playing:
                    self.audio_backend.play()
            self.chapter_dragging = False

        # < > chapter-skip chevrons flanking the lower bar.
        var chev_y = chap_y + bar_h / 2.0 - skip_h / 2.0
        var prev_result = ui.button_at(
            ICON_CHEV_LEFT,
            margin,
            chev_y,
            skip_w,
            skip_h,
            PLAYER_BG,
            TEXT_LIGHT,
            Color(30, 60, 74, 255),
            action="prev_chapter",
        )
        if prev_result.clicked:
            self._previous_chapter()
            self._seek_to_current()

        var next_result = ui.button_at(
            ICON_CHEV_RIGHT,
            sw_design - margin - skip_w,
            chev_y,
            skip_w,
            skip_h,
            PLAYER_BG,
            TEXT_LIGHT,
            Color(30, 60, 74, 255),
            action="next_chapter",
        )
        if next_result.clicked:
            self._next_chapter()
            self._seek_to_current()

    def _draw_left_rail(
        mut self, mut ui: UIContext, sw_design: Float64, bottom_top: Float64
    ) raises:
        """Vertical stack of mode toggles on the left edge, vertically
        centered between the header and the bottom bars."""
        var margin = 24.0
        var btn = 88.0
        var gap = 36.0
        var rail_x = margin
        var rail_top = 140.0

        var rail_bottom = bottom_top - 40.0
        var n = 3
        var block_h = Float64(n) * btn + Float64(n - 1) * gap
        var rail_y = rail_top + (rail_bottom - rail_top - block_h) / 2.0

        # Layers → chapter drawer
        var layers_result = ui.button_at(
            ICON_LAYERS,
            rail_x,
            rail_y,
            btn,
            btn,
            PLAYER_BG,
            TEXT_LIGHT,
            Color(30, 60, 74, 255),
        )
        if layers_result.clicked:
            self._set_overlay(ui, OVERLAY_CHAPTERS)

        # Sliders → settings popover (speed + volume)
        var tune_y = rail_y + btn + gap
        var tune_result = ui.button_at(
            ICON_TUNE,
            rail_x,
            tune_y,
            btn,
            btn,
            PLAYER_BG,
            TEXT_LIGHT,
            Color(30, 60, 74, 255),
        )
        if tune_result.clicked:
            self._set_overlay(ui, OVERLAY_SETTINGS)

        # Info → book details popover
        var info_y = rail_y + 2.0 * (btn + gap)
        var info_result = ui.button_at(
            ICON_INFO,
            rail_x,
            info_y,
            btn,
            btn,
            PLAYER_BG,
            TEXT_LIGHT,
            Color(30, 60, 74, 255),
        )
        if info_result.clicked:
            self._set_overlay(ui, OVERLAY_INFO)

    # ------------------------------------------------------------------
    # Right rail — ±30s skips and circled play/pause
    # ------------------------------------------------------------------

    def _draw_right_rail(
        mut self, mut ui: UIContext, sw_design: Float64, bottom_top: Float64
    ) raises:
        """Skip + play stack on the right edge, mirroring the left rail."""
        var margin = 24.0
        var btn = 88.0
        var play_btn = 128.0
        var gap = 52.0
        var rail_x = sw_design - margin - play_btn
        var rail_top = 140.0
        var rail_bottom = bottom_top - 40.0
        var block_h = 2.0 * btn + play_btn + 2.0 * gap
        var rail_y = rail_top + (rail_bottom - rail_top - block_h) / 2.0

        # << −30s
        var back30_result = ui.button_at(
            ICON_SKIP_BACK,
            rail_x,
            rail_y,
            btn,
            btn,
            PLAYER_BG,
            TEXT_LIGHT,
            Color(30, 60, 74, 255),
            action="skip_back",
        )
        if back30_result.clicked:
            self._skip_30_back()

        # Circled play / pause (the mock's encircled triangle).
        var play_label = ICON_PLAY
        if self.is_playing:
            play_label = ICON_PAUSE_CIRCLE
        var play_result = ui.button_at(
            play_label,
            rail_x,
            rail_y + btn + gap,
            play_btn,
            play_btn,
            PLAYER_BG,
            GREEN,
            Color(60, 90, 104, 255),
            action="play_pause",
        )
        if play_result.clicked:
            self.toggle_playback()

        # >> +30s
        var fwd30_result = ui.button_at(
            ICON_SKIP_FORWARD,
            rail_x,
            rail_y + btn + gap + play_btn + gap,
            btn,
            btn,
            PLAYER_BG,
            TEXT_LIGHT,
            Color(30, 60, 74, 255),
            action="skip_forward",
        )
        if fwd30_result.clicked:
            self._skip_30_forward()

    # ------------------------------------------------------------------
    # Cover art — centered in the free space
    # ------------------------------------------------------------------

    def _draw_cover(
        mut self,
        mut ui: UIContext,
        sw_design: Float64,
        sh_design: Float64,
        bottom_top: Float64,
    ):
        """Blit the cover centered between header and bottom bars.

        Painted FIRST (bottom layer) — rails and bars draw over it when a
        narrow window forces overlap, so controls stay visible/clickable.
        The `side` cap keeps the art clear of the rails where space allows.
        """
        var header_h = 92.0
        var top = header_h + 20.0
        var bottom = bottom_top - 40.0
        var box_h = bottom - top

        var side = box_h
        if side > sw_design - 2.0 * 24.0:
            side = sw_design - 2.0 * 24.0
        if side < 80.0:
            side = 80.0
        var cover_x = (sw_design - side) / 2.0
        var cover_y = top + (box_h - side) / 2.0
        _ = sh_design

        if self.has_cover:
            var cover_h_safe = self.cover_h
            if cover_h_safe < 1:
                cover_h_safe = 1
            var aspect = Float64(self.cover_w) / Float64(cover_h_safe)
            var dst_w = side
            var dst_h = side
            if aspect >= 1.0:
                dst_h = side / aspect
            else:
                dst_w = side * aspect
            var scale = Float64(ui.ui_scale)
            ui.canvas().blit_rgba(
                self.cover_pixels.value(),
                self.cover_w,
                self.cover_h,
                self.cover_w * 4,
                cover_x * scale,
                cover_y * scale,
                dst_w * scale,
                dst_h * scale,
            )
        else:
            ui.card(
                cover_x, cover_y, side, side, PLACEHOLDER_BG, roundness=0.08
            )
            var cover_icon = "COVER"
            var icon_meas = ui._measure_text(cover_icon, 48)
            var icon_x = cover_x + (side - ui.text_w_design(icon_meas.x)) / 2.0
            var icon_y = cover_y + (side - ui.text_h_design(icon_meas.y)) / 2.0
            ui.move_to(icon_x, icon_y)
            ui.label(cover_icon, 48, TEXT_DIM)

    # ------------------------------------------------------------------
    # Overlays — chapter drawer, settings popover, info popover
    # ------------------------------------------------------------------

    def _draw_overlays(
        mut self,
        mut ui: UIContext,
        sw_design: Float64,
        sh_design: Float64,
    ) raises:
        """Mutually exclusive floating panels + click-outside-to-close.

        `overlay_armed` prevents the same click that opened a panel from
        instantly closing it (the toggle button click would otherwise land
        on the click-outside guard the same frame)."""
        if self.overlay_mode == OVERLAY_NONE:
            return

        if ui.mouse_pressed and not self.overlay_armed:
            if not self._pointer_in_active_panel(ui, sw_design, sh_design):
                self.overlay_mode = OVERLAY_NONE
                return

        self.overlay_armed = False

        if self.overlay_mode == OVERLAY_CHAPTERS:
            self._draw_chapter_drawer(ui, sw_design, sh_design)
        elif self.overlay_mode == OVERLAY_SETTINGS:
            self._draw_settings_popover(ui, sw_design, sh_design)
        elif self.overlay_mode == OVERLAY_INFO:
            self._draw_info_popover(ui, sw_design, sh_design)

    def _pointer_in_active_panel(
        self, mut ui: UIContext, sw_design: Float64, sh_design: Float64
    ) -> Bool:
        """True if the cursor is inside the currently open overlay panel."""
        var card = self._active_panel_rect(sw_design, sh_design)
        return ui._hit(card)

    def _active_panel_rect(
        self, sw_design: Float64, sh_design: Float64
    ) -> Rect:
        """Design-px rect of the open overlay (chapter drawer OR popovers)."""
        if self.overlay_mode == OVERLAY_CHAPTERS:
            return self._chapter_drawer_rect(sw_design, sh_design)
        return self._popover_rect(sw_design, sh_design)

    def _chapter_drawer_rect(
        self, sw_design: Float64, sh_design: Float64
    ) -> Rect:
        """Geometry of the left chapter drawer (design px)."""
        var margin = 20.0
        var bottom = sh_design - 120.0
        if bottom - DRAWER_TOP < DRAWER_MIN_H:
            bottom = DRAWER_TOP + DRAWER_MIN_H
            if bottom > sh_design:
                bottom = sh_design
        var usable = sw_design - 2.0 * margin
        var w = DRAWER_W
        if w > usable:
            w = usable
        return Rect(margin, DRAWER_TOP, w, bottom - DRAWER_TOP)

    def _popover_rect(self, sw_design: Float64, sh_design: Float64) -> Rect:
        """Geometry shared by the settings and info popovers (left-anchored)."""
        var margin = 20.0
        var w = 380.0
        var bottom = sh_design - 120.0
        if bottom - DRAWER_TOP < DRAWER_MIN_H:
            bottom = DRAWER_TOP + DRAWER_MIN_H
            if bottom > sh_design:
                bottom = sh_design
        var usable = sw_design - 2.0 * margin
        if w > usable:
            w = usable
        return Rect(margin, DRAWER_TOP, w, bottom - DRAWER_TOP)

    def _draw_chapter_drawer(
        mut self, mut ui: UIContext, sw_design: Float64, sh_design: Float64
    ) raises:
        """Slide-out chapter list on the left (scrollable, click to seek)."""
        var card = self._chapter_drawer_rect(sw_design, sh_design)
        var x = Float64(card.x)
        var y = Float64(card.y)
        var w = Float64(card.width)
        var h = Float64(card.height)

        ui.card(x, y, w, h, CARD_BG, roundness=0.03)

        # Drawer title + close button.
        ui.move_to(x + 24.0, y + 18.0)
        ui.label("Chapters", 22, TEXT_BRIGHT)

        var close_btn = 36.0
        var close_result = ui.button_at(
            ICON_CLOSE,
            x + w - close_btn - 14.0,
            y + 12.0,
            close_btn,
            close_btn,
            CARD_BG,
            TEXT_DIM,
            Color(30, 60, 74, 255),
        )
        if close_result.clicked:
            self.overlay_mode = OVERLAY_NONE
            ui.nav_reset()
            return

        # Scrollable chapter rows.
        if len(self.chapters) == 0:
            ui.move_to(x + 24.0, y + 70.0)
            ui.label("No chapters", 18, TEXT_DIM)
            return

        var list_top = y + DRAWER_TITLE_ROW
        var list_h = h - DRAWER_TITLE_ROW - DRAWER_PAD_BOTTOM
        var chap_h = CHAPTER_ROW_H

        # Scroll region for the spatial-nav engine: the chapter rows are
        # nav region 1 of this screen; the hint lets a held dpad scroll
        # the drawer instead of escaping into the close button.
        var nav_scroll_design = Float64(self.chapter_scroll_offset) / Float64(
            ui.ui_scale
        )
        var nav_total = Float64(len(self.chapters)) * Float64(chap_h)
        ui.nav_scroll_hint(
            1,
            nav_scroll_design > 0.5,
            (nav_total - nav_scroll_design) > Float64(list_h) + 0.5,
        )
        if ui.nav_scroll_edge(1, NAV_DOWN):
            self.chapter_scroll_offset = Float32(
                Float64(self.chapter_scroll_offset)
                + Float64(chap_h) * Float64(ui.ui_scale)
            )
            var max_scroll = Float32(nav_total - Float64(list_h))
            if self.chapter_scroll_offset > max_scroll:
                self.chapter_scroll_offset = max_scroll
        elif ui.nav_scroll_edge(1, NAV_UP):
            self.chapter_scroll_offset = Float32(
                Float64(self.chapter_scroll_offset)
                - Float64(chap_h) * Float64(ui.ui_scale)
            )
            if self.chapter_scroll_offset < 0.0:
                self.chapter_scroll_offset = 0.0

        ui.begin_clip(x, list_top, w, list_h)

        var scroll_design = Float64(self.chapter_scroll_offset) / Float64(
            ui.ui_scale
        )
        var row_y = list_top - scroll_design

        for i in range(len(self.chapters)):
            var chap = self.chapters[i]
            if row_y + chap_h < list_top:
                row_y += chap_h
                continue
            if row_y > list_top + list_h:
                break

            # Highlight only the current chapter (canvas has no alpha
            # compositing — "transparent" simply means don't paint).
            if chap.is_current:
                var row_rect = ui.rect(x + 10.0, row_y, w - 20.0, chap_h - 6.0)
                ui.canvas().fill_rect(
                    Float64(row_rect.x),
                    Float64(row_rect.y),
                    Float64(row_rect.width),
                    Float64(row_rect.height),
                    CHAPTER_HIGHLIGHT,
                )

            # Chapter number.
            var ch_num = String(chap.index)
            ui.move_to(x + 22.0, row_y + 10.0)
            ui.label(ch_num, 16, GREEN if chap.is_current else TEXT_DIM)

            # Chapter title (truncated to the row's free width; time column
            # reserves ~120 design px on the right).
            var title_x = x + 60.0
            var max_title_w = w - 60.0 - 130.0
            var chap_title = chap.tag
            var title_meas = ui._measure_text(chap_title, 14)
            if title_meas.x > Float32(max_title_w) * ui.font_scale:
                var max_chars = Int(max_title_w / 8.0)
                if max_chars > 3:
                    chap_title = (
                        truncate_string(chap_title, max_chars - 3) + "..."
                    )
                else:
                    chap_title = truncate_string(chap_title, max_chars)
            ui.move_to(title_x, row_y + 9.0)
            var title_color = TEXT_BRIGHT if chap.is_current else TEXT_LIGHT
            ui.label(chap_title, 20, title_color)

            # Second line: start time + chapter duration ("1h 12m" style).
            var start_sec = Float64(chap.start_time_ms) / 1000.0
            var duration_text = _chapter_duration_text(chap)
            var start_text = format_time(start_sec)
            ui.move_to(title_x, row_y + 42.0)
            ui.label(start_text, 14, TEXT_MUTED)

            var dur_meas = ui._measure_text(duration_text, 14)
            var dur_x = x + w - ui.text_w_design(dur_meas.x) - 24.0
            ui.move_to(dur_x, row_y + 42.0)
            ui.label(duration_text, 14, TEXT_MUTED)

            # Click detection for chapter row (same rect as drawn), plus
            # the spatial-nav registration: A on the focused row seeks to
            # the chapter, same as clicking it.
            var click_rect = ui.rect(x + 10.0, row_y, w - 20.0, chap_h)
            var row_nav = ui.nav_node(click_rect, 1)
            var row_activated = ui.nav_activated(row_nav)
            if ui.nav_focused(row_nav):
                ui.focus_ring(click_rect)
            if row_activated or ui._clicked(click_rect):
                self.current_time = Float64(chap.start_time_ms) / 1000.0
                self._update_current_chapter()
                self._seek_to_current()

            row_y += chap_h

        ui.end_clip()

    def _draw_settings_popover(
        mut self, mut ui: UIContext, sw_design: Float64, sh_design: Float64
    ) raises:
        """Left-anchored popover: playback speed −/+ and volume slider."""
        var card = self._popover_rect(sw_design, sh_design)
        var x = Float64(card.x)
        var y = Float64(card.y)
        var w = Float64(card.width)
        var h = Float64(card.height)

        ui.card(x, y, w, h, CARD_BG, roundness=0.03)

        ui.move_to(x + 24.0, y + 18.0)
        ui.label("Settings", 22, TEXT_BRIGHT)

        var close_btn = 36.0
        var close_result = ui.button_at(
            ICON_CLOSE,
            x + w - close_btn - 14.0,
            y + 12.0,
            close_btn,
            close_btn,
            CARD_BG,
            TEXT_DIM,
            Color(30, 60, 74, 255),
        )
        if close_result.clicked:
            self.overlay_mode = OVERLAY_NONE
            ui.nav_reset()
            return

        var row_y = y + 70.0

        # --- Speed: − [label] + (±0.05 per tap, atempo restart) ---
        ui.move_to(x + 24.0, row_y + 6.0)
        ui.label("Speed", 18, TEXT_LIGHT)

        var btn = 44.0
        var minus_result = ui.button_at(
            "-",
            x + 24.0,
            row_y + 34.0,
            btn,
            btn,
            BTN_CONTROL,
            TEXT_LIGHT,
            Color(30, 60, 74, 255),
            action="speed_down",
        )
        if minus_result.clicked:
            self._change_speed(-0.05)

        var speed_lbl = self._speed_label()
        var speed_meas = ui._measure_text(speed_lbl, 16)
        var label_slot = 96.0
        ui.move_to(
            x
            + 24.0
            + btn
            + 12.0
            + (label_slot - ui.text_w_design(speed_meas.x)) / 2.0,
            row_y + 46.0,
        )
        ui.label(speed_lbl, 20, TEXT_BRIGHT)

        var plus_result = ui.button_at(
            "+",
            x + 24.0 + btn + 12.0 + label_slot + 12.0,
            row_y + 34.0,
            btn,
            btn,
            BTN_CONTROL,
            TEXT_LIGHT,
            Color(30, 60, 74, 255),
            action="speed_up",
        )
        if plus_result.clicked:
            self._change_speed(0.05)

        # --- Volume: slider + percentage ---
        var vol_row_y = row_y + btn + 60.0
        ui.move_to(x + 24.0, vol_row_y + 6.0)
        ui.label("Volume", 18, TEXT_LIGHT)

        var vol_slider_x = x + 24.0
        var vol_slider_w = w - 120.0
        var vol_result = ui.slider(
            vol_slider_x,
            vol_row_y + 40.0,
            vol_slider_w,
            12.0,
            self.volume,
            0.0,
            1.0,
        )
        if vol_result.clicked:
            self.volume_dragging = True
        if self.volume_dragging and ui.mouse_down:
            self.volume = ui.slider_value_from_mouse(
                vol_result.bounds, ui.mouse_pos.x, 0.0, 1.0
            )
            if self.has_stream:
                self.audio_backend.set_volume(self.volume)
        elif not ui.mouse_down:
            self.volume_dragging = False

        var vol_pct = Int(self.volume * 100.0)
        var vol_pct_str = String(vol_pct) + "%"
        ui.move_to(vol_slider_x + vol_slider_w + 14.0, vol_row_y + 38.0)
        ui.label(vol_pct_str, 16, TEXT_DIM)

    def _draw_info_popover(
        mut self, mut ui: UIContext, sw_design: Float64, sh_design: Float64
    ) raises:
        """Left-anchored popover: title, author, series/genres, synopsis.

        Carries the metadata the minimal layout1 canvas removed."""
        var card = self._popover_rect(sw_design, sh_design)
        var x = Float64(card.x)
        var y = Float64(card.y)
        var w = Float64(card.width)
        var h = Float64(card.height)

        ui.card(x, y, w, h, CARD_BG, roundness=0.03)

        ui.move_to(x + 24.0, y + 18.0)
        ui.label("Details", 22, TEXT_BRIGHT)

        var close_btn = 36.0
        var close_result = ui.button_at(
            ICON_CLOSE,
            x + w - close_btn - 14.0,
            y + 12.0,
            close_btn,
            close_btn,
            CARD_BG,
            TEXT_DIM,
            Color(30, 60, 74, 255),
        )
        if close_result.clicked:
            self.overlay_mode = OVERLAY_NONE
            ui.nav_reset()
            return

        var text_x = x + 24.0
        var text_w = w - 48.0
        var row_y = y + DRAWER_TITLE_ROW

        # Title, truncated by measured width (monospace 20 ≈ 12 design px/char).
        if self.book_title.byte_length() > 0:
            var fit_title = truncate_to_width(
                self.book_title, text_w, Float64(ui.font_scale), 12.0
            )
            ui.move_to(text_x, row_y)
            ui.label(fit_title, 20, TEXT_BRIGHT)
            row_y += 32.0

        if self.book_author.byte_length() > 0:
            ui.move_to(text_x, row_y)
            ui.label(
                truncate_to_width(
                    self.book_author, text_w, Float64(ui.font_scale), 11.0
                ),
                18,
                TEXT_LIGHT,
            )
            row_y += 26.0

        # Secondary line: narrator · series · year · genres.
        var meta_parts = List[String]()
        if self.book_narrator.byte_length() > 0:
            meta_parts.append("Narrator: " + self.book_narrator)
        if self.book_series.byte_length() > 0:
            meta_parts.append(self.book_series)
        if self.book_publisher_year.byte_length() > 0:
            meta_parts.append(self.book_publisher_year)
        if self.book_genres.byte_length() > 0:
            meta_parts.append(self.book_genres)
        if len(meta_parts) > 0:
            var meta_line = meta_parts[0]
            for i in range(1, len(meta_parts)):
                meta_line = meta_line + "  ·  " + meta_parts[i]
            ui.move_to(text_x, row_y)
            ui.label(
                truncate_to_width(
                    meta_line, text_w, Float64(ui.font_scale), 9.6
                ),
                16,
                TEXT_MUTED,
            )
            row_y += 26.0

        # Description, word-wrapped to the popover width and clipped to the
        # card interior (monospace 16 ≈ 9.6 design px/char).
        if self.book_description.byte_length() > 0:
            row_y += 10.0
            var line_h = 22.0
            var max_lines = Int((y + h - row_y - 16.0) / line_h)
            if max_lines < 1:
                max_lines = 1
            var cpl = Int(text_w / (9.6 * Float64(ui.font_scale)))
            if cpl < 10:
                cpl = 10
            var wrapped = split_wrap_chars(self.book_description, cpl)
            ui.begin_clip(x, row_y, w, y + h - row_y)
            var line_idx = 0
            while line_idx < max_lines and line_idx < len(wrapped):
                ui.move_to(text_x, row_y + Float64(line_idx) * line_h)
                ui.label(wrapped[line_idx], 16, TEXT_LIGHT)
                line_idx += 1
            ui.end_clip()


def _chapter_duration_text(chap: PlexChapter) -> String:
    """Human chapter duration: 'Xh Ym', 'Ym Zs', or 'Zs' (seconds rounded)."""
    var total_sec = Int(
        (Float64(chap.end_time_ms - chap.start_time_ms) / 1000.0) + 0.5
    )
    if total_sec < 0:
        total_sec = 0
    var hours = total_sec // 3600
    var minutes = (total_sec % 3600) // 60
    var seconds = total_sec % 60
    if hours > 0:
        return String(hours) + "h " + String(minutes) + "m"
    if minutes > 0:
        return String(minutes) + "m " + String(seconds) + "s"
    return String(seconds) + "s"
