"""AudioPipe — native Mojo ffmpeg subprocess feeding PCM.

Spawns ffmpeg via `popen` to read a
Plex HTTP stream URL or a local audio file, applies pitch-correct tempo change
via the `atempo` filter, and writes 32-bit float PCM (f32le, 44100 Hz, stereo)
to stdout. The UI loop polls ffmpeg's stdout non-blocking each frame and
feeds chunks directly

Mojo 1.0.0 has no threading or sync primitives, so the Python background
thread + bounded queue is replaced with single-threaded non-blocking reads:
ffmpeg's stdout fd is set to O_NONBLOCK, stdio is set to unbuffered (_IONBF),
and `read_chunk()` polls via `fread` each frame — returning whatever bytes
are available (EAGAIN -> empty result, EOF -> marks end).

Zero per-float FFI crossings: PCM lands in a persistent Mojo heap buffer and
its raw C address is handed to `update_audio_stream`
"""

from std.os import path, getenv
from std.pathlib import Path
from std.sys._libc import popen, pclose, FILE_ptr
from std.ffi import external_call, c_int, c_size_t
from std.memory import Layout
from std.memory.unsafe_pointer import Pointer
from std.collections import List

from functions.helpers import _is_executable, _which, _shell_quote
from platform.ffi import cstr

# Must match load_audio_stream() args on the player side.
comptime SAMPLE_RATE = 44100
comptime SAMPLE_SIZE = 32  # bits per sample (float32)
comptime CHANNELS = 2

