from std.os import makedirs, path
from std.pathlib import Path
from std.python import Python, PythonObject
from std.collections import List, Dict, Optional
from std.memory.unsafe_pointer import Pointer
from std.memory import alloc, dealloc, Layout, ThinAllocation
from std.math import min
from resources.color import Color
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
from functions.audio_pipe import AudioPipe, ChunkResult, HttpHeader
from functions.audio_backend import AudioBackend
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

from ui.widgets import TextInput, Button, Checkbox, PlexBookCard
from ui.font import FontSet
from ui.imui import UIContext, UIResult
from ui import Screen
from ui.plex_objects import PlexTrack, PlexChapter, LibraryItem, ServerItem
from ui.icons import ICON_PLAY, ICON_PAUSE

# ---------------------------------------------------------------------------
# Player screen — audiobook playback UI (immediate-mode UI)
#
# The IMUI refactor fixes the critical draw/click layout mismatch bug:
# layout now happens once in draw() and clicks are checked against the same
# rectangles returned by UI elements. No more duplicated constants with
# different values between draw() and handle_mouse_click().
# ---------------------------------------------------------------------------


struct PlayerScreen:
    var book_id: String
    var book_title: String
    var book_author: String
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

    def __init__(out self, screen_w: Int, screen_h: Int):
        self.book_id = ""
        self.book_title = ""
        self.book_author = ""
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
        self.progress_sync_interval = 15.0
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

    def load_book(mut self, book: PlexBookCard, app_state: PlexSession) raises:
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

        var detail = get_book_detail(
            app_state.server_url,
            token,
            book.rating_key,
            app_state.client_id,
        )

        var thumb_path = ""
        if detail.thumb.byte_length() > 0:
            thumb_path = detail.thumb

        try:
            self._load_cover(detail.thumb, app_state)
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

        var tracks = get_book_tracks(
            app_state.server_url,
            token,
            book.rating_key,
            app_state.client_id,
        )

        for i in range(len(tracks)):
            self.tracks.append(tracks[i].copy())

            var track_chapters = get_track_chapters(
                app_state.server_url,
                token,
                tracks[i].rating_key,
                app_state.client_id,
            )

            for j in range(len(track_chapters)):
                var chapter = track_chapters[j].copy()
                chapter.is_current = False
                self.chapters.append(chapter)

        # Fallback: if neither the book card nor the detail API provided a
        # duration, derive it from the sum of track durations.
        if self.duration <= 0.0 and len(self.tracks) > 0:
            var total_ms = 0
            for i in range(len(self.tracks)):
                total_ms += self.tracks[i].duration_ms
            if total_ms > 0:
                self.duration = Float64(total_ms) / 1000.0
                self.book_duration = self.duration

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
                self.current_time = Float64(resume_ms) / 1000.0
            elif not found_progress and detail.view_offset_ms > 0:
                # Album-level offset only (single-track or edge case).
                self.current_time = Float64(detail.view_offset_ms) / 1000.0

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
        if len(self.tracks) > 0 and self.tracks[0].file_key.byte_length() > 0:
            try:
                var decision = get_playback_decision(
                    self.server_url,
                    self.token,
                    self.tracks[0].file_key,
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
        var started = False
        try:
            started = self.pipe.start(
                self.stream_source,
                seek_s,
                self.speed,
                self.stream_is_local,
                headers,
            )
        except e:
            started = False
        if not started:
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

        var restarted = False
        try:
            restarted = self.pipe.restart(seek_s, self.speed)
        except:
            restarted = False
        if not restarted:
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
            try:
                self.audio_backend.close()
            except:
                pass
            self.has_stream = False
        if self.pipe_loaded:
            try:
                self.pipe.stop()
            except:
                pass
        self.frames_fed_since_restart = 0

    def _load_cover(
        mut self, thumb_path: String, app_state: PlexSession
    ) raises:
        """Load cover art from the Plex thumbnail API."""
        if self.cover_loaded:
            return

        if thumb_path.byte_length() == 0:
            self.cover_loaded = True
            return
            self.cover_loaded = True
            return

        var token = app_state.server_token
        if token.byte_length() == 0:
            token = app_state.account_token

        var thumb_url = get_thumbnail_url(
            app_state.server_url,
            thumb_path,
            token,
            300,
            300,
        )

        if thumb_url.byte_length() == 0:
            self.cover_loaded = True
            return

        var image_data = load_cached_cover(self.book_id, 300, 300)
        if image_data.byte_length() == 0:
            image_data = fetch_thumbnail(thumb_url)
            save_cached_cover(self.book_id, 300, 300, image_data)

        if image_data.byte_length() == 0:
            self.cover_loaded = True
            return

        var decoded = imdecode(image_data)
        self.cover_w = decoded.width
        self.cover_h = decoded.height

        # Copy RGBA pixels into the layout-allocated pixel buffer the
        # Canvas rasterizer blits directly.
        var n = self.cover_w * self.cover_h * 4
        var layout = Layout[UInt8](count=n)
        self.cover_pixels = Optional[Pointer[UInt8, MutUntrackedOrigin]](
            alloc(layout).unsafe_leak()
        )
        for i in range(n):
            self.cover_pixels.value()[unsafe_offset=i] = decoded.pixels[i]

        self.has_cover = True

        self.cover_loaded = True

    def stop_and_unload_stream(mut self):
        """Stop the backend stream, terminate ffmpeg, and unload cover art."""
        self.is_playing = False
        self._sync_progress()

        self._stop_stream()

        if self.has_cover:
            var old_pixels = self.cover_pixels.take()
            dealloc(
                ThinAllocation(unsafe_owned_ptr=old_pixels).unsafe_with_layout(
                    Layout[UInt8](count=self.cover_w * self.cover_h * 4)
                )
            )
            self.has_cover = False
        self.cover_loaded = False

    def handle_mouse_click(
        mut self, mouse_pos: Vec2, mut screen: Screen
    ) raises:
        # IMUI handles clicks inside draw() — no-op for main-loop contract.
        pass

    def handle_mouse_drag(mut self, mouse_pos: Vec2):
        """Handle progress bar and volume slider dragging.

        Drag state is retained here (progress_dragging/volume_dragging).
        The actual slider geometry is recomputed in draw() via IMUI, so
        we must mirror the same design-pixel layout to compute new values.
        """
        # Layout constants (design px — must match draw())
        var right_col_x = 500.0
        var right_col_w = 200.0  # placeholder; actual width depends on screen

        # We need the screen width to compute right_col_w. Since handle_mouse_drag
        # is called from main.mojo without screen dims, we read from the music
        # stream's stored screen size... but we removed screen_w/screen_h fields.
        # Instead, we handle drag inside draw() where we have the UIContext.
        # This method is kept as a no-op; drag is processed in draw() via
        # ui.mouse_down + slider hover detection.
        pass

    def handle_scroll(mut self, wheel_delta: Float32):
        """Scroll the chapter list (design-pixel space)."""
        if len(self.chapters) == 0:
            return

        var chap_h = 32.0
        var total_height = Float64(len(self.chapters)) * chap_h
        # Approximate visible height — the exact value is computed in draw()
        # from screen_h. We use a conservative estimate here; draw() will
        # clamp the offset correctly.
        var visible_height = 600.0

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
                    try:
                        self.audio_backend.play()
                    except:
                        pass
            else:
                try:
                    self.audio_backend.play()
                except:
                    pass
        else:
            if self.has_stream:
                try:
                    self.audio_backend.pause()
                except:
                    pass
        self._sync_progress()

    def _sync_progress(mut self):
        """Report playback progress to the Plex server (best-effort)."""
        if self.server_url.byte_length() == 0 or self.token.byte_length() == 0:
            return
        if self.current_track_rating_key.byte_length() == 0:
            return
        if self.progress_sync_timer < self.progress_sync_interval:
            return

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

            _ = report_progress(
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

        self.progress_sync_timer = 0.0

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
            try:
                self.audio_backend.pause()
            except:
                pass
        var ok = self._restart_stream_at(self.current_time)
        if ok and was_playing:
            try:
                self.audio_backend.play()
            except:
                pass

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
                try:
                    self.audio_backend.pause()
                except:
                    pass
            var ok = self._restart_stream_at(self.current_time)
            if ok and was_playing:
                try:
                    self.audio_backend.play()
                    self.is_playing = True
                except:
                    pass
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
            # Pull one chunk of PCM from the native pipe. read_chunk() returns
            # a ChunkResult (address, frame_count); address is the C address
            # of the pipe's persistent heap buffer.
            var chunk = ChunkResult(0, 0)
            try:
                chunk = self.pipe.read_chunk()
            except:
                chunk = ChunkResult(0, 0)

            if chunk.address != 0 and chunk.frame_count > 0:
                # Construct a void pointer from the buffer address and copy
                # it into the backend ring — zero-copy until the ring
                # (AudioPipe owns the memory).
                var pcm_ptr = Pointer[NoneType, MutUntrackedOrigin](
                    unsafe_from_address=chunk.address
                )
                try:
                    self.audio_backend.write_pcm(pcm_ptr, chunk.frame_count)
                except:
                    pass
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
        var reached_end = False
        try:
            reached_end = self.pipe.reached_end()
        except:
            reached_end = False
        if reached_end and not self.progress_dragging:
            self.is_playing = False
            self.current_time = self.duration
            self._mark_track_watched()

        self._update_current_chapter()

    def draw(
        mut self,
        mut ui: UIContext,
        mut screen: Screen,
    ) raises:
        """Render the entire player screen (immediate-mode).

        Layout, input handling, and drawing all happen in this single pass.
        Slider dragging is handled here via ui.mouse_down + retained drag
        flags, using the exact same rectangles returned by ui.slider().
        """
        var sw_design = Float64(ui.screen_w) / Float64(ui.ui_scale)
        var sh_design = Float64(ui.screen_h) / Float64(ui.ui_scale)

        # --- Header bar ---
        var header_h = 50.0
        ui.panel_bg(0.0, 0.0, sw_design, header_h, PLAYER_BG)

        # Back button
        var btn_w = sw_design * 0.25
        var btn_h = 36.0
        ui.move_to(20.0, 7.0)
        ui.cursor_w = Float32(btn_w) * ui.ui_scale
        var back_result = ui.button(
            "<< LIBRARY",
            btn_h,
            BTN_DARK_LIB,
            TEXT_LIGHT,
            Color(55, 64, 80, 255),
            action="back_button",
        )
        # add back
        if back_result.clicked:
            self.stop_and_unload_stream()
            screen.current = 1
            return

        # "Now Playing" label (right-aligned in header)
        var now_playing = "Now Playing"
        var np_meas = ui._measure_text(now_playing, 22)
        var np_x = sw_design - ui.text_w_design(np_meas.x) - 20.0
        ui.move_to(np_x, 12.0)
        ui.label(now_playing, 22, GREEN)

        # --- Content area (vertical stack: cover → metadata → description → player → chapters) ---
        var content_x = 20.0
        var content_w = sw_design - 40.0

        # --- Cover art (centered on app width, scaled to x% width bound, aspect-preserving) ---
        var cover_max = min(sw_design * 0.4, sh_design * 0.4)
        var cover_w = cover_max
        var cover_h = cover_max
        if self.has_cover:
            # Compute scaled dimensions preserving aspect ratio, fit within cover_max.
            var tex_w = Float64(self.cover_w)
            var tex_h = Float64(self.cover_h)
            if tex_w > 0 and tex_h > 0:
                var aspect = tex_w / tex_h
                if aspect >= 1.0:
                    cover_w = cover_max
                    cover_h = cover_max / aspect
                else:
                    cover_h = cover_max
                    cover_w = cover_max * aspect
            var cover_x = (sw_design - cover_w) / 2.0
            var cover_y = header_h + 14.0
            # Canvas is in SCREEN pixels; all imui primitives convert
            # design->screen via ui_scale. blit_rgba expects screen px too,
            # so scale the design-space cover rect before blitting.
            var scale = Float64(ui.ui_scale)
            ui.canvas[unsafe_offset=0].blit_rgba(
                self.cover_pixels.value(),
                self.cover_w,
                self.cover_h,
                self.cover_w * 4,
                cover_x * scale,
                cover_y * scale,
                cover_w * scale,
                cover_h * scale,
            )
        else:
            var placeholder_w = cover_max
            var placeholder_h = cover_max
            var ph_x = (sw_design - placeholder_w) / 2.0
            var ph_y = header_h + 14.0
            ui.card(
                ph_x,
                ph_y,
                placeholder_w,
                placeholder_h,
                PLACEHOLDER_BG,
                roundness=0.06,
            )
            var cover_icon = "COVER"
            var icon_meas = ui._measure_text(cover_icon, 64)
            var icon_x = (
                ph_x + (placeholder_w - ui.text_w_design(icon_meas.x)) / 2.0
            )
            var icon_y = (
                ph_y + (placeholder_h - ui.text_h_design(icon_meas.y)) / 2.0
            )
            ui.move_to(icon_x, icon_y)
            ui.label(cover_icon, 64, TEXT_DIM)
            cover_w = placeholder_w
            cover_h = placeholder_h

        # --- Metadata (centered below cover) ---
        var meta_y = header_h + 14.0 + cover_h + 18.0
        if self.book_title.byte_length() > 0:
            var title_meas = ui._measure_text(self.book_title, 22)
            var title_x = (sw_design - ui.text_w_design(title_meas.x)) / 2.0
            ui.move_to(title_x, meta_y)
            ui.label(self.book_title, 26, TEXT_BRIGHT)
            meta_y += 30.0

        if self.book_author.byte_length() > 0:
            var author_meas = ui._measure_text(self.book_author, 16)
            var author_x = (sw_design - ui.text_w_design(author_meas.x)) / 2.0
            ui.move_to(author_x, meta_y)
            ui.label(self.book_author, 20, TEXT_DIM)
            meta_y += 24.0

        # Secondary metadata line (narrator · series · year · genres)
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
            var meta_line_meas = ui._measure_text(meta_line, 12)
            var meta_line_x = (
                sw_design - ui.text_w_design(meta_line_meas.x)
            ) / 2.0
            ui.move_to(meta_line_x, meta_y)
            ui.label(meta_line, 20, TEXT_MUTED)
            meta_y += 20.0

        # --- Description (truncated to fit a few lines) ---
        var desc_y = meta_y + 6.0
        if self.book_description.byte_length() > 0:
            var desc_max_w = content_w
            var desc_max_chars = Int(desc_max_w / 6.0)
            if desc_max_chars > 3:
                var desc_text = truncate_string(
                    self.book_description, desc_max_chars * 3
                )
                ui.move_to(content_x, desc_y)
                ui.label(desc_text, 20, TEXT_DIM)
                desc_y += 64.0
            else:
                desc_y += 0.0
        else:
            desc_y += 0.0

        # --- Player bar (progress + controls + speed/volume) ---
        var player_y = desc_y + 8.0
        var player_w = content_w
        var player_x = content_x

        # --- Progress bar ---
        var progress_y = player_y
        var progress_h = 8.0
        var progress_result = ui.slider(
            player_x,
            progress_y,
            player_w,
            progress_h,
            self.current_time,
            0.0,
            self.duration,
        )

        # Handle click + drag on progress bar (same rectangle — no mismatch)
        if progress_result.clicked:
            self.progress_dragging = True
        if self.progress_dragging and ui.mouse_down:
            if ui._hit(progress_result.bounds) or True:
                # Allow dragging outside the bar — clamp inside slider_value_from_mouse
                self.current_time = ui.slider_value_from_mouse(
                    progress_result.bounds, ui.mouse_pos.x, 0.0, self.duration
                )
                self._update_current_chapter()
        elif not ui.mouse_down:
            if self.progress_dragging and self.has_stream and self.pipe_loaded:
                # Drag released — restart ffmpeg at the new position.
                var was_playing = self.is_playing
                if was_playing:
                    try:
                        self.audio_backend.pause()
                    except:
                        pass
                var ok = self._restart_stream_at(self.current_time)
                if ok and was_playing:
                    try:
                        self.audio_backend.play()
                    except:
                        pass
            self.progress_dragging = False

        # Time labels below progress bar
        var time_y = progress_y + progress_h + 10.0
        ui.move_to(player_x, time_y)
        ui.label(format_time(self.current_time), 20, TEXT_DIM)

        var remaining = self.duration - self.current_time
        if remaining < 0.0:
            remaining = 0.0
        var remaining_str = "-" + format_time(remaining)
        var rem_meas = ui._measure_text(remaining_str, 12)
        var rem_x = player_x + player_w - ui.text_w_design(rem_meas.x)
        ui.move_to(rem_x, time_y)
        ui.label(remaining_str, 20, TEXT_DIM)

        # --- Chapter seek bar (tracks position within the current chapter) ---
        var chap_bar_y = time_y + 30.0
        var chap_bar_h = 6.0
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

        var chap_result = ui.slider(
            player_x,
            chap_bar_y,
            player_w,
            chap_bar_h,
            chap_pos,
            0.0,
            chap_dur,
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
                    try:
                        self.audio_backend.pause()
                    except:
                        pass
                var ok = self._restart_stream_at(self.current_time)
                if ok and was_playing:
                    try:
                        self.audio_backend.play()
                    except:
                        pass
            self.chapter_dragging = False

        # Chapter time labels
        var chap_time_y = chap_bar_y + chap_bar_h + 8.0
        var chap_elapsed_str = format_time(chap_pos)
        ui.move_to(player_x, chap_time_y)
        ui.label(chap_elapsed_str, 18, TEXT_DIM)

        var chap_remaining = chap_dur - chap_pos
        if chap_remaining < 0.0:
            chap_remaining = 0.0
        var chap_rem_str = "-" + format_time(chap_remaining)
        var chap_rem_meas = ui._measure_text(chap_rem_str, 12)
        var chap_rem_x = player_x + player_w - ui.text_w_design(chap_rem_meas.x)
        ui.move_to(chap_rem_x, chap_time_y)
        ui.label(chap_rem_str, 18, TEXT_DIM)

        # Chapter label (centered between the two time labels)
        var chap_label = "Chapter"
        if self.current_chapter_idx >= 0 and self.current_chapter_idx < len(
            self.chapters
        ):
            chap_label = "Ch " + String(
                self.chapters[self.current_chapter_idx].index
            )
        var chap_lbl_meas = ui._measure_text(chap_label, 12)
        var chap_lbl_x = (
            player_x + (player_w - ui.text_w_design(chap_lbl_meas.x)) / 2.0
        )
        ui.move_to(chap_lbl_x, chap_time_y)
        ui.label(chap_label, 18, GREEN)

        # --- Playback control buttons (5 buttons, equal width) ---
        var ctrl_y = chap_time_y + 30.0
        var ctrl_btn_h = 40.0
        var ctrl_gap = 20.0
        var total_btns = 5
        var total_gap_w = Float64(total_btns - 1) * ctrl_gap
        var ctrl_btn_w = (player_w - total_gap_w) / Float64(total_btns)

        # Prev chapter
        var prev_ch_result = ui.button_at(
            "<< Prev",
            player_x,
            ctrl_y,
            ctrl_btn_w,
            ctrl_btn_h,
            BTN_CONTROL,
            TEXT_LIGHT,
            Color(55, 64, 80, 255),
            action="prev_chapter",
        )
        if prev_ch_result.clicked:
            self._previous_chapter()
            self._seek_to_current()

        # Skip back 30s
        var skip_back_result = ui.button_at(
            "< 30s",
            player_x + ctrl_btn_w + ctrl_gap,
            ctrl_y,
            ctrl_btn_w,
            ctrl_btn_h,
            BTN_CONTROL,
            TEXT_LIGHT,
            Color(55, 64, 80, 255),
            action="skip_back",
        )
        if skip_back_result.clicked:
            self.current_time = self.current_time - 30.0
            if self.current_time < 0.0:
                self.current_time = 0.0
            self._update_current_chapter()
            self._seek_to_current()

        # Play/Pause
        var play_label = ICON_PLAY
        if self.is_playing:
            play_label = ICON_PAUSE
        var play_result = ui.button_at(
            play_label,
            player_x + 2.0 * ctrl_btn_w + 2.0 * ctrl_gap,
            ctrl_y,
            ctrl_btn_w,
            ctrl_btn_h,
            GREEN,
            ACCENT_DARK,
            Color(140, 192, 88, 255),
            action="play_pause",
        )
        if play_result.clicked:
            self.toggle_playback()

        # Skip forward 30s
        var skip_fwd_result = ui.button_at(
            "> 30s",
            player_x + 3.0 * ctrl_btn_w + 3.0 * ctrl_gap,
            ctrl_y,
            ctrl_btn_w,
            ctrl_btn_h,
            BTN_CONTROL,
            TEXT_LIGHT,
            Color(55, 64, 80, 255),
            action="skip_forward",
        )
        if skip_fwd_result.clicked:
            self.current_time = self.current_time + 30.0
            if self.current_time > self.duration:
                self.current_time = self.duration
            self._update_current_chapter()
            self._seek_to_current()

        # Next chapter
        var next_ch_result = ui.button_at(
            "Next >>",
            player_x + 4.0 * ctrl_btn_w + 4.0 * ctrl_gap,
            ctrl_y,
            ctrl_btn_w,
            ctrl_btn_h,
            BTN_CONTROL,
            TEXT_LIGHT,
            Color(55, 64, 80, 255),
            action="next_chapter",
        )
        if next_ch_result.clicked:
            self._next_chapter()
            self._seek_to_current()

        # --- Speed + Volume row ---
        var vol_y = ctrl_y + ctrl_btn_h + 24.0

        # Speed: two buttons (− / +) with the current speed label between.
        # ±0.05 per click, pitch-correct via ffmpeg atempo restart.
        var speed_minus_result = ui.button_at(
            "-",
            player_x,
            vol_y,
            30.0,
            30.0,
            BTN_CONTROL,
            TEXT_LIGHT,
            Color(55, 64, 80, 255),
            action="speed_down",
        )
        if speed_minus_result.clicked:
            self._change_speed(-0.05)

        # Speed label (read-only, centered between the two buttons)
        var speed_lbl = self._speed_label()
        var speed_meas = ui._measure_text(speed_lbl, 14)
        var speed_lbl_x = (
            player_x
            + 30.0
            + 10.0
            + (60.0 - ui.text_w_design(speed_meas.x)) / 2.0
        )
        ui.move_to(speed_lbl_x, vol_y + 8.0)
        ui.label(speed_lbl, 18, TEXT_BRIGHT)

        var speed_plus_result = ui.button_at(
            "+",
            player_x + 30.0 + 10.0 + 60.0 + 10.0,
            vol_y,
            30.0,
            30.0,
            BTN_CONTROL,
            TEXT_LIGHT,
            Color(55, 64, 80, 255),
            action="speed_up",
        )
        if speed_plus_result.clicked:
            self._change_speed(0.05)

        # Volume label
        var vol_label_x = player_x + 30.0 + 10.0 + 60.0 + 10.0 + 30.0 + 10.0
        ui.move_to(vol_label_x, vol_y + 6.0)
        ui.label("Vol", 18, TEXT_DIM)

        # Volume slider
        var vol_slider_x = vol_label_x + 30.0
        var vol_slider_w = 150.0
        var vol_slider_h = 6.0
        var vol_result = ui.slider(
            vol_slider_x,
            vol_y + 10.0,
            vol_slider_w,
            vol_slider_h,
            self.volume,
            0.0,
            1.0,
        )

        # Handle volume drag
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

        # Volume percentage label
        var vol_pct = Int(self.volume * 100.0)
        var vol_pct_str = String(vol_pct) + "%"
        ui.move_to(vol_slider_x + vol_slider_w + 8.0, vol_y + 6.0)
        ui.label(vol_pct_str, 18, TEXT_DIM)

        # --- Chapter list (scrollable) ---
        if len(self.chapters) > 0:
            var chap_list_y = vol_y + 56.0
            var chap_list_bottom = sh_design - 10.0
            var chap_list_h = chap_list_bottom - chap_list_y
            var chap_h = 32.0

            ui.begin_clip(player_x, chap_list_y, player_w, chap_list_h)

            var scroll_design = Float64(self.chapter_scroll_offset) / Float64(
                ui.ui_scale
            )
            var cy = chap_list_y - scroll_design

            for i in range(len(self.chapters)):
                var chap = self.chapters[i]
                var row_y = cy + Float64(i) * chap_h

                if row_y + chap_h < chap_list_y:
                    continue
                if row_y > chap_list_bottom:
                    break

                # Row background: transparent by default (gradient shows
                # through); highlight only the current chapter. Canvas has
                # no alpha compositing, so "transparent" = don't paint.
                if chap.is_current:
                    var row_rect = ui.rect(
                        player_x, row_y, player_w, chap_h - 2.0
                    )
                    ui.canvas[unsafe_offset=0].fill_rect(
                        Float64(row_rect.x),
                        Float64(row_rect.y),
                        Float64(row_rect.width),
                        Float64(row_rect.height),
                        CHAPTER_HIGHLIGHT,
                    )

                # Chapter number
                var ch_num = String(chap.index)
                ui.move_to(player_x + 8.0, row_y + 12.0)
                ui.label(ch_num, 18, GREEN if chap.is_current else TEXT_DIM)

                # Chapter title (truncated)
                var title_x_d = player_x + 40.0
                var max_title_w = player_w - 180.0
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

                ui.move_to(title_x_d, row_y + 12.0)
                var title_color = TEXT_BRIGHT if chap.is_current else TEXT_LIGHT
                ui.label(chap_title, 20, title_color)

                # Time range
                var time_range = (
                    format_time(Float64(chap.start_time_ms) / 1000.0)
                    + " - "
                    + format_time(Float64(chap.end_time_ms) / 1000.0)
                )
                var time_meas = ui._measure_text(time_range, 12)
                var time_x = (
                    player_x + player_w - ui.text_w_design(time_meas.x) - 8.0
                )
                ui.move_to(time_x, row_y + 9.0)
                ui.label(time_range, 20, TEXT_MUTED)

                # Click detection for chapter row (same rectangle as drawn)
                var click_rect = ui.rect(player_x, row_y, player_w, chap_h)
                if ui._clicked(click_rect):
                    self.current_time = Float64(chap.start_time_ms) / 1000.0
                    self._update_current_chapter()
                    self._seek_to_current()

            ui.end_clip()
