"""Gamepad input via raw evdev — reads /dev/input/eventNN directly.

The Wayland stack has no joystick API, so gamepad support reads the evdev
device node for the handheld's virtual controller (hhd "Xbox Elite"). The
device is discovered by scanning /proc/bus/input/devices for a handler whose
name heuristics match a gamepad (rejects keyboards/pointing devices by
capability bits), defaulting to any device with an ABS_HAT0 axis and a large
KEY bitmap.

Design (proven pthread pattern from platform/audio_backend.mojo):
- A reader thread does blocking read(2) on the event fd, decodes the
  input_event structs (24 bytes on x86_64: tv_sec 8, tv_usec 8, type u16,
  code u16, value i32), and updates two lock-protected masks:
    down  mask — button currently held
    edge  mask — button pressed since the last end_frame() (cleared by the
                 UI thread once per frame, mirroring WindowInput edges)
- last_button records the most recent press for the settings rebinder.
"""
from std.ffi import (
    c_int,
    c_uint,
    c_ulong,
    external_call,
)
from std.memory import stack_allocation, alloc, Layout, dealloc, ThinAllocation
from std.memory.unsafe_pointer import Pointer
from std.collections import List, Optional
from std.pathlib import Path
from std.os import path

from functions.mutex import Mutex
from platform.ffi import (
    c_read,
    c_close,
    pthread_create,
    pthread_join,
    c_null,
)

# --- joystick (js0) structs / constants -------------------------------------
# hhd's virtual "Xbox Elite" is SILENT on the evdev EV_KEY layer; it only
# speaks via /dev/input/js0 (Linux joystick API). js_event (x86_64):
#   struct js_event { __u32 time; __s16 value; __u8 type; __u8 number; }
#   = 4 + 2 + 1 + 1 pad = 8 bytes.
comptime JS_EVENT_BYTES = 8
comptime JS_TYPE_BUTTON = 0x01
comptime JS_TYPE_AXIS = 0x02
comptime JS_TYPE_INIT = 0x80
comptime JS_AXIS_HAT_X = 16  # standard js axis numbering for ABS_HAT0X
comptime JS_AXIS_HAT_Y = 17  # ... and ABS_HAT0Y
comptime GAMEPAD_NAME = "Xbox Elite"

# JSIOCGAXMAP — read the js axis map (64 bytes: js axis i -> ABS code).
comptime JSIOCGAXMAP = 0x80406A32
# ABS codes for the axes the reader needs.
comptime ABS_X = 0x00
comptime ABS_Y = 0x01
comptime ABS_HAT0X_CODE = 0x10
comptime ABS_HAT0Y_CODE = 0x11

# Standard Linux joystick button numbering for Xbox-layout pads:
# 0=A 1=B 2=X 3=Y 4=LB 5=RB 6=view 7=menu.
comptime DPAD_UP_CODE = 9001
comptime DPAD_DOWN_CODE = 9002
comptime DPAD_LEFT_CODE = 9003
comptime DPAD_RIGHT_CODE = 9004

# Left-stick navigation: the stick's analog axes (raw ±32767 on the js
# event numbers resolved at open() from JSIOCGAXMAP — ABS_X/ABS_Y for
# real pads) drive the same dpad-style codes (rising-edge presses
# through a hysteresis pair, so a noisy stick near the threshold can't
# double-fire). Diagonal pushes engage two directions at once.
comptime STICK_ENGAGE_VAL = 16000  # ~50% push to engage
comptime STICK_RELEASE_VAL = 9000  # ~27% to release (hysteresis band)


# --- js axis map resolution --------------------------------------------------


