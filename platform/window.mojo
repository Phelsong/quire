# platform/window.mojo — Wayland window + wl_shm framebuffer
#
# Wraps the wayland package (mojo-wayland bindings) into a small API the app
# loop drives each frame:
#   - Window.open(title, width, height)  : connect + xdg handshake + shm pool
#   - window.pixels() → Pointer[UInt8]  (ARGB8888, rows of `stride` bytes)
#   - window.flush()                      : damage whole surface + commit
#   - window.poll() -> Bool               : dispatch events; False = close
#   - window.close()                      : munmap + disconnect
#
from std.ffi import external_call
from std.ffi import c_int, c_ulong
from std.memory.unsafe_pointer import Pointer

from platform.ffi import (
    c_null as _null,
    c_close,
    c_munmap,
    c_ftruncate,
    c_mmap,
    c_memfd_create,
    c_memcmp_same as _c_memcmp_same,
    PROT_READ,
    PROT_WRITE,
    MAP_SHARED,
)
from platform.wl_args import (
    wlstring as _wlstring,
    arg_as_string as _arg_as_string,
    arg_as_u32 as _arg_as_u32,
    arg_as_i32 as _arg_as_i32,
    arg_as_fixed as _arg_as_fixed,
    free_string_arg as _free_string_arg,
)

from wayland.core import (
    WLPtr,
    WLArgument,
    MAX_EVENT_ARGS,
    shim_interface,
    wl_display_connect,
    wl_display_disconnect,
    wl_display_dispatch,
    wl_display_dispatch_pending,
    wl_display_flush,
    wl_display_get_fd,
    wl_display_roundtrip,
    stack_allocation,
)
from wayland.gen.wayland import (
    wl_display_get_registry,
    wl_registry_bind,
    wl_registry_listen,
    wl_registry_next_global,
    SHM_FORMAT_ARGB8888,
    wl_compositor_create_surface,
    wl_shm_create_pool,
    wl_shm_pool_create_buffer,
    wl_surface_attach,
    wl_surface_damage,
    wl_surface_commit,
    wl_seat_get_pointer,
    wl_seat_get_keyboard,
    wl_seat_get_touch,
    wl_pointer_listen,
    wl_pointer_next_enter,
    wl_pointer_next_leave,
    wl_pointer_next_motion,
    wl_pointer_next_button,
    wl_pointer_next_axis,
    wl_keyboard_listen,
    wl_keyboard_next_enter,
    wl_keyboard_next_leave,
    wl_keyboard_next_key,
    wl_touch_listen,
    wl_touch_next_down,
    wl_touch_next_up,
    wl_touch_next_motion,
)
from wayland.gen.xdg_shell import (
    xdg_wm_base_get_xdg_surface,
    xdg_wm_base_pong,
    xdg_wm_base_listen,
    xdg_wm_base_next_ping,
    xdg_surface_get_toplevel,
    xdg_surface_ack_configure,
    xdg_surface_listen,
    xdg_surface_next_configure,
    xdg_toplevel_listen,
    xdg_toplevel_next_configure,
    xdg_toplevel_next_close,
    xdg_toplevel_set_maximized,
    xdg_toplevel_set_title,
)
from wayland.gen.xdg_decoration_unstable_v1 import (
    ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE,
    zxdg_decoration_manager_v1_get_toplevel_decoration,
    zxdg_toplevel_decoration_v1_listen,
    zxdg_toplevel_decoration_v1_next_configure,
    zxdg_toplevel_decoration_v1_set_mode,
)


# --- tiny libc bindings moved to platform.ffi (shared with the tests) ----


# libc poll(2) constants (POLLIN; -1 = block indefinitely)
comptime POLLIN = 0x001
comptime POLL_TIMEOUT_BLOCK = -1

# Frame pacing: the poll(2) timeout bounds the frame interval. 33ms ≈ 30fps —
# dropping the rate from ~60fps because the player screen showed rendering
# artifacts from very frequent buffer re-attach/commits (Hyprland races the
# repaints); 30fps is plenty for a UI.
comptime FRAME_TIMEOUT_MS = c_int(33)


struct PollFd(Copyable, ImplicitlyCopyable, Movable):
    """libc struct pollfd (linux x86_64: int fd; short events; short revents).
    """

    var fd: Int32
    var events: Int16
    var revents: Int16

    def __init__(out self):
        self.fd = -1
        self.events = 0
        self.revents = 0


