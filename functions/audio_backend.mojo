# audio_backend.mojo — PulseAudio simple-API backend. Pure Mojo: external_call FFI to libpulse-simple +
# pthread (no C shim needed).
#
# Model: AudioPipe (ffmpeg) produces f32le stereo PCM chunks; the player's
# x-fps loop calls needs_data() then write_pcm() to push chunks into a ring
# buffer; a dedicated writer thread drains the ring into pa_simple_write.
# pa_simple blocks when the server buffer is full — the thread owns that
# blocking, never the UI loop.
#
# Thread-safety: Mutex[RingState] (pthread-backed, from functions/mutex.mojo)
# guards ring bookkeeping. The mutex lives inside BackendShared, which is
# move-constructed onto the heap in create() — the writer thread reaches
# everything through the shared pointer.
from std.ffi import external_call
from std.memory import stack_allocation, unsafe_memcpy
from std.memory.unsafe_pointer import Pointer
from std.collections import Optional
from std.time import sleep

from functions.mutex import Mutex

from platform.ffi import c_null as _null
from platform.ffi import cstr
from platform.ffi import heap_malloc
from platform.ffi import heap_free_byte

# --- PulseAudio constants (pulse/def.h, sample.h) ---
comptime PA_STREAM_PLAYBACK = 1
# enum pa_sample_format: 0=U8 1=ALAW 2=ULAW 3=S16LE 4=S16BE 5=FLOAT32LE ...
# NOTE: FLOAT32LE is 5 — an early draft used 3 (S16LE), which made libpulse
# read the f32 stream as int16 → severe distortion.
comptime PA_SAMPLE_FLOAT32LE = 5

comptime SAMPLE_RATE = 44100
comptime CHANNELS = 2
comptime BYTES_PER_FRAME = CHANNELS * 4  # f32 stereo

# Ring capacity in FRAMES. 65536 frames ≈ 1.49s of headroom at 44.1kHz;
# comfortably larger than the 4096-frame chunks the pipe produces.
comptime RING_FRAMES = 65536
comptime RING_BYTES = RING_FRAMES * BYTES_PER_FRAME

# Writer drain granularity: matches the AudioPipe chunk size.
comptime DRAIN_FRAMES = 4096

# BackendShared heap allocation size: 3 x 8B (stream/ring/capacity) + Mutex
# (2 x 8B ptrs + 40B pthread_mutex_t) = 80B; 96 leaves headroom.
comptime SIZEOF_BACKEND_SHARED = 96


# --- pa_sample_spec: {int format, uint32 rate, uint8 channels} (12 bytes) ---
# NOTE (Mojo 1.0.0): Array (fixed-size N) is NOT implicitly copyable, so this
# struct cannot declare ImplicitlyCopyable and value-copies need an explicit
struct PaSampleSpec(Copyable, Movable):
    var raw: Array[Byte, 12]

    def __init__(out self, fmt: Int32, rate: UInt32, channels: UInt8):
        self.raw = Array[Byte, 12](uninitialized=True)
        var sp = Pointer[Byte, MutUntrackedOrigin](
            unsafe_from_address=Int(self.raw.unsafe_ptr())
        )
        # format (LE int32)
        for i in range(4):
            sp[unsafe_offset=0 + i] = Byte((Int(fmt) >> (8 * i)) & 0xFF)
        # rate (LE uint32)
        for i in range(4):
            sp[unsafe_offset=4 + i] = Byte((Int(rate) >> (8 * i)) & 0xFF)
        # channels (uint8) + 3 pad bytes
        sp[unsafe_offset=8] = Byte(channels & 0xFF)
        sp[unsafe_offset=9] = Byte(0)
        sp[unsafe_offset=10] = Byte(0)
        sp[unsafe_offset=11] = Byte(0)

    def __copyinit__(mut self, existing: Self):
        self.raw = Array[Byte, 12](uninitialized=True)
        for i in range(12):
            self.raw[i] = existing.raw[i]


# --- Shared control block between player thread and writer thread ---
# RingState: the mutable bookkeeping guarded by the mutex. Ring geometry
# (ring, capacity) and the pulse stream are immutable after create(), so
# they stay outside the lock — readers may touch them freely.
struct RingState(Copyable, Movable):
    var read_pos: Int  # bytes (writer)
    var write_pos: Int  # bytes (player)
    var used: Int  # bytes currently buffered
    var running: Int  # writer thread keepalive
    var playing: Int  # gate: writer actually writes
    var volume: Float32  # applied at drain time

    def __init__(out self):
        self.read_pos = 0
        self.write_pos = 0
        self.used = 0
        self.running = 1
        self.playing = 0
        self.volume = Float32(1.0)