struct JsAxisMap(Copyable, ImplicitlyCopyable, Movable):
    """Which js event numbers carry the left stick and the dpad hat.

    joydev packs axes sequentially and the numbering is device-specific:
    this pad (six analog axes + hat) puts ABS_HAT0X/Y at 6/7 — NOT the
    16/17 the reader originally hardcoded (never true for xpad-style
    pads), which is why dpad navigation never fired. Resolved once per
    open() via JSIOCGAXMAP with conventional fallbacks."""

    var stick_x: Int32
    var stick_y: Int32
    var hat_x: Int32
    var hat_y: Int32

    def __init__(out self):
        self.stick_x = Int32(0)
        self.stick_y = Int32(1)
        self.hat_x = Int32(16)
        self.hat_y = Int32(17)


def _resolve_js_axes(fd: Int32) -> JsAxisMap:
    """Query JSIOCGAXMAP (falling back to the conventional numbers when
    the ioctl fails). Unset entries fall back the same way: js axis
    numbers for axes the device lacks are simply not used."""
    var map = JsAxisMap()
    map.stick_x = Int32(-1)
    map.stick_y = Int32(-1)
    map.hat_x = Int32(-1)
    map.hat_y = Int32(-1)

    var buf = stack_allocation[64, UInt8]()
    for i in range(64):
        buf[unsafe_offset=i] = UInt8(0xFF)
    var rc = external_call["ioctl", c_int, num_fixed_args=3](
        fd,
        c_uint(JSIOCGAXMAP),
        rebind[Pointer[NoneType, MutUntrackedOrigin]](buf),
    )
    if rc < 0:
        return map^  # ioctl failed: keep the fallbacks

    for i in range(64):
        var code = Int(buf[unsafe_offset=i])
        if code == ABS_X and map.stick_x < 0:
            map.stick_x = Int32(i)
        elif code == ABS_Y and map.stick_y < 0:
            map.stick_y = Int32(i)
        elif code == ABS_HAT0X_CODE and map.hat_x < 0:
            map.hat_x = Int32(i)
        elif code == ABS_HAT0Y_CODE and map.hat_y < 0:
            map.hat_y = Int32(i)

    if map.stick_x < 0:
        map.stick_x = Int32(0)
    if map.stick_y < 0:
        map.stick_y = Int32(1)
    if map.hat_x < 0:
        map.hat_x = Int32(JS_AXIS_HAT_X)
    if map.hat_y < 0:
        map.hat_y = Int32(JS_AXIS_HAT_Y)
    return map^


# libc file calls: external_call["open"] / ["read"] collide with symbols
# predeclared in std.ffi ('existing function with conflicting signature'
# at legalize time when linked from main). glibc exports __-prefixed
# aliases of the same syscalls — different symbol names, same behavior.
def _open_evdev(path: Pointer[Int8, MutAnyOrigin], flags: c_int) -> Int32:
    # open64 is VARIADIC (`int open64(const char *, int, ...)`) — the mode
    # arg is never passed here (O_RDONLY only), but the fixed-arg count is
    # still an ABI requirement for any C variadic function.
    return external_call["open64", Int32, num_fixed_args=2](path, flags)


# --- reader thread shared state ----------------------------------------------

comptime MASK_WORDS = 16  # codes up to 511 fit in words 0..15 (32 bits each)


