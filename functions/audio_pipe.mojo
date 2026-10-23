"""AudioPipe — native Mojo ffmpeg subprocess feeding PCM.

Spawns ffmpeg via posix_spawnp (native argv — no shell) to read a
Plex HTTP stream URL or a local audio file, applies pitch-correct tempo change
via the `atempo` filter, and writes 32-bit float PCM (f32le, 44100 Hz, stereo)
to stdout. The UI loop polls ffmpeg's stdout non-blocking each frame and
feeds chunks directly.

The child process is wired up through posix_spawn_file_actions: stdout ->
the pipe read end, stderr -> /dev/null (the old popen command's
`2>/dev/null` tail). The read end is O_NONBLOCK, so `read_chunk()` polls
via raw read(2) each frame — returning whatever bytes are available
(EAGAIN -> empty result, EOF -> marks end). This replaced a Python
background thread + bounded queue and keeps the player loop in charge of
pacing; the file_actions approach replaced popen + FILE* entirely for
Mojo 1.2 (no shell parsing, no stdio buffering lies, no fread/ferror/feof
flag decoding).

Zero per-float FFI crossings: PCM lands in a persistent Mojo heap buffer and
its raw C address is handed to `update_audio_stream`.
"""

from std.os import path, getenv
from std.pathlib import Path
from std.sys._libc import (
    _get_environ,
    fcntl,
    pipe,
    close as libc_close,
    kill,
    SignalCodes,
    waitpid,
    WaitFlags,
    FcntlCommands,
    FcntlFDFlags,
    # NOTE: the stdlib `posix_spawnp` parametric wrapper is deliberately NOT
    # imported: it hardcodes NULL file_actions (no stdout redirection), and
    # its 4-arg external declaration conflicts with this module's 6-arg
    # external_call to the same symbol. Call the extern directly instead.
)
from std.sys._libc_errno import get_errno, ErrNo
from std.ffi import c_int, c_pid_t, c_uint, CStringSpan, external_call
from std.memory.pointer import OptionalPointer
from std.memory import stack_allocation
from std.memory.unsafe_pointer import Pointer
from std.collections import List, Optional

from functions.helpers import _is_executable, _which
from platform.ffi import Box, c_read

# Must match load_audio_stream() args on the player side.
comptime SAMPLE_RATE = 44100
comptime SAMPLE_SIZE = 32  # bits per sample (float32)
comptime CHANNELS = 2