# Not Copyable (the Mutex cannot be copied): constructed locally in create()
# and moved onto the heap. Every access — from either thread — goes through
# a Pointer[BackendShared].
struct BackendShared(Movable):
    var stream: Pointer[NoneType, MutUntrackedOrigin]  # pa_simple*
    var ring: Pointer[Byte, MutUntrackedOrigin]  # f32 PCM ring
    var capacity: Int  # ring size in bytes
    var state: Mutex[RingState]  # guards RingState above

    def __init__(
        out self,
        stream: Pointer[NoneType, MutUntrackedOrigin],
        ring: Pointer[Byte, MutUntrackedOrigin],
    ):
        self.stream = stream
        self.ring = ring
        self.capacity = RING_BYTES
        self.state = Mutex[RingState]()
        self.state.init_with(RingState())


def _ring_read(
    sh_ptr: Pointer[BackendShared, MutUntrackedOrigin],
    dest: Pointer[Byte, MutUntrackedOrigin],
    take: Int,
    read_pos: Int,
):
    """Copy `take` bytes from the ring starting at read_pos into dest,
    handling the wrap-around. Caller holds the data snapshot stable (only
    the writer advances read_pos, so positions it observed under lock stay
    valid until it advances them)."""
    var capacity = sh_ptr[unsafe_offset=0].capacity
    var ring = sh_ptr[unsafe_offset=0].ring
    var wrapped = read_pos + take - capacity
    if wrapped <= 0:
        var src = Pointer[Byte, MutUntrackedOrigin](
            unsafe_from_address=Int(ring) + read_pos
        )
        unsafe_memcpy(dest=dest, src=src, count=take)
    else:
        var head = capacity - read_pos
        var src1 = Pointer[Byte, MutUntrackedOrigin](
            unsafe_from_address=Int(ring) + read_pos
        )
        unsafe_memcpy(dest=dest, src=src1, count=head)
        unsafe_memcpy(
            dest=Pointer[Byte, MutUntrackedOrigin](
                unsafe_from_address=Int(dest) + head
            ),
            src=ring,
            count=take - head,
        )


def _load_state(
    sh_ptr: Pointer[BackendShared, MutUntrackedOrigin],
) -> RingState:
    """Snapshot the guarded ring state (single lock scope)."""
    with sh_ptr[unsafe_offset=0].state.lock() as p:
        return p[unsafe_offset=0].copy()


def backend_writer_entry(
    arg: Pointer[NoneType, MutUntrackedOrigin],
) -> Pointer[NoneType, MutUntrackedOrigin]:
    """Writer thread: drains ring -> pa_simple_write while running."""
    var sh_ptr = arg.unsafe_bitcast[BackendShared]()
    var chunk = stack_allocation[DRAIN_FRAMES * BYTES_PER_FRAME, Byte]()
    while True:
        var snap = _load_state(sh_ptr)

        if snap.running == 0:
            break

        if snap.playing == 0 or snap.used == 0:
            # idle: sleep so a paused backend doesn't busy-spin the CPU
            sleep(0.1)
            continue

        # take up to DRAIN_FRAMES from the ring
        var take = snap.used
        var chunk_max = DRAIN_FRAMES * BYTES_PER_FRAME
        if take > chunk_max:
            take = chunk_max

        _ring_read(sh_ptr, chunk, take, snap.read_pos)

        # advance read position, release the consumed space
        with sh_ptr[unsafe_offset=0].state.lock() as p:
            p[unsafe_offset=0].read_pos = (
                p[unsafe_offset=0].read_pos + take
            ) % sh_ptr[unsafe_offset=0].capacity
            p[unsafe_offset=0].used -= take

        # apply volume in place
        var nsamples = take // 4  # f32 samples (stereo interleaved)
        var f = chunk.unsafe_bitcast[Float32]()
        for i in range(nsamples):
            f[unsafe_offset=i] = f[unsafe_offset=i] * snap.volume

        # blocking write to pulse — this thread owns the latency
        var bytes_written = external_call["pa_simple_write", Int32](
            sh_ptr[unsafe_offset=0].stream,
            chunk.unsafe_bitcast[NoneType](),
            UInt64(take),
            _null[NoneType](),
        )
        if bytes_written < 0:
            # write failed (server gone?). stop the playback loop.
            with sh_ptr[unsafe_offset=0].state.lock() as p:
                p[unsafe_offset=0].playing = 0

    return _null[NoneType]()


