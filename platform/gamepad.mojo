"""Gamepad input via raw evdev — reads /dev/input/eventNN directly.

The Wayland stack has no joystick API, so gamepad support reads the evdev
device node for the handheld's virtual controller (hhd "Xbox Elite"). The
device is discovered by scanning /proc/bus/input/devices for a handler whose
name heuristics match a gamepad (rejects keyboards/pointing devices by
capability bits), defaulting to any device with an ABS_HAT0 axis and a large
KEY bitmap.

Design (proven pthread pattern from functions/audio_backend.mojo):
- A reader thread does blocking read(2) on the event fd, decodes the
  input_event structs (24 bytes on x86_64: tv_sec 8, tv_usec 8, type u16,
  code u16, value i32), and updates two lock-protected masks:
    down  mask — button currently held
    edge  mask — button pressed since the last end_frame() (cleared by the
                 UI thread once per frame, mirroring WindowInput edges)
- last_button records the most recent press for the settings rebinder.
"""
from std.ffi import external_call
from std.python import Python
from std.memory import stack_allocation, alloc, Layout
from std.memory.unsafe_pointer import Pointer
from std.collections import List, Optional

from functions.mutex import Mutex

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

# Standard Linux joystick button numbering for Xbox-layout pads:
# 0=A 1=B 2=X 3=Y 4=LB 5=RB 6=view 7=menu.
comptime DPAD_UP_CODE = 9001
comptime DPAD_DOWN_CODE = 9002
comptime DPAD_LEFT_CODE = 9003
comptime DPAD_RIGHT_CODE = 9004


from platform.ffi import c_null as _null


# libc file calls: external_call["open"] / ["read"] collide with symbols
# predeclared in std.ffi ('existing function with conflicting signature'
# at legalize time when linked from main). glibc exports __-prefixed
# aliases of the same syscalls — different symbol names, same behavior.
def _open_evdev(path: Pointer[Int8, MutAnyOrigin], flags: Int32) -> Int32:
    return external_call["open64", Int32](path, Int(flags))


def _read(fd: Int32, buf: Pointer[NoneType, MutUntrackedOrigin], n: Int) -> Int:
    return external_call["__read", Int](fd, buf, n)


def _close(fd: Int32):
    _ = external_call["close", Int32](fd)


def _pthread_create(
    tid: Pointer[UInt64, MutUntrackedOrigin],
    entry_fn: Pointer[NoneType, MutUntrackedOrigin],
    arg: Pointer[NoneType, MutUntrackedOrigin],
) -> Int32:
    return external_call["pthread_create", Int32](
        tid, _null[NoneType](), entry_fn, arg
    )


def _pthread_join(tid: UInt64):
    _ = external_call["pthread_join", Int32](tid, _null[NoneType]())


# --- reader thread shared state ----------------------------------------------

comptime MASK_WORDS = 16  # codes up to 511 fit in words 0..15 (32 bits each)


struct PadState(Copyable, Movable):
    """Gamepad state guarded by Mutex[PadState]: the down/edge bitmaps (the
    pointers themselves are stable heap allocations set once in open()), the
    hat axes, and the last-button record for the settings rebinder."""

    var down: Pointer[UInt32, MutUntrackedOrigin]  # MASK_WORDS bitmap, held
    var edge: Pointer[UInt32, MutUntrackedOrigin]  # MASK_WORDS bitmap, edge
    var last_button: Int32
    var hat_x: Int32  # ABS_HAT0X value (-1/0/1)
    var hat_y: Int32  # ABS_HAT0Y value (-1/0/1)

    def __init__(out self):
        self.down = Pointer[UInt32, MutUntrackedOrigin](
            unsafe_from_address=Int(0)
        )
        self.edge = Pointer[UInt32, MutUntrackedOrigin](
            unsafe_from_address=Int(0)
        )
        self.last_button = -1
        self.hat_x = 0
        self.hat_y = 0