def _evdev_to_glfw(code: Int) -> Int32:
    """Translate evdev key codes to the GLFW values resources/keys.mojo
    stores. Unmapped codes pass through so unknown keys still arrive."""
    if code == 1:
        return 256  # ESC
    # Digits row: evdev 2..10 = keys 1..9 → GLFW 49..57; evdev 11 = 0 → 48.
    if code >= 2 and code <= 10:
        return Int32(48 + (code - 2))
    if code == 11:
        return 48  # KEY_ZERO
    if code == 12:
        return 45  # KEY_MINUS
    if code == 13:
        return 61  # KEY_EQUAL
    if code == 14:
        return 259  # BACKSPACE
    if code == 15:
        return 258  # TAB
    if code == 28:
        return 257  # ENTER
    if code == 29:
        return 341  # LEFT_CONTROL
    if code == 41:
        return 96  # GRAVE
    if code == 42:
        return 340  # LEFT_SHIFT
    # QWERTY row: q w e r t y u i o p → evdev 16..25 → GLFW 81 87 69 82 84 89 85 73 79 80
    if code == 16:
        return 81
    if code == 17:
        return 87
    if code == 18:
        return 69
    if code == 19:
        return 82
    if code == 20:
        return 84
    if code == 21:
        return 89
    if code == 22:
        return 85
    if code == 23:
        return 73
    if code == 24:
        return 79
    if code == 25:
        return 80
    # Brackets etc: [ 26→91, ] 27→93, \ 43→92
    if code == 26:
        return 91
    if code == 27:
        return 93
    if code == 43:
        return 92
    # HOME row: a s d f g h j k l → evdev 30..38 → GLFW 65 83 68 70 71 72 74 75 76
    if code == 30:
        return 65
    if code == 31:
        return 83
    if code == 32:
        return 68
    if code == 33:
        return 70
    if code == 34:
        return 71
    if code == 35:
        return 72
    if code == 36:
        return 74
    if code == 37:
        return 75
    if code == 38:
        return 76
    if code == 39:
        return 59  # semicolon
    if code == 40:
        return 39  # apostrophe
    # BOTTOM row: z x c v b n m → evdev 44..50 → GLFW 90 88 67 86 66 78 77
    if code == 44:
        return 90
    if code == 45:
        return 88
    if code == 46:
        return 67
    if code == 47:
        return 86
    if code == 48:
        return 66
    if code == 49:
        return 78
    if code == 50:
        return 77
    if code == 51:
        return 44  # comma
    if code == 52:
        return 46  # period
    if code == 53:
        return 47  # slash
    if code == 54:
        return 344  # RIGHT_SHIFT
    if code == 56:
        return 342  # LEFT_ALT
    if code == 57:
        return 32  # SPACE
    if code == 97:
        return 345  # RIGHT_CONTROL
    if code == 100:
        return 346  # RIGHT_ALT
    if code == 111:
        return 261  # DELETE
    if code == 103:
        return 265  # UP
    if code == 104:
        return 264  # LEFT
    if code == 105:
        return 263  # DOWN
    if code == 106:
        return 262  # RIGHT
    if code == 110:
        return 260  # INSERT
    return Int32(code)


struct GlobalInfo(Copyable, Movable):
    var name: UInt32
    var version: UInt32

    def __init__(out self, name: UInt32, version: UInt32):
        self.name = name
        self.version = version


def _find_globals(
    queue: WLPtr, display: WLPtr, wants: List[String]
) raises -> List[GlobalInfo]:
    """Scan registry globals once for several interfaces.

    Globals are announced exactly once per registry, in one startup burst;
    a sequential find-and-discard loop (find A, then find B) silently eats
    B's announcement while waiting for A's successors. This scans until
    every requested interface is claimed or the burst ends, so optional
    protocols announced early survive to be bound.

    Returns infos in the same order as `wants`; a name the compositor
    doesn't offer comes back as name=0."""
    var found = List[GlobalInfo]()
    var want_count = len(wants)
    for _make in range(want_count):
        found.append(GlobalInfo(0, 0))

    var remaining = len(wants)
    var args = stack_allocation[MAX_EVENT_ARGS, WLArgument]()
    # The burst is bounded: a handful of roundtrips collects a complete
    # announcement list from any compositor (or proves it done).
    for _attempt in range(20):
        while wl_registry_next_global(queue, args):
            var iface_name = _arg_as_string(args[unsafe_offset=1])
            for want_idx in range(len(wants)):
                if iface_name == wants[want_idx] and found[want_idx].name == 0:
                    found[want_idx] = GlobalInfo(
                        _arg_as_u32(args[unsafe_offset=0]),
                        _arg_as_u32(args[unsafe_offset=2]),
                    )
                    remaining -= 1
            _free_string_arg(args[unsafe_offset=1])
            if remaining == 0:
                return found^
        # Pump what's still in flight without ever blocking on an idle
        # socket (dispatch would block forever once the burst is over;
        # roundtrip always returns).
        _ = wl_display_roundtrip(display)
        _ = wl_display_dispatch_pending(display)
    return found^


def _find_global(
    queue: WLPtr, display: WLPtr, want: String
) raises -> GlobalInfo:
    """Returns (name, version) for a global; dispatches while looking."""
    var args = stack_allocation[MAX_EVENT_ARGS, WLArgument]()
    while True:
        while wl_registry_next_global(queue, args):
            var iface_name = _arg_as_string(args[unsafe_offset=1])
            var is_want = iface_name == want
            _free_string_arg(args[unsafe_offset=1])
            if is_want:
                return GlobalInfo(
                    _arg_as_u32(args[unsafe_offset=0]),
                    _arg_as_u32(args[unsafe_offset=2]),
                )
        var n = wl_display_dispatch(display)
        if n <= 0:
            raise Error("failed to read registry events")