# PCM frames per chunk. 1 frame = CHANNELS samples.
# 4096 frames ≈ 93ms at 44.1kHz stereo — small enough for low latency, large
# enough to amortize per-chunk overhead. Must match player-side BUFFER_FRAMES.
comptime CHUNK_FRAMES = 4096
comptime CHUNK_BYTES = CHUNK_FRAMES * CHANNELS * (SAMPLE_SIZE // 8)  # 32768

comptime F_SETFL = 4
comptime O_NONBLOCK = 0x800
comptime _IONBF = 2  # setvbuf mode: unbuffered I/O


# ---------------------------------------------------------------------------
# Tuple replacements — Mojo 1.0.0b2 tuples don't construct as types
# ---------------------------------------------------------------------------


struct HttpHeader(Copyable, ImplicitlyCopyable, Movable):
    """A single HTTP header key/value pair. Replaces (String, String)."""

    var key: String
    var value: String

    def __init__(out self):
        self.key = ""
        self.value = ""

    def __init__(out self, key: String, value: String):
        self.key = key
        self.value = value

    def __init__(out self, *, copy: Self):
        self.key = copy.key
        self.value = copy.value


struct ChunkResult(Copyable, ImplicitlyCopyable, Movable):
    """Result of read_chunk(): buffer address + frames filled.

    address==0 / frame_count==0 means no data ready (EAGAIN) or pipe stopped.
    """

    var address: Int
    var frame_count: Int

    def __init__(out self):
        self.address = 0
        self.frame_count = 0

    def __init__(out self, *, copy: Self):
        self.address = copy.address
        self.frame_count = copy.frame_count

    def __init__(out self, address: Int, frame_count: Int):
        self.address = address
        self.frame_count = frame_count


# ---------------------------------------------------------------------------
# Audio-specific FILE* placeholder (helpers moved to functions.helpers)
# ---------------------------------------------------------------------------


def _null_file_ptr() -> FILE_ptr:
    """Return a zero-valued FILE* placeholder for the 'no process' state.

    Accessing this without `running=True` would be undefined; the `running`
    flag gates all real use. Default value construction (no initializer)
    yields the zero-valued placeholder on Mojo 1.0.0.
    """
    var fp = FILE_ptr()
    return fp


# ---------------------------------------------------------------------------
# ffmpeg binary location
# ---------------------------------------------------------------------------


def _find_ffmpeg() raises -> String:
    """Locate an ffmpeg binary, preferring the pixi env one.

    Mirrors the Python `_find_ffmpeg`: $CONDA_PREFIX/bin/ffmpeg, then `which`,
    then /usr/bin/ffmpeg. Falls back to the bare name `ffmpeg` (relying on PATH).
    """
    var candidates = List[String]()
    var conda_prefix = getenv("CONDA_PREFIX")
    if conda_prefix.byte_length() > 0:
        candidates.append(conda_prefix + "/bin/ffmpeg")
    var which_result = _which("ffmpeg")
    if which_result.byte_length() > 0:
        candidates.append(which_result)
    candidates.append("/usr/bin/ffmpeg")

    for i in range(len(candidates)):
        var candidate = candidates[i]
        if candidate.byte_length() > 0 and path.isfile(Path(candidate)):
            return candidate
    return "ffmpeg"


# ---------------------------------------------------------------------------
# Numeric formatting helpers
# ---------------------------------------------------------------------------


def _format_seek(seek_s: Float64) -> String:
    """Format a seek offset in seconds with 3 decimal places (e.g. '12.345')."""
    var whole = Int(seek_s)
    var frac = seek_s - Float64(whole)
    if frac < 0.0:
        frac = -frac
    var frac_ms = Int(frac * 1000.0 + 0.5)
    if frac_ms >= 1000:
        whole += 1
        frac_ms -= 1000
    var frac_str = String(frac_ms)
    # Zero-pad to 3 digits.
    if frac_ms < 10:
        frac_str = "00" + frac_str
    elif frac_ms < 100:
        frac_str = "0" + frac_str
    return String(whole) + "." + frac_str


def _format_speed(speed: Float64) -> String:
    """Format an atempo speed value with 4 decimal places (e.g. '1.0500')."""
    var whole = Int(speed)
    var frac = speed - Float64(whole)
    if frac < 0.0:
        frac = -frac
    var frac_micro = Int(frac * 10000.0 + 0.5)
    if frac_micro >= 10000:
        whole += 1
        frac_micro -= 10000
    var frac_str = String(frac_micro)
    if frac_micro < 10:
        frac_str = "000" + frac_str
    elif frac_micro < 100:
        frac_str = "00" + frac_str
    elif frac_micro < 1000:
        frac_str = "0" + frac_str
    return String(whole) + "." + frac_str


# ---------------------------------------------------------------------------
# AudioPipe struct
# ---------------------------------------------------------------------------


struct AudioPipe:
    """Manages an ffmpeg subprocess producing f32le PCM on stdout.

    Lifecycle:
      start(source, seek_s, speed, is_local, headers) -> Bool
      read_chunk() -> ChunkResult
          Reads one chunk of PCM into the persistent buffer and returns
          (address, frames). address==0 / frames==0 means no data ready.
      restart(seek_s, speed) -> Bool
          Kill + respawn (for speed/seek changes; atempo needs a fresh proc).
      stop()
          Terminate ffmpeg and close the pipe.

    No threading: `read_chunk` polls ffmpeg's non-blocking stdout each frame.
    """

    # ffmpeg subprocess handle. `fp` is a non-nullable C FILE*; the
    # `running` flag gates all access (when False, fp is stale/invalid).
    var fp: FILE_ptr
    var fd: Int  # stdout fileno; -1 when no process
    var running: Bool
    var reached_eof: Bool

    # CHUNK_FRAMES * CHANNELS floats = CHUNK_BYTES bytes.
    var buffer: Pointer[UInt8, MutUntrackedOrigin]

    # Stream parameters retained for restart().
    var source: String
    var is_local: Bool
    var extra_headers: List[HttpHeader]
    var ffmpeg_path: String

    # Total frames fed out via read_chunk since last start/restart.
    # The player reads this to advance normalized playback time.
    var frames_output: Int

    def __init__(out self):
        self.fp = _null_file_ptr()
        self.fd = -1
        self.running = False
        self.reached_eof = False
        self.buffer = alloc(Layout[UInt8](count=CHUNK_BYTES)).unsafe_leak()
        self.source = ""
        self.is_local = False
        self.extra_headers = List[HttpHeader]()
        self.ffmpeg_path = ""
        self.frames_output = 0

    def __deinit__(deinit self):
        self._terminate()
        self.buffer.unsafe_free()

    def __init__(out self, *, copy: Self):
        self.fp = copy.fp
        self.fd = copy.fd
        self.running = copy.running
        self.reached_eof = copy.reached_eof
        # Deep copy the buffer so the copy owns independent memory.
        self.buffer = alloc(Layout[UInt8](count=CHUNK_BYTES)).unsafe_leak()
        if copy.running:
            for i in range(CHUNK_BYTES):
                self.buffer[unsafe_offset=i] = copy.buffer[unsafe_offset=i]
        self.source = copy.source
        self.is_local = copy.is_local
        self.extra_headers = copy.extra_headers.copy()
        self.ffmpeg_path = copy.ffmpeg_path
        self.frames_output = copy.frames_output

    # ------------------------------------------------------------------ #
    # Public API
    # ------------------------------------------------------------------ #

    def start(
        mut self,
        source: String,
        seek_s: Float64 = 0.0,
        speed: Float64 = 1.0,
        is_local: Bool = False,
        headers: Optional[List[HttpHeader]] = None,
    ) raises -> Bool:
        """Spawn ffmpeg reading `source` (file path or HTTP URL) and begin
        draining stdout. Returns True on success."""
        self.stop()
        self.source = source
        self.is_local = is_local
        self.extra_headers = List[HttpHeader]()
        if headers:
            for i in range(len(headers[])):
                self.extra_headers.append(headers[][i])
        self.frames_output = 0
        if self.ffmpeg_path.byte_length() == 0:
            self.ffmpeg_path = _find_ffmpeg()
        return self._spawn(seek_s, speed)

    def restart(mut self, seek_s: Float64, speed: Float64) raises -> Bool:
        """Kill current ffmpeg and respawn at `seek_s` with `speed`.
        Use for seek and speed changes (atempo requires a fresh process)."""
        if self.source.byte_length() == 0:
            return False
        self.stop()
        self.frames_output = 0
        return self._spawn(seek_s, speed)

    def read_chunk(mut self) raises -> ChunkResult:
        """Read one chunk of PCM into the persistent buffer and return
        a ChunkResult (address, frame_count). frame_count may be less than
        CHUNK_FRAMES if only a partial chunk was available. Returns (0, 0)
        when no data is ready (EAGAIN) or the pipe isn't running.

        Non-blocking: ffmpeg's stdout fd is O_NONBLOCK and stdio is set to
        unbuffered (_IONBF), so `fread` returns immediately with whatever
        bytes are available. At 60fps this keeps the AudioStream fed without
        the overhead of a background thread.

        Read protocol (verified against glibc behavior):
          - n > 0: data read. ferror may also be 1 (a follow-up non-blocking
            probe hit EAGAIN after draining the available bytes) — clear it.
          - n == 0, feof == 1: real EOF (ffmpeg closed stdout). Mark end.
          - n == 0, ferror == 1, feof == 0: EAGAIN, no data this frame.
        """
        if not self.running:
            return ChunkResult(0, 0)

        # Clear any sticky error/EOF flag from a previous EAGAIN so this read
        # can surface fresh state.
        _ = external_call["clearerr", c_int](self.fp)

        var buf_ptr = rebind[Pointer[Int8, MutUntrackedOrigin]](self.buffer)
        var n = external_call["fread", c_size_t](
            buf_ptr, c_size_t(1), c_size_t(CHUNK_BYTES), self.fp
        )
        var n_bytes = Int(n)

        var eof_flag = Int(external_call["feof", c_int](self.fp))

        # Real EOF: ffmpeg closed stdout (finished or died). Drain any final
        # bytes first (n may be > 0 with eof set on the same read).
        if eof_flag == 1:
            self.reached_eof = True
            self.running = False
            if n_bytes > 0:
                # Last partial chunk — deliver it before signaling end.
                if n_bytes > CHUNK_BYTES:
                    n_bytes = CHUNK_BYTES
                var frame_count = n_bytes // (CHANNELS * (SAMPLE_SIZE // 8))
                self.frames_output += frame_count
                var addr = Int(self.buffer)
                return ChunkResult(addr, frame_count)
            return ChunkResult(0, 0)

        # EAGAIN (or transient error) with no data — retry next frame.
        if n_bytes == 0:
            # ferror is set from the non-blocking probe hitting EAGAIN; the
            # next read_chunk clears it via clearerr above.
            return ChunkResult(0, 0)

        # Got data (ferror may also be 1 from a trailing EAGAIN probe — harmless).
        if n_bytes > CHUNK_BYTES:
            n_bytes = CHUNK_BYTES

        var frame_count = n_bytes // (CHANNELS * (SAMPLE_SIZE // 8))
        self.frames_output += frame_count
        var addr = Int(self.buffer)
        return ChunkResult(addr, frame_count)

    def get_buffer_address(self) -> Int:
        """Return the persistent buffer's C address (for diagnostics)."""
        return Int(self.buffer)

    def get_chunk_frames(self) -> Int:
        """Return the fixed chunk size in frames (CHUNK_FRAMES)."""
        return CHUNK_FRAMES

    def is_running(self) -> Bool:
        """True if ffmpeg is alive and hasn't hit EOF."""
        return self.running

    def reached_end(self) -> Bool:
        """True once ffmpeg has closed stdout (EOF reached)."""
        return self.reached_eof

    def stop(mut self):
        """Terminate ffmpeg and close the pipe. Safe to call multiple times."""
        self._terminate()

    # ------------------------------------------------------------------ #
    # Internal
    # ------------------------------------------------------------------ #

    def _terminate(mut self):
        """Close the pipe if running and reset state. Does NOT free buffer."""
        if self.running:
            _ = pclose(self.fp)
        self.running = False
        self.fd = -1
        self.fp = _null_file_ptr()

    def _build_command(mut self, seek_s: Float64, speed: Float64) -> String:
        """Build the shell command for ffmpeg. Output is always f32le
        44100Hz stereo. Uses popen so the shell parses argv — we must
        shell-quote every interpolated value."""
        var cmd = _shell_quote(self.ffmpeg_path)
        cmd += " -hide_banner -loglevel error"

        # HTTP headers for Plex streams (e.g. X-Plex-Token).
        if not self.is_local and len(self.extra_headers) > 0:
            var header_blob = String("")
            for i in range(
                len(
                    self.extra_headers,
                )
            ):
                var entry = self.extra_headers[i].copy()
                header_blob += entry.key + ": " + entry.value + "\r\n"
            cmd += " -headers " + _shell_quote(header_blob)

        # Seek before input lets ffmpeg skip decode of earlier frames.
        if seek_s > 0.0:
            cmd += " -ss " + _format_seek(seek_s)
        cmd += " -i " + _shell_quote(self.source)

        # atempo for pitch-correct speed. 0.5-2.0 covers our entire range
        # (clamped in player); one filter instance suffices.
        if abs(speed - 1.0) > 1e-3:
            var atempo_val = speed
            if atempo_val < 0.5:
                atempo_val = 0.5
            if atempo_val > 2.0:
                atempo_val = 2.0
            cmd += " -af atempo=" + _format_speed(atempo_val)

        cmd += " -f f32le -ar 44100 -ac 2 pipe:1 2>/dev/null"
        return cmd

    def _spawn(mut self, seek_s: Float64, speed: Float64) raises -> Bool:
        """Launch ffmpeg via popen and set stdout non-blocking."""
        var cmd_str = self._build_command(seek_s, speed)
        var cmd = String(cmd_str)
        var mode = String("r")
        try:
            self.fp = popen(cstr(cmd), cstr(mode))
        except:
            self.running = False
            self.fd = -1
            return False

        # popen returns a non-null FILE* on success. The libc binding's
        # non-nullable type means we can't null-check directly; rely on
        # fileno succeeding as the liveness probe.
        try:
            self.fd = Int(external_call["fileno", c_int](self.fp))
        except:
            _ = pclose(self.fp)
            self.running = False
            self.fd = -1
            self.fp = _null_file_ptr()
            return False

        if self.fd < 0:
            _ = pclose(self.fp)
            self.running = False
            self.fd = -1
            self.fp = _null_file_ptr()
            return False

        # Set the stdout fd to non-blocking so read() returns EAGAIN instead
        # of blocking the 60fps UI loop when ffmpeg has no data yet.
        try:
            _ = external_call["fcntl", c_int](
                c_int(self.fd), c_int(F_SETFL), c_int(O_NONBLOCK)
            )
        except:
            pass  # non-blocking is best-effort; blocking reads still work

        # Set stdio to unbuffered (_IONBF) so fread hits the non-blocking fd
        # directly rather than trying to fill a stdio buffer (which would
        # block). Without this, fread on a non-blocking fd sets ferror on
        # every EAGAIN even when no data was requested.
        try:
            _ = external_call["setvbuf", c_int](
                self.fp,
                Pointer[Int8, MutUntrackedOrigin].unsafe_dangling(),
                c_int(_IONBF),
                c_int(0),
            )
        except:
            pass

        self.running = True
        self.reached_eof = False
        self.frames_output = 0
        return True