# PCM frames per chunk. 1 frame = CHANNELS samples.
# 4096 frames ≈ 93ms at 44.1kHz stereo — small enough for low latency, large
# enough to amortize per-chunk overhead. Must match player-side BUFFER_FRAMES.
comptime CHUNK_FRAMES = 4096
comptime CHUNK_BYTES = CHUNK_FRAMES * CHANNELS * (SAMPLE_SIZE // 8)  # 32768

comptime F_SETFL = 4  # not in stdlib's FcntlCommands (only F[D]GETFD/SETFD)
comptime O_NONBLOCK = 0x800
comptime O_WRONLY = 2
comptime O_APPEND = 0o2000
comptime STDOUT_FILENO = 1
comptime STDERR_FILENO = 2


# ---------------------------------------------------------------------------
# Tuple replacements — tuple types didn't construct reliably on the old
# toolchain line; these structs also read better at call sites
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
    """Result of read_chunk(): PCM bytes + frames filled.

    The buffer pointer is typed (Float32 stereo-interleaved PCM) — callers
    can't forge an address or lose the type across module boundaries.
    has_data() is the guard: a no-data result carries a dangling pointer
    that MUST NOT be read, and has_data() is the only correct way to check.
    """

    var samples: Pointer[Float32, MutUntrackedOrigin]  # f32 stereo PCM
    var frame_count: Int

    def __init__(out self):
        self.samples = Pointer[Float32, MutUntrackedOrigin].unsafe_dangling()
        self.frame_count = 0

    def __init__(out self, *, copy: Self):
        self.samples = copy.samples
        self.frame_count = copy.frame_count

    def __init__(
        out self,
        samples: Pointer[Float32, MutUntrackedOrigin],
        frame_count: Int,
    ):
        self.samples = samples
        self.frame_count = frame_count

    def has_data(self) -> Bool:
        return self.frame_count > 0


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
          typed samples + frames. has_data()==False means no data ready.
      restart(seek_s, speed) -> Bool
          Kill + respawn (for speed/seek changes; atempo needs a fresh proc).
      stop()
          Terminate ffmpeg and close the pipe.

    No threading: `read_chunk` polls ffmpeg's non-blocking stdout each frame.
    """

    # ffmpeg subprocess handle. The Process owns reaping (waitpid);
    # `running` gates all access, `read_fd` holds the non-blocking stdout
    # pipe read end (-1 when no process). The write end is closed in the
    # parent immediately after spawn so the child sees EOF when it exits.
    var pid: c_pid_t
    var read_fd: Int
    var running: Bool
    var reached_eof: Bool

    # CHUNK_FRAMES * CHANNELS floats = CHUNK_BYTES bytes. Owned by the
    # Box (typed Layout sizing + matched free in __deinit__ — no manual
    # unsafe_free to roll).
    var buffer: Box[UInt8]

    # Stream parameters retained for restart().
    var source: String
    var is_local: Bool
    var extra_headers: List[HttpHeader]
    var ffmpeg_path: String

    # Total frames fed out via read_chunk since last start/restart.
    # The player reads this to advance normalized playback time.
    var frames_output: Int

    def __init__(out self):
        self.pid = c_pid_t(0)
        self.read_fd = -1
        self.running = False
        self.reached_eof = False
        self.buffer = Box[UInt8](count=CHUNK_BYTES)
        self.source = ""
        self.is_local = False
        self.extra_headers = List[HttpHeader]()
        self.ffmpeg_path = ""
        self.frames_output = 0

    def __deinit__(deinit self):
        self._terminate()
        # the buffer Box frees itself

    def __init__(out self, *, copy: Self):
        self.pid = copy.pid
        self.read_fd = copy.read_fd
        self.running = copy.running
        self.reached_eof = copy.reached_eof
        # Deep copy the buffer so the copy owns independent memory.
        self.buffer = Box[UInt8](count=CHUNK_BYTES)
        if copy.running:
            for i in range(CHUNK_BYTES):
                self.buffer.ptr()[unsafe_offset=i] = copy.buffer.ptr()[
                    unsafe_offset=i
                ]
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

        Non-blocking: the stdout pipe read end is O_NONBLOCK, so raw
        read(2) returns immediately with whatever bytes are available. At
        60fps this keeps the AudioStream fed without the overhead of a
        background thread.

        Read protocol (verified against read(2)/pipe(7) semantics):
          - n > 0: data read (a partial frame at the chunk boundary is
            dropped, as before).
          - n == 0: real EOF (all write ends closed — ffmpeg exited or
            closed stdout). Marks the end.
          - n < 0, errno EAGAIN/EINTR: no data this frame — retry next
            frame.
          - n < 0, other errno: the pipe is broken (child died) — treat
            as end.
        """
        if not self.running or self.read_fd < 0:
            return ChunkResult()

        var n = c_read(
            c_int(self.read_fd),
            rebind[Pointer[NoneType, MutUntrackedOrigin]](self.buffer.ptr()),
            CHUNK_BYTES,
        )

        if n > 0:
            var n_bytes = Int(n)
            if n_bytes > CHUNK_BYTES:
                n_bytes = CHUNK_BYTES
            var frame_count = n_bytes // (CHANNELS * (SAMPLE_SIZE // 8))
            self.frames_output += frame_count
            return ChunkResult(self.pcm_samples(), frame_count)

        if n == 0:
            # Real EOF: ffmpeg closed stdout (finished or died). Reap the
            # process (blocking wait is fine — the child is already exiting
            # or dead).
            self.reached_eof = True
            self.running = False
            self._reap()
            return ChunkResult()

        # n < 0: inspect errno.
        var err = get_errno()
        if err == ErrNo.EAGAIN or err == ErrNo.EINTR:
            # No data this frame — retry on the next frame tick.
            return ChunkResult()

        # Unexpected error on a pipe we own: the write end is gone (child
        # died). Treat as end-of-stream and remember the failure.
        self.reached_eof = True
        self.running = False
        self._reap()
        return ChunkResult()

    def pcm_samples(self) -> Pointer[Float32, MutUntrackedOrigin]:
        """The persistent buffer, typed as f32 stereo-interleaved samples."""
        return rebind[Pointer[Float32, MutUntrackedOrigin]](self.buffer.ptr())

    def get_buffer_address(self) -> Int:
        """Return the persistent buffer's C address (for diagnostics)."""
        return Int(self.buffer.ptr())

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
        """Kill ffmpeg (SIGKILL), drop the pipe, and reap the child.
        Safe to call multiple times. Does NOT free buffer."""
        if self.pid != c_pid_t(0):
            _ = kill(c_int(self.pid), SignalCodes.KILL)
        if self.read_fd >= 0:
            _ = libc_close(c_int(self.read_fd))
        self.running = False
        self.read_fd = -1
        if self.pid != c_pid_t(0):
            # Blocking wait on a SIGKILLed child is prompt. Best-effort:
            # a reaping failure never spills (the pid would linger as a
            # zombie until our exit reaps it via init).
            var st = stack_allocation[1, c_int]()
            _ = waitpid(self.pid, st, c_int(0))
            self.pid = c_pid_t(0)

    def _reap(mut self):
        """Collect an already-exited child (called on EOF). Non-blocking."""
        if self.pid == c_pid_t(0):
            return
        var st = stack_allocation[1, c_int]()
        _ = waitpid(self.pid, st, WaitFlags.WNOHANG)
        self.pid = c_pid_t(0)

    def _build_argv(mut self, seek_s: Float64, speed: Float64) -> List[String]:
        """Build ffmpeg's argv directly (native posix_spawnp, no shell).

        Output is always f32le 44100Hz stereo on `pipe:1`. stderr is
        redirected to /dev/null in the child via file_actions, so no
        `2>/dev/null` argument exists here (that spelling would need a
        shell anyway)."""
        var argv = List[String]()
        # Never touch the terminal's stdin (classic ffmpeg hang when the
        # input is interactive); popen-era runs relied on the shell.
        argv.append("-nostdin")
        argv.append("-hide_banner")
        argv.append("-loglevel")
        argv.append("error")

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
            argv.append("-headers")
            argv.append(header_blob)

        # Seek before input lets ffmpeg skip decode of earlier frames.
        if seek_s > 0.0:
            argv.append("-ss")
            argv.append(_format_seek(seek_s))
        argv.append("-i")
        argv.append(self.source)

        # atempo for pitch-correct speed. 0.5-2.0 covers our entire range
        # (clamped in player); one filter instance suffices.
        if abs(speed - 1.0) > 1e-3:
            var atempo_val = speed
            if atempo_val < 0.5:
                atempo_val = 0.5
            if atempo_val > 2.0:
                atempo_val = 2.0
            argv.append("-af")
            argv.append("atempo=" + _format_speed(atempo_val))

        argv.append("-f")
        argv.append("f32le")
        argv.append("-ar")
        argv.append(String(SAMPLE_RATE))
        argv.append("-ac")
        argv.append(String(CHANNELS))
        argv.append("pipe:1")
        return argv^

    def _spawn(mut self, seek_s: Float64, speed: Float64) raises -> Bool:
        """Launch ffmpeg via posix_spawnp (native argv) with its stdout
        wired to a pipe non-blocking read end."""
        var argv = self._build_argv(seek_s, speed)
        # DEBUG: dump the raw argv from the child's perspective
        var dbg = String()
        for i in range(len(argv)):
            dbg += "[" + argv[i] + "]"
        print("ARGV:", dbg)

        # pipe(): raw fds we own (stdlib Pipe closes both in __deinit__,
        # which would detach our read end when this function returns).
        var fds = stack_allocation[2, c_int]()
        if pipe(fds) != 0:
            return False
        # pipe(2): fds[0] = read end, fds[1] = write end. CLOEXEC on both,
        # so pre-exec code in the child never sees them — adddup2's dup2
        # clears the flag on the child's new stdout itself.
        var write_fd = Int(fds[unsafe_offset=1])
        var read_fd = Int(fds[unsafe_offset=0])
        _ = fcntl(
            fds[unsafe_offset=0], FcntlCommands.F_SETFD, FcntlFDFlags.FD_CLOEXEC
        )
        _ = fcntl(
            fds[unsafe_offset=1], FcntlCommands.F_SETFD, FcntlFDFlags.FD_CLOEXEC
        )

        # posix_spawn_file_actions_t: glibc holds a small inline arena
        # (~80 B on x86-64); a zeroed 256-byte, 8-aligned stack buffer
        # comfortably covers it. Zeroed because an uninitialized struct
        # handed to init() is UB in principle.
        var fa = stack_allocation[32, UInt64]()
        # Typed as OptionalPointer (not Pointer) to match the shape the
        # stdlib's own posix_spawnp wrapper declares for "posix_spawnp" —
        # mismatched ext-decl signatures abort at archive link time.
        var fa_ptr = OptionalPointer[NoneType, MutUntrackedOrigin](
            Pointer[NoneType, MutUntrackedOrigin](unsafe_from_address=Int(fa))
        )
        var rc = external_call["posix_spawn_file_actions_init", c_int](fa_ptr)
        var spawned_ok = False
        if rc == 0:
            # Child stderr -> /dev/null (swallows -loglevel errors, same as
            # the old popen command's `2>/dev/null` tail).
            # DEBUG BISECT: leave stderr inherited (no addopen)
            pass
        if rc == 0:
            # Child stdout (fd 1) <- the pipe's write end.
            rc = external_call["posix_spawn_file_actions_adddup2", c_int](
                fa_ptr,
                c_int(write_fd),
                c_int(STDOUT_FILENO),
            )
        if rc == 0:
            # argv: [file_name, ...args, NULL]. The String entries must
            # OUTLIVE the spawn: as_c_string_span() attaches the NUL
            # terminator to each (mutable) String and aliases its memory.
            var parts = self.ffmpeg_path.split("/")
            var args_copy = List[String]()
            args_copy.append(String(parts[len(parts) - 1]))  # argv[0]
            for i in range(len(argv)):
                args_copy.append(argv[i])

            var argv_ptrs = List[Optional[CStringSpan[ImmutAnyOrigin]]]()
            for j in range(len(args_copy)):
                # Mutate the element in place — a `var arg = args_copy[j]`
                # copy would be deep and die before the spawn, dangling
                # the span.
                var cs = rebind[CStringSpan[ImmutAnyOrigin]](
                    args_copy[j].as_c_string_span()
                )
                argv_ptrs.append(Optional(cs))
            argv_ptrs.append(None)  # NULL terminator

            var pid: c_pid_t = 0
            rc = external_call["posix_spawnp", c_int](
                Pointer(to=pid),
                self.ffmpeg_path.as_c_string_span(),
                fa_ptr,  # file_actions
                OptionalPointer[NoneType, ImmUntrackedOrigin](),  # attrp
                argv_ptrs.unsafe_ptr(),
                _get_environ(),  # inherit the parent's environment
            )
            if rc == 0:
                self.pid = pid
                spawned_ok = True

        _ = external_call["posix_spawn_file_actions_destroy", c_int](fa_ptr)

        if not spawned_ok:
            _ = libc_close(c_int(write_fd))
            _ = libc_close(c_int(read_fd))
            self.running = False
            self.read_fd = -1
            self.pid = c_pid_t(0)
            return False

        # The parent must not hold the write end, or the child's EOF never
        # shows up as read()==0 (the pipe stays open forever).
        _ = libc_close(c_int(write_fd))

        # Non-blocking read end: read() returns EAGAIN instead of blocking
        # the 60fps UI loop when ffmpeg has no data yet.
        _ = fcntl(c_int(read_fd), F_SETFL, O_NONBLOCK)

        self.read_fd = read_fd
        self.running = True
        self.reached_eof = False
        self.frames_output = 0
        return True