# Not Copyable (the Mutex cannot be copied): allocated on the heap in open()
# and freed in close(). The reader thread reaches everything through the
# shared pointer.
struct PadShared(Movable):
    var fd: Int32
    var running: Int32  # reader thread keepalive
    var state: Mutex[PadState]  # guards PadState above

    def __init__(out self, fd: Int32):
        self.fd = fd
        self.running = 1
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
        var got = _read(sh[unsafe_offset=0].fd, ev_bytes, JS_EVENT_BYTES)
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
                        var down_w = p[unsafe_offset=0].down
                        var edge_w = p[unsafe_offset=0].edge
                        down_w[unsafe_offset=gcode // 32] = down_w[
                            unsafe_offset=gcode // 32
                        ] | (UInt32(1) << UInt32(gcode % 32))
                        edge_w[unsafe_offset=gcode // 32] = edge_w[
                            unsafe_offset=gcode // 32
                        ] | (UInt32(1) << UInt32(gcode % 32))
                        p[unsafe_offset=0].last_button = Int32(gcode)
                    else:
                        var down_w = p[unsafe_offset=0].down
                        down_w[unsafe_offset=gcode // 32] = down_w[
                            unsafe_offset=gcode // 32
                        ] & ~(UInt32(1) << UInt32(gcode % 32))
            elif (jtype & JS_TYPE_AXIS) != 0:
                if jnum == JS_AXIS_HAT_X:
                    p[unsafe_offset=0].hat_x = Int32(jval)
                elif jnum == JS_AXIS_HAT_Y:
                    p[unsafe_offset=0].hat_y = Int32(jval)
    return _null[NoneType]()