struct Frame(Copyable, Movable):
    """One mmap'd wl_shm frame buffer. Pixels are ARGB8888 little-endian
    (B,G,R,X byte order); rows are `stride` bytes apart."""

    var fd: Int32
    var pool: WLPtr
    var buffer: WLPtr
    var data: WLPtr
    var width: Int
    var height: Int
    var stride: Int
    var size: Int

    def __init__(out self):
        self.fd = -1
        self.pool = _null[NoneType]()
        self.buffer = _null[NoneType]()
        self.data = _null[NoneType]()
        self.width = 0
        self.height = 0
        self.stride = 0
        self.size = 0

    def __copyinit__(mut self, existing: Self):
        self.fd = existing.fd
        self.pool = existing.pool
        self.buffer = existing.buffer
        self.data = existing.data
        self.width = existing.width
        self.height = existing.height
        self.stride = existing.stride
        self.size = existing.size

    @staticmethod
    def _build(
        width: Int, height: Int, shm: WLPtr, surface: WLPtr
    ) raises -> Frame:
        """Allocate a fresh memfd + shm pool + ARGB8888 buffer and attach it.
        Used by open() and resize(). Caller keeps ownership of the fd via the
        pool (the fd is closed right after the pool is created)."""
        var fd = c_memfd_create("quire-wl".as_c_string_span(), 0)
        if fd < 0:
            raise Error("wayland: memfd_create failed")
        var stride = width * 4
        var size = stride * height
        _ = c_ftruncate(fd, size)
        var pixels = c_mmap(0, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        # mmap signals failure with MAP_FAILED = (void*)-1, NOT a null
        # pointer — the null check everyone reaches for here never fires
        # and a failed mmap would segfault on the first pixel write.
        if Int(pixels) == -1:
            # mmap failed: the memfd is still ours — close it before raising,
            # or every failed resize leaks an fd.
            c_close(fd)
            raise Error("wayland: mmap failed")
        var pool = wl_shm_create_pool(shm, fd, Int32(size))
        var buffer = wl_shm_pool_create_buffer(
            pool,
            0,
            Int32(width),
            Int32(height),
            Int32(stride),
            SHM_FORMAT_ARGB8888,
        )
        c_close(fd)
        var frame = Frame()
        frame.fd = -1  # fd consumed by the pool; munmap data on close only
        frame.pool = pool
        frame.buffer = buffer
        frame.data = pixels
        frame.width = width
        frame.height = height
        frame.stride = stride
        frame.size = size
        return frame^


# Window-relative input state fed by wl_seat events. Mirrors the fields
# UIContext reads (mouse pose + button state, key events, wheel delta), with
# GLFW keycodes
#
# Key-event queue capacity. 32 slots ≈ 32 presses inside one 16-33ms
# frame (≈1000 cps sustained) — no real keyboard does that; on overflow
# the OLDEST queued press is dropped so consumers always see the recent
# tail. (The old single-slot model dropped every event but the very last
# instead, which swallowed keystrokes whenever a frame ran long.) Presses
# queue inline — no heap, no allocation per event.
comptime KEY_QUEUE_CAP = 32


struct WindowInput(Copyable, Movable):
    var mouse_x: Float64
    var mouse_y: Float64
    var mouse_down: Bool
    var mouse_pressed: Bool
    # Frame-scoped ring of pressed keys (inline slots — no heap churn per
    # event): poll() appends each press; consumers drain it per frame; the
    # ring resets with the other press edges at the start of the next poll
    # (pending_clear). Releases update `last_event_key` but don't queue —
    # no consumer reads release edges.
    var key_ring: Array[Int32, KEY_QUEUE_CAP]
    var key_ring_head: Int  # oldest queued event (ring buffer)
    var key_ring_count: Int  # events queued this frame
    # Cross-frame "most recent key event" (press OR release — never
    # cleared by pending_clear): the key_down() held-modifier
    # approximation reads this, since a held key emits one press and no
    # events until released or replaced by a newer event.
    var last_event_key: Int32
    var any_key_pressed: Bool
    var wheel_delta: Float64
    # True while the window has keyboard focus (wl_keyboard enter/leave).
    # Gamepad input is only honored while focused.
    var focused: Bool
    # Touch-origin tracking (for drag-to-scroll): True when the current
    # press came from wl_touch_down rather than a pointer button. Mouse
    # presses fire actions on the press edge; touch presses instead record
    # intent and complete on release (tap = activate, drag = scroll).
    var press_is_touch: Bool
    # Surface position where the current touch drag began (screen px).
    var touch_start_x: Float64
    var touch_start_y: Float64
    # internal edge bookkeeping
    var pending_clear: Bool

    def __init__(out self):
        self.mouse_x = 0.0
        self.mouse_y = 0.0
        self.mouse_down = False
        self.mouse_pressed = False
        self.key_ring = Array[Int32, KEY_QUEUE_CAP]()
        self.key_ring_head = 0
        self.key_ring_count = 0
        self.last_event_key = 0
        self.any_key_pressed = False
        self.wheel_delta = 0.0
        self.focused = False
        self.press_is_touch = False
        self.touch_start_x = 0.0
        self.touch_start_y = 0.0
        self.pending_clear = False

    def __copyinit__(mut self, existing: Self):
        self.mouse_x = existing.mouse_x
        self.mouse_y = existing.mouse_y
        self.mouse_down = existing.mouse_down
        self.mouse_pressed = existing.mouse_pressed
        self.key_ring = existing.key_ring.copy()
        self.key_ring_head = existing.key_ring_head
        self.key_ring_count = existing.key_ring_count
        self.last_event_key = existing.last_event_key
        self.any_key_pressed = existing.any_key_pressed
        self.wheel_delta = existing.wheel_delta
        self.focused = existing.focused
        self.press_is_touch = existing.press_is_touch
        self.touch_start_x = existing.touch_start_x
        self.touch_start_y = existing.touch_start_y
        self.pending_clear = existing.pending_clear

    def queue_key_event(mut self, key: Int32, pressed: Bool):
        """Record one raw key event (poll-side, one call per Wayland event).

        Presses AND releases update `last_event_key` (key_down()'s
        held-modifier approximation); only presses join this frame's ring.
        On overflow the oldest press is dropped (see KEY_QUEUE_CAP)."""
        self.last_event_key = key
        if not pressed:
            return
        if self.key_ring_count == KEY_QUEUE_CAP:
            self.key_ring_head = (self.key_ring_head + 1) % KEY_QUEUE_CAP
            self.key_ring_count -= 1
        self.key_ring[
            (self.key_ring_head + self.key_ring_count) % KEY_QUEUE_CAP
        ] = key
        self.key_ring_count += 1

    def frame_key_press(self, j: Int) -> Int32:
        """The j-th queued press of this frame, oldest first (j < count)."""
        return self.key_ring[(self.key_ring_head + j) % KEY_QUEUE_CAP]

    def frame_key_pressed(self, code: Int) -> Bool:
        """True if `code` was pressed among this frame's queued events.

        Scans the WHOLE ring, so every press the frame collected is
        visible — not just one (coalescing in the old single-slot model
        dropped all but the last). Non-consuming: other consumers may
        still test other codes against the same events this frame."""
        for j in range(self.key_ring_count):
            if Int(self.frame_key_press(j)) == code:
                return True
        return False

    def clear_frame_keys(mut self):
        """Empty the frame's event ring (next-poll edge reset)."""
        self.key_ring_head = 0
        self.key_ring_count = 0


# Wayland window + framebuffer. One per process.
struct Window(Copyable, Movable):
    var display: WLPtr
    var compositor: WLPtr
    var shm: WLPtr
    var wm_base: WLPtr
    var surface: WLPtr
    var xdg_surface: WLPtr
    var toplevel: WLPtr
    # xdg-decoration (server-side title bar). decoration_manager null when
    # the compositor doesn't advertise the protocol — all decoration calls
    # guard on it, so compositors without it fall back to client chrome.
    var decoration_manager: WLPtr
    var toplevel_decoration: WLPtr
    var deco_queue: WLPtr
    # Latest decoration configure mode (SERVER_SIDE / CLIENT_SIDE); the
    # configure must be acked by committing after it, which present() does.
    var decoration_mode: UInt32
    var xs_queue: WLPtr
    var top_queue: WLPtr
    var wm_queue: WLPtr
    var pointer: WLPtr
    var keyboard: WLPtr
    var touch: WLPtr
    var pt_queue: WLPtr
    var kb_queue: WLPtr
    var tch_queue: WLPtr
    var input: WindowInput
    var frame: Frame
    # Second buffer for double-buffering: the app draws into `draw` while the
    # compositor shows `frame`; present() swaps them after a changed-content
    # commit. Eliminates tearing (compositor never reads the buffer being
    # written) and lets present() skip commits entirely when nothing changed.
    var back: Frame
    # True after present() committed because content differed; False when the
    # draw buffer matched the shown one (no commit issued).
    var committed_last_frame: Bool
    var open_ok: Bool
    # Resize bookkeeping: poll() sets pending_resize when a toplevel configure
    # announces dimensions different from the current frame buffer; main()
    # then calls rebuild_frame(new_w, new_h) before the next present().
    var pending_resize: Bool
    var pending_resize_w: Int
    var pending_resize_h: Int
    # Serial from the latest xdg_surface.configure; consumed by
    # rebuild_frame()'s ack (configure must be acked before attach in some
    # compositors).
    var xdg_ack_configure_serial: UInt32

    def __init__(out self):
        self.display = _null[NoneType]()
        self.compositor = _null[NoneType]()
        self.shm = _null[NoneType]()
        self.wm_base = _null[NoneType]()
        self.surface = _null[NoneType]()
        self.xdg_surface = _null[NoneType]()
        self.toplevel = _null[NoneType]()
        self.decoration_manager = _null[NoneType]()
        self.toplevel_decoration = _null[NoneType]()
        self.deco_queue = _null[NoneType]()
        self.decoration_mode = UInt32(0)
        self.xs_queue = _null[NoneType]()
        self.top_queue = _null[NoneType]()
        self.wm_queue = _null[NoneType]()
        self.pointer = _null[NoneType]()
        self.keyboard = _null[NoneType]()
        self.touch = _null[NoneType]()
        self.pt_queue = _null[NoneType]()
        self.kb_queue = _null[NoneType]()
        self.tch_queue = _null[NoneType]()
        self.input = WindowInput()
        self.frame = Frame()
        self.back = Frame()
        self.committed_last_frame = False
        self.open_ok = False
        self.pending_resize = False
        self.pending_resize_w = 0
        self.pending_resize_h = 0
        self.xdg_ack_configure_serial = UInt32(0)

    def __copyinit__(mut self, existing: Self):
        self.display = existing.display
        self.compositor = existing.compositor
        self.shm = existing.shm
        self.wm_base = existing.wm_base
        self.surface = existing.surface
        self.xdg_surface = existing.xdg_surface
        self.toplevel = existing.toplevel
        self.xs_queue = existing.xs_queue
        self.top_queue = existing.top_queue
        self.decoration_manager = existing.decoration_manager
        self.toplevel_decoration = existing.toplevel_decoration
        self.deco_queue = existing.deco_queue
        self.decoration_mode = existing.decoration_mode
        self.wm_queue = existing.wm_queue
        self.pointer = existing.pointer
        self.keyboard = existing.keyboard
        self.touch = existing.touch
        self.pt_queue = existing.pt_queue
        self.kb_queue = existing.kb_queue
        self.tch_queue = existing.tch_queue
        self.input = existing.input.copy()
        self.frame = existing.frame.copy()
        self.back = existing.back.copy()
        self.committed_last_frame = existing.committed_last_frame
        self.open_ok = existing.open_ok
        self.pending_resize = existing.pending_resize
        self.pending_resize_w = existing.pending_resize_w
        self.pending_resize_h = existing.pending_resize_h
        self.xdg_ack_configure_serial = existing.xdg_ack_configure_serial

    @staticmethod
    def open(title: String, width: Int, height: Int) raises -> Window:
        """Connect + create the surface chain + negotiate the first configure
        + map the shm backing store. Raises on any compositor error — the
        app cannot render without a surface, so this is fail-fast."""
        var w = Window()
        w.display = wl_display_connect(0)
        if Int(w.display) == 0:
            raise Error("failed to connect to compositor")

        var registry = wl_display_get_registry(w.display)
        var queue_buf = stack_allocation[1, WLPtr]()
        if wl_registry_listen(registry, queue_buf) != 0:
            raise Error("wayland: registry listen failed")
        var reg_queue = queue_buf[unsafe_offset=0]

        # One burst scan for every interface we bind at startup. Globals
        # are announced once each; separate find-loops would eat the
        # announcements of later finds (decoration is announced BEFORE
        # xdg_wm_base on KWin — sequential lookups starve it).
        var wanted = List[String]()
        wanted.append("wl_compositor")
        wanted.append("wl_shm")
        wanted.append("xdg_wm_base")
        wanted.append("zxdg_decoration_manager_v1")  # optional
        var infos = _find_globals(reg_queue, w.display, wanted)
        ref comp_info = infos[0]
        ref shm_info = infos[1]
        ref wm_info = infos[2]
        ref deco_info = infos[3]

        var compositor = wl_registry_bind(
            registry,
            shim_interface("wl_compositor"),
            _wlstring("wl_compositor".as_c_string_span()),
            comp_info.name,
            4,
        )
        var shm = wl_registry_bind(
            registry,
            shim_interface("wl_shm"),
            _wlstring("wl_shm".as_c_string_span()),
            shm_info.name,
            1,
        )
        var wm_ver = UInt32(3) if wm_info.version > 3 else wm_info.version
        var wm_base = wl_registry_bind(
            registry,
            shim_interface("xdg_wm_base"),
            _wlstring("xdg_wm_base".as_c_string_span()),
            wm_info.name,
            wm_ver,
        )
        if Int(compositor) == 0 or Int(shm) == 0 or Int(wm_base) == 0:
            raise Error("wayland: registry bind failed")
        w.compositor = compositor
        w.shm = shm
        w.wm_base = wm_base

        # Server-side decorations: bind the manager, request a decoration
        # object for our toplevel and ask for SERVER_SIDE chrome. The
        # compositor replies with a configure carrying the granted mode —
        # polled below before the buffer attach (an unacked decoration
        # configure + buffer attach is UNCONFIGURED_BUFFER, a protocol
        # error that compositors kill the client for).
        if deco_info.name > 0:
            var deco_mgr = wl_registry_bind(
                registry,
                shim_interface("zxdg_decoration_manager_v1"),
                _wlstring("zxdg_decoration_manager_v1".as_c_string_span()),
                deco_info.name,
                1,
            )
            if Int(deco_mgr) != 0:
                w.decoration_manager = deco_mgr

        var surface = wl_compositor_create_surface(compositor)
        var xdg_surface = xdg_wm_base_get_xdg_surface(wm_base, surface)
        var toplevel = xdg_surface_get_toplevel(xdg_surface)
        # Borrowed request title: a mutable copy of the caller's string is
        # required (as_c_string_span must mutate its source; the borrow only
        # has to outlive set_title's synchronous wire-buffer copy).
        var title_view = title
        xdg_toplevel_set_title(
            toplevel, _wlstring(title_view.as_c_string_span())
        )

        # Request server-side decorations (title bar drawn by the compositor)
        # before the first commit. Guarded: compositors without
        # zxdg_decoration_manager_v1 keep the client-side default.
        w.toplevel_decoration = _null[NoneType]()
        if Int(w.decoration_manager) != 0:
            var deco = zxdg_decoration_manager_v1_get_toplevel_decoration(
                w.decoration_manager, toplevel
            )
            w.toplevel_decoration = deco
            if Int(deco) != 0:
                zxdg_toplevel_decoration_v1_set_mode(
                    deco, ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE
                )
                var qd_buf = stack_allocation[1, WLPtr]()
                if zxdg_toplevel_decoration_v1_listen(deco, qd_buf) != 0:
                    # Listen failure is non-fatal: degrade to client chrome.
                    w.toplevel_decoration = _null[NoneType]()
                else:
                    w.deco_queue = qd_buf[unsafe_offset=0]

        # Request a maximized toplevel BEFORE the first commit. The
        # compositor answers with a configure carrying the real workbench
        # size (see below) — the caller reads it from frame.width/height.
        xdg_toplevel_set_maximized(toplevel)

        var qs_buf = stack_allocation[1, WLPtr]()
        var qt_buf = stack_allocation[1, WLPtr]()
        if xdg_surface_listen(xdg_surface, qs_buf) != 0:
            raise Error("wayland: xdg_surface listen failed")
        if xdg_toplevel_listen(toplevel, qt_buf) != 0:
            raise Error("wayland: toplevel listen failed")
        var xs_queue = qs_buf[unsafe_offset=0]
        var top_queue = qt_buf[unsafe_offset=0]

        wl_surface_commit(surface)
        _ = wl_display_roundtrip(w.display)

        # toplevel configure → ack → surface configure → ack.
        # The configure's (width, height) args carry the compositor-assigned
        # size — for a maximized toplevel that's the real workarea, which
        # overrides the requested w/h when valid (0 = "pick your own").
        var fb_w = width
        var fb_h = height
        var targs = stack_allocation[MAX_EVENT_ARGS, WLArgument]()
        var configured = False
        for _ in range(50):
            while xdg_toplevel_next_configure(top_queue, targs):
                var cw = Int(_arg_as_i32(targs[unsafe_offset=0]))
                var ch = Int(_arg_as_i32(targs[unsafe_offset=1]))
                if cw > 0 and ch > 0:
                    fb_w = cw
                    fb_h = ch
                configured = True
                break
            if configured:
                break
            _ = wl_display_dispatch(w.display)
        if not configured:
            raise Error("wayland: never received toplevel configure")

        # surface configure → ack. KWin delivers xdg_surface.configure in a
        # SEPARATE batch after the toplevel configure (Hyprland sends them
        # together), so roundtrip-wait for it — attaching a buffer before the
        # surface configure is a fatal xdg-shell protocol error (KWin kills
        # the client: "attached a buffer before configure event").
        var sargs = stack_allocation[MAX_EVENT_ARGS, WLArgument]()
        var serial: UInt32 = 0
        for _ in range(50):
            while xdg_surface_next_configure(xs_queue, sargs):
                serial = _arg_as_u32(sargs[unsafe_offset=0])
            if serial != 0:
                break
            _ = wl_display_roundtrip(w.display)
        if serial == 0:
            raise Error("wayland: never received surface configure")
        xdg_surface_ack_configure(xdg_surface, serial)
        _ = wl_display_roundtrip(w.display)

        # Decoration configure: the compositor answers the set_mode request
        # with (mode) on the decoration queue. Read it now so
        # decoration_mode reflects what will be committed with the first
        # buffer (the commit acks the configure — that's the protocol's
        # ack mechanism for this object). Absent event = compositor picked
        # its own mode; the default keeps decorations alive either way.
        if Int(w.deco_queue) != 0:
            var dargs = stack_allocation[MAX_EVENT_ARGS, WLArgument]()
            for _ in range(20):
                while zxdg_toplevel_decoration_v1_next_configure(
                    w.deco_queue, dargs
                ):
                    w.decoration_mode = _arg_as_u32(dargs[unsafe_offset=0])
                if w.decoration_mode != 0:
                    break
                _ = wl_display_roundtrip(w.display)

        _ = wl_display_roundtrip(w.display)

        # Input sources: bind wl_seat and wire pointer/keyboard/touch queues.
        # The compositor only delivers input to the FOCUSED surface and in
        # window-relative coordinates — exactly what UIContext hit-tests need
        # (unlike libinput, whose coords are desktop-absolute).
        # NOTE: the first registry pass already consumed/discarded the wl_seat
        # global (it precedes the others in announcement order), so request a
        # FRESH registry object — the compositor re-announces all globals.
        var reg2 = wl_display_get_registry(w.display)
        var reg2_buf = stack_allocation[1, WLPtr]()
        if wl_registry_listen(reg2, reg2_buf) != 0:
            raise Error("wayland: second registry listen failed")
        _ = wl_display_roundtrip(w.display)
        var seat_info = _find_global(
            reg2_buf[unsafe_offset=0], w.display, "wl_seat"
        )
        var seat_ver = UInt32(5) if seat_info.version > 5 else seat_info.version
        var seat = wl_registry_bind(
            reg2,
            shim_interface("wl_seat"),
            _wlstring("wl_seat".as_c_string_span()),
            seat_info.name,
            seat_ver,
        )
        if Int(seat) == 0:
            raise Error("wayland: wl_seat bind failed")
        w.pointer = wl_seat_get_pointer(seat)
        w.keyboard = wl_seat_get_keyboard(seat)
        w.touch = wl_seat_get_touch(seat)
        var pq_buf = stack_allocation[1, WLPtr]()
        var kq_buf = stack_allocation[1, WLPtr]()
        var tq_buf = stack_allocation[1, WLPtr]()
        if wl_pointer_listen(w.pointer, pq_buf) != 0:
            raise Error("wayland: pointer listen failed")
        if wl_keyboard_listen(w.keyboard, kq_buf) != 0:
            raise Error("wayland: keyboard listen failed")
        if wl_touch_listen(w.touch, tq_buf) != 0:
            raise Error("wayland: touch listen failed")
        w.pt_queue = pq_buf[unsafe_offset=0]
        w.kb_queue = kq_buf[unsafe_offset=0]
        w.tch_queue = tq_buf[unsafe_offset=0]
        _ = wl_display_roundtrip(w.display)

        # wm_base ping queue (must exist before pings arrive)
        var wm_queue_buf = stack_allocation[1, WLPtr]()
        if xdg_wm_base_listen(wm_base, wm_queue_buf) != 0:
            raise Error("wayland: wm_base listen failed")
        var wm_queue0 = wm_queue_buf[unsafe_offset=0]

        # framebuffers: TWO ARGB8888 shm buffers for double-buffering. The
        # app draws into `back` via draw_buffer(); present() memcmps it
        # against the shown `frame`, commits only on change, then swaps.
        var frame = Frame._build(fb_w, fb_h, shm, surface)
        var back = Frame._build(fb_w, fb_h, shm, surface)

        wl_surface_attach(surface, frame.buffer, 0, 0)
        wl_surface_commit(surface)

        # store state via field-by-field init (no partial self mutation)
        w.frame = frame^
        w.back = back^

        w.surface = surface
        w.xdg_surface = xdg_surface
        w.toplevel = toplevel
        w.xs_queue = xs_queue
        w.top_queue = top_queue
        w.wm_queue = wm_queue0
        w.open_ok = True
        return w^

    def rebuild_frame(mut self, new_w: Int, new_h: Int) raises:
        """Swap the frame buffer for one at the new size.

        Ack the pending xdg_surface.configure (waiting for it if KWin lags
        it behind the toplevel configure), allocate a fresh
        memfd/pool/buffer, attach, and commit. The old buffer/pool objects
        are left to be reaped with the connection on close (small leak per
        resize; correct behavior beats premature destroys)."""
        if Int(self.shm) == 0:
            raise Error("wayland: rebuild_frame before open")
        # Ack the last surface configure BEFORE the new attach+commit. KWin
        # can lag the xdg_surface.configure behind the toplevel configure
        # that set pending_resize — roundtrip-wait for the serial (attaching
        # before the surface configure is a fatal xdg-shell error).
        var sargs = stack_allocation[MAX_EVENT_ARGS, WLArgument]()
        for _ in range(50):
            while xdg_surface_next_configure(self.xs_queue, sargs):
                self.xdg_ack_configure_serial = _arg_as_u32(
                    sargs[unsafe_offset=0]
                )
            if self.xdg_ack_configure_serial != 0:
                break
            _ = wl_display_roundtrip(self.display)
        if self.xdg_ack_configure_serial != 0:
            xdg_surface_ack_configure(
                self.xdg_surface, self.xdg_ack_configure_serial
            )
            self.xdg_ack_configure_serial = UInt32(0)
        # Attach the new-size buffers IN PLACE — no NULL-attach unmap. The
        # old detach+reattach unmapped the surface, and KWin requires a
        # FRESH configure (sent only after the remap commit) before any
        # further attach — racing it kills the client with
        # "attached a buffer before configure event". Ack-then-attach at
        # the acked size is the standard resize path and needs no unmap.
        var new_frame = Frame._build(new_w, new_h, self.shm, self.surface)
        self.frame = new_frame^
        var new_back = Frame._build(new_w, new_h, self.shm, self.surface)
        self.back = new_back^
        wl_surface_attach(self.surface, self.frame.buffer, 0, 0)
        wl_surface_damage(self.surface, 0, 0, Int32(new_w), Int32(new_h))
        wl_surface_commit(self.surface)

    def pixels(mut self) -> Pointer[UInt8, MutUntrackedOrigin]:
        """Base pointer of the DRAW buffer (what the app rasterizes into).

        Double-buffered: this is NOT what the compositor displays — the shown
        buffer only updates inside present() when content differs. Never draw
        into the shown buffer directly."""
        return Pointer[UInt8, MutUntrackedOrigin](
            unsafe_from_address=Int(self.back.data)
        )

    def present(mut self) raises:
        """Commit the frame ONLY when the draw buffer differs from what the
        compositor shows (byte-exact memcmp, one native call). On change:
        attach the DRAW buffer (re-attach per commit is required on
        Hyprland — damage-only commits on an attached buffer can be
        skipped), damage, commit, then swap the two Frames; the old shown
        buffer becomes the next draw target. The compositor therefore
        never reads the buffer being rasterized, and idle screens issue
        zero commits (no teardown races = no repaint artifacts)."""
        if self.frame.size != self.back.size or self.frame.size == 0:
            return
        var same = _c_memcmp_same(
            Pointer[UInt8, MutUntrackedOrigin](
                unsafe_from_address=Int(self.frame.data)
            ),
            Pointer[UInt8, MutUntrackedOrigin](
                unsafe_from_address=Int(self.back.data)
            ),
            self.frame.size,
        )
        if same:
            self.committed_last_frame = False
            return
        # commit the draw buffer, then swap: last shown becomes next draw.
        wl_surface_attach(self.surface, self.back.buffer, 0, 0)
        wl_surface_damage(
            self.surface,
            0,
            0,
            Int32(self.frame.width),
            Int32(self.frame.height),
        )
        wl_surface_commit(self.surface)
        var tmp = self.frame^
        self.frame = self.back^
        self.back = tmp^
        self.committed_last_frame = True

    def poll(mut self) -> Bool:
        """Pump events. Answers pings, drains reconfigures, feeds input into
        self.input, returns False on compositor close request. Sets
        pending_resize_w/h (and leaves pending_resize True) when the
        compositor announces a configure with a different size; the caller
        calls rebuild_frame() with those dims."""
        var wargs = stack_allocation[MAX_EVENT_ARGS, WLArgument]()
        self.pending_resize = False
        # answer pings (else the compositor kills us after ~10s)
        var ping_args = stack_allocation[MAX_EVENT_ARGS, WLArgument]()
        while xdg_wm_base_next_ping(self.wm_queue, ping_args):
            xdg_wm_base_pong(
                self.wm_base, _arg_as_u32(ping_args[unsafe_offset=0])
            )
        # drain configure events: size changes set pending_resize so the app
        # can rebuild its shm buffer; pure reconfigures are acknowledged.
        while xdg_toplevel_next_configure(self.top_queue, wargs):
            # toplevel configure args: (width i, height i, states a)
            var cw = Int(Int32(_arg_as_u32(wargs[unsafe_offset=0])))
            var ch = Int(Int32(_arg_as_u32(wargs[unsafe_offset=1])))
            if (
                cw > 0
                and ch > 0
                and (cw != self.frame.width or ch != self.frame.height)
            ):
                self.pending_resize_w = cw
                self.pending_resize_h = ch
                self.pending_resize = True
        while xdg_surface_next_configure(self.xs_queue, wargs):
            self.xdg_ack_configure_serial = _arg_as_u32(wargs[unsafe_offset=0])
        # --- input drain (window-relative pointer coords, GLFW keycodes) ---
        # Edge bookkeeping: press edges are true for exactly one frame; the
        # pending_clear flag clears them (and the frame's key ring) at the
        # START of the next poll, so no press edge leaks across frames.
        if self.input.pending_clear:
            self.input.mouse_pressed = False
            self.input.any_key_pressed = False
            self.input.clear_frame_keys()
            self.input.pending_clear = False
        self.input.pending_clear = True
        # pointer: enter gives initial position; motion updates it
        while wl_pointer_next_enter(self.pt_queue, wargs):
            self.input.mouse_x = _arg_as_fixed(wargs[unsafe_offset=2])
            self.input.mouse_y = _arg_as_fixed(wargs[unsafe_offset=3])
        _ = wl_pointer_next_leave(self.pt_queue, wargs)
        while wl_pointer_next_motion(self.pt_queue, wargs):
            self.input.mouse_x = _arg_as_fixed(wargs[unsafe_offset=1])
            self.input.mouse_y = _arg_as_fixed(wargs[unsafe_offset=2])
        # pointer button: 272 = BTN_LEFT; state 1 = pressed
        while wl_pointer_next_button(self.pt_queue, wargs):
            var btn = _arg_as_u32(wargs[unsafe_offset=2])
            var st = _arg_as_u32(wargs[unsafe_offset=3])
            if btn == 272:
                if st == 1:
                    self.input.mouse_down = True
                    self.input.mouse_pressed = True
                    self.input.press_is_touch = False
                else:
                    self.input.mouse_down = False
        # pointer axis: axis 0 = vertical scroll
        while wl_pointer_next_axis(self.pt_queue, wargs):
            var axis_id = _arg_as_u32(wargs[unsafe_offset=1])
            if axis_id == 0:
                self.input.wheel_delta += _arg_as_fixed(wargs[unsafe_offset=2])
        # keyboard focus: enter/leave toggle input.focused. Gamepad reads
        # are gated on this (imui checks it before touching the pad).
        while wl_keyboard_next_enter(self.kb_queue, wargs):
            self.input.focused = True
        while wl_keyboard_next_leave(self.kb_queue, wargs):
            self.input.focused = False
            self.input.any_key_pressed = False
        # keyboard: evdev code → GLFW value (resources/keys values).
        # Every event joins the frame's ring (queue_key_event), so a
        # burst typed across a slow poll keeps ALL its presses instead
        # of collapsing to the last one.
        while wl_keyboard_next_key(self.kb_queue, wargs):
            var evdev = Int(_arg_as_u32(wargs[unsafe_offset=2]))
            var st = _arg_as_u32(wargs[unsafe_offset=3])
            self.input.queue_key_event(_evdev_to_glfw(evdev), st == 1)
        # touch: simulate mouse on the primary touching slot.
        # down(serial, time, surface, id, x, y) / motion(time, id, x, y) /
        # up(serial, time, id)
        while wl_touch_next_down(self.tch_queue, wargs):
            self.input.mouse_x = _arg_as_fixed(wargs[unsafe_offset=4])
            self.input.mouse_y = _arg_as_fixed(wargs[unsafe_offset=5])
            self.input.mouse_down = True
            self.input.mouse_pressed = True
            self.input.press_is_touch = True
            self.input.touch_start_x = self.input.mouse_x
            self.input.touch_start_y = self.input.mouse_y
        while wl_touch_next_motion(self.tch_queue, wargs):
            self.input.mouse_x = _arg_as_fixed(wargs[unsafe_offset=2])
            self.input.mouse_y = _arg_as_fixed(wargs[unsafe_offset=3])
        while wl_touch_next_up(self.tch_queue, wargs):
            self.input.mouse_down = False
        if xdg_toplevel_next_close(self.top_queue):
            return False
        # Non-blocking event pump: flush outgoing requests, then wait for
        # readability (poll, 16ms cap) before reading pending events. A plain
        # wl_display_dispatch BLOCKS until an event arrives — the UI froze
        # whenever nothing was happening (no input, no configures). The final
        # blocking dispatch only runs when poll(2) says the fd is readable;
        # otherwise we just drain already-queued events.
        _ = wl_display_flush(self.display)
        var pfd = stack_allocation[1, PollFd]()
        pfd[unsafe_offset=0].fd = wl_display_get_fd(self.display)
        pfd[unsafe_offset=0].events = Int16(POLLIN)
        pfd[unsafe_offset=0].revents = Int16(0)
        var prc = external_call["poll", c_int](
            pfd, c_ulong(1), FRAME_TIMEOUT_MS
        )
        # Read whatever arrived (if anything); also drain already-queued events.
        _ = wl_display_dispatch_pending(self.display)
        if prc > 0 and (Int(pfd[unsafe_offset=0].revents) & POLLIN) != 0:
            _ = wl_display_dispatch(self.display)
        return True

    def close(mut self):
        if Int(self.frame.data) != 0:
            c_munmap(self.frame.data, self.frame.size)
            self.frame.data = _null[NoneType]()
        if Int(self.back.data) != 0:
            c_munmap(self.back.data, self.back.size)
            self.back.data = _null[NoneType]()
        if Int(self.display) != 0:
            wl_display_disconnect(self.display)
            self.display = _null[NoneType]()
        self.open_ok = False