struct PadState(Copyable, Movable):
    """Gamepad state guarded by Mutex[PadState]: the down/edge bitmaps are
    INLINE fixed-size storage (Array[UInt32, MASK_WORDS] — sized at comptime
    from MASK_WORDS, no heap indirection), plus the hat axes, the left
    stick's engagement mask, and the last-button record for the settings
    rebinder."""

    var down: Array[UInt32, MASK_WORDS]  # button held
    var edge: Array[UInt32, MASK_WORDS]  # pressed since last end_frame()
    var last_button: Int32
    var hat_x: Int32  # ABS_HAT0X value (-1/0/1)
    var hat_y: Int32  # ABS_HAT0Y value (-1/0/1)
    var stick_x: Int32  # left stick raw axis 0
    var stick_y: Int32  # left stick raw axis 1
    var stick_engage: UInt32  # left-stick engaged-direction bitmask

    def __init__(out self):
        self.down = Array[UInt32, MASK_WORDS](uninitialized=True)
        self.edge = Array[UInt32, MASK_WORDS](uninitialized=True)
        for i in range(MASK_WORDS):
            self.down[i] = 0
            self.edge[i] = 0
        self.last_button = -1
        self.hat_x = 0
        self.hat_y = 0
        self.stick_x = 0
        self.stick_y = 0
        self.stick_engage = 0

    def __copyinit__(mut self, existing: Self):
        # Array is not implicitly copyable — elementwise copy (same shape
        # as PaSampleSpec in audio_backend).
        self.down = Array[UInt32, MASK_WORDS](uninitialized=True)
        self.edge = Array[UInt32, MASK_WORDS](uninitialized=True)
        for i in range(MASK_WORDS):
            self.down[i] = existing.down[i]
            self.edge[i] = existing.edge[i]
        self.last_button = existing.last_button
        self.hat_x = existing.hat_x
        self.hat_y = existing.hat_y
        self.stick_x = existing.stick_x
        self.stick_y = existing.stick_y
        self.stick_engage = existing.stick_engage


# Not Copyable (the Mutex cannot be copied): allocated on the heap in open()
# and freed in close(). The reader thread reaches everything through the
# shared pointer.
struct PadShared(Movable):
    var fd: Int32
    var running: Int32  # reader thread keepalive
    var axes: JsAxisMap  # resolved js event numbers (stick + hat)
    var state: Mutex[PadState]  # guards PadState above

    def __init__(out self, fd: Int32, var axes: JsAxisMap):
        self.fd = fd
        self.running = Int32(1)
        self.axes = axes^
        self.state = Mutex[PadState]()
        self.state.init_with(PadState())


struct JoystickEvent(Copyable, Deinitable, ImplicitlyCopyable, Movable):
    """Raw joystick event (8 bytes: u32 time, s16 value, u8 type, u8 num)."""

    var js_time: UInt32
    var js_value: Int16
    var js_type: UInt8
    var js_number: UInt8