# --- The backend the player talks to ---
struct AudioBackend(Copyable, Movable):
    """create (load_audio_stream), needs_data (is_audio_stream_processed),
    write_pcm (update_audio_stream), play/pause/resume/stop, is_playing,
    set_volume, close (unload_audio_stream)."""

    var shared: Optional[
        Pointer[BackendShared, MutUntrackedOrigin]
    ]  # heap control block
    var thread: Optional[Pointer[UInt64, MutUntrackedOrigin]]  # pthread_t
    var created: Bool
    var active: Bool  # between play() and pause()/stop() — "is_playing"

    def __init__(out self):
        self.shared = Optional[Pointer[BackendShared, MutUntrackedOrigin]]()
        self.thread = Optional[Pointer[UInt64, MutUntrackedOrigin]]()
        self.created = False
        self.active = False

    # -- lifecycle ----------------------------------------------------------

    def create(mut self) -> Bool:
        """Connect to the pulse server at 44100Hz / f32le / stereo and spawn
        the writer thread. Mirrors load_audio_stream(...)."""
        if self.created:
            return True

        # pa_simple_new expects a POINTER to pa_sample_spec; passing by-value
        # pushes struct bytes into the arg register where libpulse
        # dereferences it (pa_sample_spec_valid segfault — see ab_smoke saga).
        var spec_mem = heap_malloc(12).unsafe_bitcast[PaSampleSpec]()
        spec_mem.unsafe_write(
            PaSampleSpec(PA_SAMPLE_FLOAT32LE, SAMPLE_RATE, CHANNELS)
        )
        var app_name = String("quire")
        var stream_name = String("playback")
        var stream = external_call[
            "pa_simple_new", Pointer[NoneType, MutUntrackedOrigin]
        ](
            _null[NoneType](),  # server (default)
            cstr(app_name),
            PA_STREAM_PLAYBACK,
            _null[NoneType](),  # device (default)
            cstr(stream_name),
            spec_mem,
            _null[NoneType](),  # channel map (default)
            _null[NoneType](),  # buffering attrs (defaults)
            _null[NoneType](),  # error
        )
        if Int(stream) == 0:
            return False

        var ring = heap_malloc(RING_BYTES).unsafe_bitcast[Byte]()

        # BackendShared owns the mutex; move-construct it onto the heap so
        # both threads reach it through sh_mem. HEAP-allocation is mandatory:
        # stack_allocation memory lives in create()'s frame and is clobbered
        # once create() returns (the original writer-thread segfault).
        var shared = BackendShared(stream, ring)
        var sh_mem = heap_malloc(SIZEOF_BACKEND_SHARED).unsafe_bitcast[
            BackendShared
        ]()
        sh_mem.unsafe_write(shared^)

        self.shared = Optional[Pointer[BackendShared, MutUntrackedOrigin]](
            sh_mem
        )

        # pthread_t buffer must outlive create() too (close() joins it).
        var tid = heap_malloc(8).unsafe_bitcast[UInt64]()
        var rc = external_call["pthread_create", Int32](
            tid,
            _null[NoneType](),
            backend_writer_entry,
            sh_mem.unsafe_bitcast[NoneType](),
        )
        if rc != 0:
            external_call["pa_simple_free", NoneType](stream)
            sh_mem[unsafe_offset=0].state.close()
            heap_free_byte(sh_mem.unsafe_bitcast[Byte]())
            heap_free_byte(ring)
            self.shared = Optional[Pointer[BackendShared, MutUntrackedOrigin]]()
            return False

        self.thread = Optional[Pointer[UInt64, MutUntrackedOrigin]](tid)
        self.created = True
        self.active = False
        return True

    def close(mut self):
        """Stop the writer, drain, free. Mirrors unload_audio_stream."""
        if not self.created or not self.shared or not self.thread:
            return
        var sh_mem = self.shared.value()

        with sh_mem[unsafe_offset=0].state.lock() as p:
            p[unsafe_offset=0].running = 0

        _ = external_call["pthread_join", Int32](
            self.thread.value()[unsafe_offset=0], _null[NoneType]()
        )

        _ = external_call["pa_simple_drain", Int32](
            sh_mem[unsafe_offset=0].stream, _null[NoneType]()
        )
        _ = external_call["pa_simple_free", NoneType](
            sh_mem[unsafe_offset=0].stream
        )
        sh_mem[unsafe_offset=0].state.close()

        # free the heap allocations made in create()
        heap_free_byte(sh_mem[unsafe_offset=0].ring.unsafe_bitcast[Byte]())
        heap_free_byte(self.thread.value().unsafe_bitcast[Byte]())
        heap_free_byte(sh_mem.unsafe_bitcast[Byte]())

        self.shared = Optional[Pointer[BackendShared, MutUntrackedOrigin]]()
        self.thread = Optional[Pointer[UInt64, MutUntrackedOrigin]]()
        self.created = False
        self.active = False

    # -- playback control ---------------------------------------------------

    def play(mut self):
        """Start/resume consumption. Mirrors play_audio_stream /
        resume_audio_stream."""
        if not self.created or not self.shared:
            return
        var sh_mem = self.shared.value()
        with sh_mem[unsafe_offset=0].state.lock() as p:
            p[unsafe_offset=0].playing = 1
        self.active = True

    def pause(mut self):
        """Halt consumption and discard buffered audio so resume starts at
        the pipe's current position (mirrors pause_audio_stream semantics
        the player relies on during seek/speed changes)."""
        if not self.created or not self.shared:
            return
        var sh_mem = self.shared.value()
        with sh_mem[unsafe_offset=0].state.lock() as p:
            p[unsafe_offset=0].playing = 0
            # drop anything the writer hasn't taken yet — resume starts at
            # the pipe's current position
            p[unsafe_offset=0].read_pos = 0
            p[unsafe_offset=0].write_pos = 0
            p[unsafe_offset=0].used = 0
        _ = external_call["pa_simple_flush", Int32](
            sh_mem[unsafe_offset=0].stream, _null[NoneType]()
        )
        self.active = False

    def stop(mut self):
        """Full stop: pause + drop sink-side pending audio."""
        self.pause()
        if self.created and self.shared:
            _ = external_call["pa_simple_flush", Int32](
                self.shared.value()[unsafe_offset=0].stream, _null[NoneType]()
            )
        self.active = False

    def is_playing(mut self) -> Bool:
        return self.created and self.active

    # -- data flow ----------------------------------------------------------

    def needs_data(mut self) -> Bool:
        """True when the ring can accept another full DRAIN_FRAMES chunk.
        Mirrors is_audio_stream_processed."""
        if not self.created or not self.shared:
            return False
        var sh_mem = self.shared.value()
        with sh_mem[unsafe_offset=0].state.lock() as p:
            var free = (
                sh_mem[unsafe_offset=0].capacity - p[unsafe_offset=0].used
            )
            return free >= DRAIN_FRAMES * BYTES_PER_FRAME

    def write_pcm(
        self, src: Pointer[NoneType, MutUntrackedOrigin], frames: Int
    ):
        """Memcpy a chunk into the ring. Caller guarantees frames <=
        DRAIN_FRAMES and calls needs_data() first. The initial bytes are
        pre-scaled for volume (cheap: 4096 frames per 16ms tick)."""
        if not self.created or not self.shared:
            return
        var sh_mem = self.shared.value()
        var nbytes = frames * BYTES_PER_FRAME
        if nbytes == 0:
            return

        # scale volume on the way in (reader applies to its copy too, but a
        # chunk only passes through here once)
        var src_bytes = src.unsafe_bitcast[Byte]()
        with sh_mem[unsafe_offset=0].state.lock() as p:
            var sh_vol = p[unsafe_offset=0].volume
            if sh_vol != 1.0:
                var f = src_bytes.unsafe_bitcast[Float32]()
                for i in range(frames * CHANNELS):
                    f[unsafe_offset=i] = f[unsafe_offset=i] * sh_vol

        with sh_mem[unsafe_offset=0].state.lock() as p:
            var write_pos = p[unsafe_offset=0].write_pos
            var capacity = sh_mem[unsafe_offset=0].capacity
            var ring = sh_mem[unsafe_offset=0].ring
            var wrapped = write_pos + nbytes - capacity
            if wrapped <= 0:
                var dst = Pointer[Byte, MutUntrackedOrigin](
                    unsafe_from_address=Int(ring) + write_pos
                )
                unsafe_memcpy(dest=dst, src=src_bytes, count=nbytes)
            else:
                var head = capacity - write_pos
                var dst1 = Pointer[Byte, MutUntrackedOrigin](
                    unsafe_from_address=Int(ring) + write_pos
                )
                unsafe_memcpy(dest=dst1, src=src_bytes, count=head)
                unsafe_memcpy(
                    dest=ring,
                    src=Pointer[Byte, MutUntrackedOrigin](
                        unsafe_from_address=Int(src_bytes) + head
                    ),
                    count=nbytes - head,
                )
            p[unsafe_offset=0].write_pos = (write_pos + nbytes) % capacity
            p[unsafe_offset=0].used += nbytes

    def set_volume(self, v: Float64):
        """Volume is applied on PCM data flowing through; nothing touches
        the pulse server-side sink volume (mirrors per-stream volume)."""
        if not self.created or not self.shared:
            return
        var sh_mem = self.shared.value()
        var clamped = v
        if clamped < 0.0:
            clamped = 0.0
        if clamped > 4.0:
            clamped = 4.0
        with sh_mem[unsafe_offset=0].state.lock() as p:
            p[unsafe_offset=0].volume = Float32(clamped)

    def frames_in_flight(self) -> Int:
        """Approximate buffered frames (ring only; pulse-side latency not
        included). Diagnostic/useful for time-sync tuning."""
        if not self.created or not self.shared:
            return 0
        var sh_mem = self.shared.value()
        with sh_mem[unsafe_offset=0].state.lock() as p:
            return p[unsafe_offset=0].used // BYTES_PER_FRAME