# --- code translation --------------------------------------------------------


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
    inv = {7: 0, 6: 1, 8: 2, 5: 3, 9: 4, 11: 5, 13: 6, 14: 7, 16: 8, 17: 9}
    try:
        var v = inv[gamepad_code]
        return v
    except:
        pass
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
    var tid: UInt64
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
        var cs = mutnode.as_c_string_slice()
        var fd = _open_evdev(rebind[Pointer[Int8, MutAnyOrigin]](cs), 0)
        if fd < 0:
            return False
        self.fd = fd

        # shared state block (heap: reader thread lives beyond this call).
        # The Mutex owns the PadState; the down/edge bitmap allocations it
        # points at are set once here and never change for the pad's life.
        var sh_ptr = alloc(Layout[PadShared](count=1)).unsafe_leak()
        sh_ptr.unsafe_write(PadShared(Int32(fd)))
        var down_mem = alloc(Layout[UInt32](count=MASK_WORDS)).unsafe_leak()
        var edge_mem = alloc(Layout[UInt32](count=MASK_WORDS)).unsafe_leak()
        for i in range(MASK_WORDS):
            down_mem[unsafe_offset=i] = 0
            edge_mem[unsafe_offset=i] = 0
        with sh_ptr[unsafe_offset=0].state.lock() as p:
            p[unsafe_offset=0].down = down_mem
            p[unsafe_offset=0].edge = edge_mem

        self.shared = Optional[Pointer[PadShared, MutUntrackedOrigin]](sh_ptr)
        var tid_mem = alloc(Layout[UInt64](count=1)).unsafe_leak()
        tid_mem.unsafe_write(0)
        var rc = external_call["pthread_create", Int32](
            tid_mem,
            _null[NoneType](),
            pad_reader_entry,
            rebind[Pointer[NoneType, MutUntrackedOrigin]](sh_ptr),
        )
        if rc != 0:
            # Reader never started — no concurrent access, teardown is plain.
            sh_ptr[unsafe_offset=0].running = 0
            sh_ptr[unsafe_offset=0].state.close()
            down_mem.unsafe_free()
            edge_mem.unsafe_free()
            sh_ptr.unsafe_free()
            tid_mem.unsafe_free()
            _close(fd)
            return False
        self.tid = tid_mem[unsafe_offset=0]
        self.running = True
        self.open_ok = True
        return True

    def close(mut self):
        """Stop the reader, join it, free the mutex + masks."""
        if not self.open_ok:
            return
        var sh_mem = self.shared.value()
        sh_mem[unsafe_offset=0].running = 0
        _pthread_join(self.tid)
        # Reader is joined: free the bitmap allocations under the lock, then
        # tear the mutex down.
        with sh_mem[unsafe_offset=0].state.lock() as p:
            p[unsafe_offset=0].down.unsafe_free()
            p[unsafe_offset=0].edge.unsafe_free()
        sh_mem[unsafe_offset=0].state.close()
        sh_mem.unsafe_free()
        _close(self.fd)
        self.fd = -1
        self.tid = 0
        self.running = False
        self.open_ok = False

    def is_down(mut self, gamepad_code: Int) -> Bool:
        """GAMEPAD_BUTTON_* enum -> held state.

        The reader stores both masks indexed by the enum value
        (gcode from _js_to_gamepad), so no inverse mapping is needed here.
        Dpad buttons (1-4) are not js buttons; they read the hat axes.
        """
        if not self.open_ok:
            return False  # no pad opened: all binds inert
        if gamepad_code >= 1 and gamepad_code <= 4:
            if gamepad_code == 1:
                return self._hat_down(0, -1)
            if gamepad_code == 2:
                return self._hat_down(0, 1)
            if gamepad_code == 3:
                return self._hat_down(1, -1)
            if gamepad_code == 4:
                return self._hat_down(1, 1)
            return False
        if gamepad_code < 0 or gamepad_code >= MASK_WORDS * 32:
            return False
        var sh_mem = self.shared.value()
        with sh_mem[unsafe_offset=0].state.lock() as p:
            var bit = p[unsafe_offset=0].down[
                unsafe_offset=gamepad_code // 32
            ] & (UInt32(1) << UInt32(gamepad_code % 32))
            return bit != 0

    def was_pressed(mut self, gamepad_code: Int) -> Bool:
        """enum -> pressed-since-last-end_frame edge.

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
            var bit = p[unsafe_offset=0].edge[
                unsafe_offset=gamepad_code // 32
            ] & (UInt32(1) << UInt32(gamepad_code % 32))
            return bit != 0

    def _hat_down(mut self, axis: Int, direction: Int) -> Bool:
        """True if the stored hat position for `axis` equals `direction`."""
        if not self.open_ok:
            return False
        var sh_mem = self.shared.value()
        with sh_mem[unsafe_offset=0].state.lock() as p:
            if axis == 0:
                return Int(p[unsafe_offset=0].hat_x) == direction
            return Int(p[unsafe_offset=0].hat_y) == direction

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
                p[unsafe_offset=0].edge[unsafe_offset=i] = 0
            p[unsafe_offset=0].last_button = Int32(-1)


def _find_pad_event_node() raises -> String:
    """Locate the gamepad's joystick API node (/dev/input/jsNN).

    The hhd virtual pad is silent on the evdev EV_KEY layer — its events
    only surface through the joystick API device. Discovery order:
    1. /proc/bus/input/devices: find the pad by name, take the "jsN" token
       from its Handlers line (same line that lists eventNN).
    2. Fallback: plain /dev/input/js0 when present.
    Returns "" when nothing usable is found.
    """
    var builtins = Python.import_module("builtins")
    try:
        var text = builtins.open("/proc/bus/input/devices").read()
        var blocks = text.split("\n\n")
        for i in range(len(blocks)):
            var blk = String(blocks[i])
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
    try:
        if builtins.os.path.exists("/dev/input/js0"):
            return String("/dev/input/js0")
    except e:
        pass
    return String("")


def null_gamepad_ptr() -> Pointer[Gamepad, MutUntrackedOrigin]:
    """NULL Gamepad pointer for UIContext's defaulted gamepad parameter.

    Built with the address-8-minus-8 trick (Pointer is non-nullable
    on Mojo 1.0.0); UIContext checks Int(ptr) == 0 before dereferencing.
    """
    var tmp = Pointer[Int, MutAnyOrigin](unsafe_from_address=8)
    var base = Pointer[Int8, MutUntrackedOrigin](
        unsafe_from_address=Int(tmp) - 8
    )
    return rebind[Pointer[Gamepad, MutUntrackedOrigin]](base)