def pad_reader_entry(
    arg: Pointer[NoneType, MutUntrackedOrigin]
) -> Pointer[NoneType, MutUntrackedOrigin]:
    """Reader thread: blocking-read js_event (8B) and maintain the masks.

    The joystick layer stores buttons in the down/edge bitmaps indexed by
     gamepad enum (via _js_to_gamepad), so accessor code stays in
    enum space. Hat axes (16/17) maintain hat_x/hat_y (-1/0/1).
    """
    var sh = Pointer[PadShared, MutUntrackedOrigin](
        unsafe_from_address=Int(arg)
    )
    var ev = stack_allocation[1, JoystickEvent]()
    var ev_bytes = rebind[Pointer[NoneType, MutUntrackedOrigin]](ev)
    while sh[unsafe_offset=0].running == 1:
        var got = c_read(sh[unsafe_offset=0].fd, ev_bytes, JS_EVENT_BYTES)
        if got < Int(JS_EVENT_BYTES):
            continue

        var jtype = Int(ev[unsafe_offset=0].js_type)
        var jnum = Int(ev[unsafe_offset=0].js_number)
        var jval = Int(ev[unsafe_offset=0].js_value)
        # Skip init events (type | 0x80) — they just replay device state.
        if (jtype & JS_TYPE_INIT) != 0:
            continue

        with sh[unsafe_offset=0].state.lock() as p:
            if (jtype & JS_TYPE_BUTTON) != 0:
                var gcode = Int(_js_to_gamepad(jnum))
                if gcode >= 0 and gcode < MASK_WORDS * 32:
                    if jval != 0:
                        var bit = UInt32(1) << UInt32(gcode % 32)
                        p[unsafe_offset=0].down[gcode // 32] |= bit
                        p[unsafe_offset=0].edge[gcode // 32] |= bit
                        p[unsafe_offset=0].last_button = Int32(gcode)
                    else:
                        p[unsafe_offset=0].down[gcode // 32] &= ~(
                            UInt32(1) << UInt32(gcode % 32)
                        )
            elif (jtype & JS_TYPE_AXIS) != 0:
                # Hat (dpad) + left stick: maintain the dpad-style down
                # bits and press edges (the only way dpad/stick presses
                # reach the keybind / nav paths); the stick's analog
                # values run the hysteresis machine.
                var hat_x_num = Int(sh[unsafe_offset=0].axes.hat_x)
                var hat_y_num = Int(sh[unsafe_offset=0].axes.hat_y)
                var st_x_num = Int(sh[unsafe_offset=0].axes.stick_x)
                var st_y_num = Int(sh[unsafe_offset=0].axes.stick_y)
                if jnum == hat_x_num:
                    _set_hat_axis(p[unsafe_offset=0], jval, True)
                elif jnum == hat_y_num:
                    _set_hat_axis(p[unsafe_offset=0], jval, False)
                elif jnum == st_x_num:
                    _set_stick_axis(p[unsafe_offset=0], jval, True)
                elif jnum == st_y_num:
                    _set_stick_axis(p[unsafe_offset=0], jval, False)
    return c_null[NoneType]()


# --- code translation --------------------------------------------------------


def _apply_hat_bits(mut p: PadState, new_x: Int, new_y: Int):
    """Maintain the dpad down bits (codes 1-4) for a new hat position and
    RISING-EDGE presses: a direction newly engaged sets its edge bit once
    (recorded as last_button for the rebinder); disengaging just clears
    the down bit. Level events must not re-press a held direction.

    Raylib LEFT_FACE_* mapping: 1=UP(y-1) 2=RIGHT(x+1) 3=DOWN(y+1)
    4=LEFT(x-1)."""
    var dirs: List[Int] = [1, 2, 3, 4]
    var engaged: List[Bool] = [
        new_y == -1,
        new_x == 1,
        new_y == 1,
        new_x == -1,
    ]
    for i in range(4):
        var gcode = dirs[i]
        var bit = UInt32(1) << UInt32(gcode % 32)
        var was = (p.down[gcode // 32] & bit) != 0
        if engaged[i]:
            p.down[gcode // 32] |= bit
            if not was:
                p.edge[gcode // 32] |= bit
                p.last_button = Int32(gcode)
        else:
            p.down[gcode // 32] &= ~bit


def _set_hat_axis(mut p: PadState, jval: Int, is_x: Bool):
    """Update one hat axis level, then maintain the dpad bits."""
    if is_x:
        if Int(p.hat_x) != jval:
            p.hat_x = Int32(jval)
            _apply_hat_bits(p, jval, Int(p.hat_y))
    else:
        if Int(p.hat_y) != jval:
            p.hat_y = Int32(jval)
            _apply_hat_bits(p, Int(p.hat_x), jval)


def _set_stick_axis(mut p: PadState, jval: Int, is_x: Bool):
    """Update one left-stick raw level, then run the hysteresis machine."""
    if is_x:
        if Int(p.stick_x) != jval:
            p.stick_x = Int32(jval)
            _apply_stick_axes(p, jval, Int(p.stick_y))
    else:
        if Int(p.stick_y) != jval:
            p.stick_y = Int32(jval)
            _apply_stick_axes(p, Int(p.stick_x), jval)


def _apply_stick_axes(mut p: PadState, new_x: Int, new_y: Int):
    """Left-stick navigation into the same dpad-style codes (1=UP
    2=RIGHT 3=DOWN 4=LEFT), through a hysteresis pair: a direction
    engages when its axis passes STICK_ENGAGE_VAL and releases below
    STICK_RELEASE_VAL. Rising edges raise the edge bit + last_button
    (same contract as buttons/hat); released directions clear down.

    Diagonal pushes engage two directions — the engine treats each as a
    step, so a stick-flick moves focus diagonally like a dpad-tap pair.
    """
    var dirs: List[Int] = [1, 2, 3, 4]
    # engage/release thresholds per direction (in / y axis sense)
    var engage: List[Bool] = [
        new_y <= -STICK_ENGAGE_VAL,
        new_x >= STICK_ENGAGE_VAL,
        new_y >= STICK_ENGAGE_VAL,
        new_x <= -STICK_ENGAGE_VAL,
    ]
    var release: List[Bool] = [
        new_y > -STICK_RELEASE_VAL,
        new_x < STICK_RELEASE_VAL,
        new_y < STICK_RELEASE_VAL,
        new_x > -STICK_RELEASE_VAL,
    ]
    for i in range(4):
        var gcode = dirs[i]
        var bit = UInt32(1) << UInt32(gcode % 32)
        var mask_bit = UInt32(1) << UInt32(gcode)
        var was_engaged = (p.stick_engage & mask_bit) != 0
        if not was_engaged and engage[i]:
            # Rising: press.
            p.stick_engage |= mask_bit
            p.down[gcode // 32] |= bit
            p.edge[gcode // 32] |= bit
            p.last_button = Int32(gcode)
        elif was_engaged and release[i]:
            # Falling: release.
            p.stick_engage &= ~mask_bit
            p.down[gcode // 32] &= ~bit


def _js_to_gamepad(js_num: Int) -> Int32:
    """Map a Linux joystick button number to the GAMEPAD_BUTTON_*
    enum values resources/keys.mojo stores (configs were written against
    that table).

    Standard Xbox-layout convention on the Linux joystick layer:
        0=A  1=B  2=X  3=Y  4=LB  5=RB  6=view  7=menu
        RIGHT_FACE_UP=5 (Y), RIGHT_FACE_RIGHT=6 (B),
    """
    if js_num == 0:
        return Int32(7)  # A -> RIGHT_FACE_DOWN
    if js_num == 1:
        return Int32(6)  # B -> RIGHT_FACE_RIGHT
    if js_num == 2:
        return Int32(8)  # X -> RIGHT_FACE_LEFT
    if js_num == 3:
        return Int32(5)  # Y -> RIGHT_FACE_UP
    if js_num == 4:
        return Int32(9)  # LB -> LEFT_TRIGGER_1
    if js_num == 5:
        return Int32(11)  # RB -> RIGHT_TRIGGER_1
    if js_num == 6:
        return Int32(13)  # view -> MIDDLE_LEFT
    if js_num == 7:
        return Int32(14)  # menu -> MIDDLE
    if js_num == 8:
        return Int32(16)  # left thumb (if present)
    if js_num == 9:
        return Int32(17)  # right thumb (if present)
    return Int32(-1)  # unmapped button number


def _gamepad_to_js_num(gamepad_code: Int) -> Int:
    """Inverse of _js_to_gamepad; -1 = not a KEY button (dpad is hat)."""
    if gamepad_code == 7:
        return 0
    if gamepad_code == 6:
        return 1
    if gamepad_code == 8:
        return 2
    if gamepad_code == 5:
        return 3
    if gamepad_code == 9:
        return 4
    if gamepad_code == 11:
        return 5
    if gamepad_code == 13:
        return 6
    if gamepad_code == 14:
        return 7
    if gamepad_code == 16:
        return 8
    if gamepad_code == 17:
        return 9
    return Int(-1)


# --- pad device + lifecycle ---------------------------------------------------


struct Gamepad(Copyable, Deinitable, Movable):
    """Evdev-backed gamepad reader.

    open() discovers the pad by name (hhd virtual "Xbox Elite"; fallback:
    any event device whose caps include ABS_HAT0X), spawns a reader thread
    that maintains held (down) and pressed-this-frame (edge) button masks,
    and exposes enum accessors for imui/settings. end_frame() clears
    the edge mask once per UI frame (same pending_clear model as the
    keyboard path).
    """

    var shared: Optional[Pointer[PadShared, MutUntrackedOrigin]]
    var fd: Int32
    var tid: c_ulong  # pthread handle
    var running: Bool
    var open_ok: Bool

    def __init__(out self):
        self.shared = Optional[Pointer[PadShared, MutUntrackedOrigin]]()
        self.fd = -1
        self.tid = 0
        self.running = False
        self.open_ok = False

    def __copyinit__(mut self, existing: Self):
        self.shared = existing.shared
        self.fd = existing.fd
        self.tid = existing.tid
        self.running = existing.running
        self.open_ok = existing.open_ok

    def open(mut self) raises -> Bool:
        """Discover + open the pad device and start the reader thread."""
        if self.open_ok:
            return True
        var node = _find_pad_event_node()
        if node.byte_length() == 0:
            return False
        var mutnode = String(node)
        var cs = mutnode.as_c_string_span()
        var fd = _open_evdev(rebind[Pointer[Int8, MutAnyOrigin]](cs), 0)
        if fd < 0:
            return False
        self.fd = fd

        # shared state block (heap: reader thread lives beyond this call).
        # The Mutex owns the PadState — down/edge masks are inline Array
        # storage inside it. The js axis map (stick/hat event numbers) is
        # resolved once here; the reader thread only reads it.
        var axes = _resolve_js_axes(Int32(fd))
        var sh_ptr = alloc(Layout[PadShared](count=1)).unsafe_leak()
        sh_ptr.unsafe_write(PadShared(Int32(fd), axes^))

        self.shared = Optional[Pointer[PadShared, MutUntrackedOrigin]](sh_ptr)

        # pthread handle: libc writes the value before pthread_create
        # returns; the tid is copied out below — a stack out-param cell is
        # the sanctioned idiom, no heap needed.
        var tid_cell = stack_allocation[1, c_ulong]()
        var rc = pthread_create(
            tid_cell,
            pad_reader_entry,
            rebind[Pointer[NoneType, MutUntrackedOrigin]](sh_ptr),
        )
        if rc != 0:
            # Reader never started — no concurrent access, teardown is plain.
            sh_ptr[unsafe_offset=0].running = 0
            sh_ptr[unsafe_offset=0].state.close()
            dealloc(
                ThinAllocation(unsafe_owned_ptr=sh_ptr).unsafe_with_layout(
                    Layout[PadShared](count=1)
                )
            )
            c_close(fd)
            # Reset the stored fd: the socket is closed, and a half-open
            # Gamepad must not report a stale descriptor (parity with
            # close()).
            self.fd = -1
            return False
        self.tid = tid_cell[unsafe_offset=0]
        self.running = True
        self.open_ok = True
        return True

    def close(mut self):
        """Stop the reader, join it, free the mutex + shared block."""
        if not self.open_ok:
            return
        var sh_mem = self.shared.value()
        sh_mem[unsafe_offset=0].running = 0
        pthread_join(self.tid)
        # Reader is joined: tear the mutex down (frees the item and lock
        # boxes), then free the shared block exactly as allocated.
        sh_mem[unsafe_offset=0].state.close()
        dealloc(
            ThinAllocation(unsafe_owned_ptr=sh_mem).unsafe_with_layout(
                Layout[PadShared](count=1)
            )
        )
        c_close(self.fd)
        self.fd = -1
        self.tid = 0
        self.running = False
        self.open_ok = False
        # Clear the optional so no stale shared-pointer survives close
        # (parity with AudioBackend.close()) — is_down/relaunch paths all
        # branch on open_ok, but the pointer is dead the moment the block
        # is freed.
        self.shared = Optional[Pointer[PadShared, MutUntrackedOrigin]]()

    def is_down(mut self, gamepad_code: Int) -> Bool:
        """GAMEPAD_BUTTON_* enum -> held state.

        The reader maintains the down mask for every mapped control in
        enum space; dpad codes (1-4) read the same mask — the hat and
        left-stick machines both write it, so either physical input
        holds the bind."""
        if not self.open_ok:
            return False  # no pad opened: all binds inert
        if gamepad_code < 0 or gamepad_code >= MASK_WORDS * 32:
            return False
        var sh_mem = self.shared.value()
        with sh_mem[unsafe_offset=0].state.lock() as p:
            var bit = p[unsafe_offset=0].down[gamepad_code // 32] & (
                UInt32(1) << UInt32(gamepad_code % 32)
            )
            return bit != 0

    def was_pressed(mut self, gamepad_code: Int) -> Bool:
        """Enum code -> pressed-since-last-end_frame edge.

        The reader writes the edge mask in ENUM space, so read it
        back with the same index (no _gamepad_to_js_num roundtrip — that
        was the index-space mismatch that made edges vanish).
        """
        if gamepad_code < 0 or gamepad_code >= MASK_WORDS * 32:
            return False
        if not self.open_ok:
            return False
        var sh_mem = self.shared.value()
        with sh_mem[unsafe_offset=0].state.lock() as p:
            var bit = p[unsafe_offset=0].edge[gamepad_code // 32] & (
                UInt32(1) << UInt32(gamepad_code % 32)
            )
            return bit != 0

    def last_button(mut self) -> Int:
        """Last pressed enum button (for settings capture). -1 = none.

        The reader stores last_button already in enum space (the
        reader maps through _js_to_gamepad on ingest), so this is a plain
        read."""
        if not self.open_ok:
            return -1  # no pad: nothing was ever pressed
        var sh_mem = self.shared.value()
        with sh_mem[unsafe_offset=0].state.lock() as p:
            return Int(p[unsafe_offset=0].last_button)

    def end_frame(mut self):
        """Clear the pressed-this-frame edge mask (call once per UI frame)."""
        if not self.open_ok:
            return  # no pad: masks don't exist
        var sh_mem = self.shared.value()
        with sh_mem[unsafe_offset=0].state.lock() as p:
            for i in range(MASK_WORDS):
                p[unsafe_offset=0].edge[i] = 0
            p[unsafe_offset=0].last_button = Int32(-1)


def _find_pad_event_node() raises -> String:
    """Locate the gamepad's joystick API node (/dev/input/jsNN).

    The hhd virtual pad is silent on the evdev EV_KEY layer — its events
    only surface through the joystick API device. Discovery order:
    1. /proc/bus/input/devices: find the pad by name, take the "jsN" token
       from its Handlers line (same line that lists eventNN).
    2. Fallback: plain /dev/input/js0 when present.
    Returns "" when nothing usable is found.

    Native implementation: Path.read_bytes() + String scanning — the old
    path booted the Python interpreter just to read /proc.
    """
    try:
        var proc_path = Path("/proc/bus/input/devices")
        if path.exists(proc_path):
            var raw = proc_path.read_bytes()
            var text = String()
            for i in range(len(raw)):
                text += String(chr(Int(raw[i])))
            var blocks = text.split("\n\n")
            for i in range(len(blocks)):
                var blk = blocks[i]
                if blk.find(GAMEPAD_NAME) >= 0:
                    # find the "H: Handlers=... js0 ..." line in this block
                    var lines = blk.split("\n")
                    for j in range(len(lines)):
                        var ln = lines[j]
                        if ln.find("H: Handlers=") >= 0:
                            var words = ln.split(" ")
                            for k in range(len(words)):
                                var w = words[k]
                                if w.find("js") == 0 and w.byte_length() > 2:
                                    return String("/dev/input/") + w
    except e:
        pass
    # Fallback: first default joystick node.
    if path.exists(Path("/dev/input/js0")):
        return String("/dev/input/js0")
    return String("")
