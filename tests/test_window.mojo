# Live window test: full WSI proof for the wayland package.
# Flow: connect -> registry globals -> bind wl_compositor + wl_shm + xdg_wm_base
#   -> create surface -> xdg surface -> toplevel -> wait configure -> ack
#   -> memfd + wl_shm pool -> ARGB8888 gradient buffer -> attach/damage/commit
#   -> dispatch loop (answers xdg ping) until closed by compositor.
from platform.ffi import (
    c_mmap,
    c_memfd_create,
    c_munmap,
    c_close,
    c_ftruncate,
    PROT_READ,
    PROT_WRITE,
    MAP_SHARED,
)
from platform.wl_args import (
    wlstring,
    arg_as_string,
    arg_as_u32,
    arg_as_fixed,
    free_string_arg,
)

from wayland.core import (
    WLPtr,
    WLArgument,
    MAX_EVENT_ARGS,
    shim_interface,
    wl_display_connect,
    wl_display_disconnect,
    wl_display_dispatch,
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
    xdg_toplevel_set_title,
)

comptime WIDTH = 400
comptime HEIGHT = 300
comptime STRIDE = WIDTH * 4
comptime POOL_SIZE = STRIDE * HEIGHT


# The old local str_to_cptr/str_to_wlstring/arg_as_* marshaling helpers and
# the duplicated libc bindings (memfd/mmap/munmap/ftruncate/close + PROT
# constants) are gone — shared via platform.wl_args and platform.ffi
# (byte-identical wire behavior, same names modulo the uint/int spellings:
# arg_as_u32 / arg_as_i32).


struct GlobalInfo(Copyable, Movable):
    var name: UInt32
    var version: UInt32

    def __init__(out self, name: UInt32, version: UInt32):
        self.name = name
        self.version = version


def find_global(
    queue: WLPtr, display: WLPtr, want: String
) raises -> GlobalInfo:
    """Returns (name, version) for a global; dispatches while looking."""
    var args = stack_allocation[MAX_EVENT_ARGS, WLArgument]()
    while True:
        while wl_registry_next_global(queue, args):
            var iface_name = arg_as_string(args[1])
            var is_want = iface_name == want
            free_string_arg(args[1])
            if is_want:
                return GlobalInfo(arg_as_u32(args[0]), arg_as_u32(args[2]))
        var n = wl_display_dispatch(display)
        if n <= 0:
            raise Error("dispatch failed while waiting for " + want)


def store_pixel(base: WLPtr, offset: Int, r: UInt8, g: UInt8, b: UInt8):
    # ARGB8888 little-endian: B, G, R, X byte order in memory
    var p = Pointer[UInt8, MutAnyOrigin](unsafe_from_address=Int(base) + offset)
    p[0] = b
    p[1] = g
    p[2] = r
    p[3] = 255


def paint_gradient(base: WLPtr):
    for y in range(HEIGHT):
        for x in range(WIDTH):
            var o = y * STRIDE + x * 4
            var r = UInt8((x * 255) // WIDTH)
            var b = UInt8(255 - ((y * 255) // HEIGHT))
            store_pixel(base, o, r, 128, b)


def main() raises:
    var display = wl_display_connect(0)
    if Int(display) == 0:
        raise Error("failed to connect to compositor")
    print("connected")

    var registry = wl_display_get_registry(display)
    var queue_buf = stack_allocation[1, WLPtr]()
    if wl_registry_listen(registry, queue_buf) != 0:
        raise Error("registry_listen failed")
    var reg_queue = queue_buf[0]

    # collect globals
    var comp_info = find_global(reg_queue, display, "wl_compositor")
    var shm_info = find_global(reg_queue, display, "wl_shm")
    var wm_info = find_global(reg_queue, display, "xdg_wm_base")
    var comp_name = comp_info.name
    var shm_name = shm_info.name
    var wm_name = wm_info.name
    var wm_ver = wm_info.version
    print("globals: compositor", comp_name, "shm", shm_name, "wm_base", wm_name)

    # bind (xdg_wm_base v3 is what we exercise)
    var compositor = wl_registry_bind(
        registry,
        shim_interface("wl_compositor"),
        wlstring("wl_compositor".as_c_string_span()),
        comp_name,
        4,
    )
    var shm = wl_registry_bind(
        registry,
        shim_interface("wl_shm"),
        wlstring("wl_shm".as_c_string_span()),
        shm_name,
        1,
    )
    var wm_ver_use = UInt32(3) if wm_ver > 3 else wm_ver
    var wm_base = wl_registry_bind(
        registry,
        shim_interface("xdg_wm_base"),
        wlstring("xdg_wm_base".as_c_string_span()),
        wm_name,
        wm_ver_use,
    )
    if Int(compositor) == 0 or Int(shm) == 0 or Int(wm_base) == 0:
        raise Error("bind failed")
    print("bound compositor + shm + xdg_wm_base")

    # surface + xdg shell objects
    var surface = wl_compositor_create_surface(compositor)
    var xdg_surface = xdg_wm_base_get_xdg_surface(wm_base, surface)
    var toplevel = xdg_surface_get_toplevel(xdg_surface)
    xdg_toplevel_set_title(
        toplevel, wlstring("mojo-wayland window".as_c_string_span())
    )
    print("surface chain created")

    # listen for events
    var qs_buf = stack_allocation[1, WLPtr]()
    var qt_buf = stack_allocation[1, WLPtr]()
    if xdg_surface_listen(xdg_surface, qs_buf) != 0:
        raise Error("xdg_surface_listen failed")
    if xdg_toplevel_listen(toplevel, qt_buf) != 0:
        raise Error("xdg_toplevel_listen failed")
    var xs_queue = qs_buf[0]
    var top_queue = qt_buf[0]

    # initial commit: triggers the configure handshake
    wl_surface_commit(surface)
    _ = wl_display_roundtrip(display)

    # wait for toplevel configure
    var targs = stack_allocation[MAX_EVENT_ARGS, WLArgument]()
    var configured: Bool = False
    for round in range(50):
        while xdg_toplevel_next_configure(top_queue, targs):
            configured = True
            break
        if configured:
            break
        _ = wl_display_dispatch(display)
    if not configured:
        raise Error("never received toplevel configure")

    # xdg_surface.configure carries the serial we must ack
    var sargs = stack_allocation[MAX_EVENT_ARGS, WLArgument]()
    var serial: UInt32 = 0
    while xdg_surface_next_configure(xs_queue, sargs):
        serial = arg_as_u32(sargs[0])
    if serial != 0:
        xdg_surface_ack_configure(xdg_surface, serial)
    _ = wl_display_roundtrip(display)
    print("configure handshake done, serial =", serial)

    # --- framebuffer: memfd + wl_shm pool + ARGB8888 gradient ---
    var fd = c_memfd_create("quire-wl".as_c_string_span(), 0)
    if fd < 0:
        raise Error("memfd_create failed")
    _ = c_ftruncate(fd, POOL_SIZE)
    var pixels = c_mmap(0, POOL_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
    # mmap failure is MAP_FAILED = (void*)-1, not null (see c_mmap).
    if Int(pixels) == -1:
        raise Error("mmap failed")
    paint_gradient(pixels)

    var pool = wl_shm_create_pool(shm, fd, Int32(POOL_SIZE))
    var buffer = wl_shm_pool_create_buffer(
        pool, 0, WIDTH, HEIGHT, Int32(STRIDE), SHM_FORMAT_ARGB8888
    )
    wl_surface_attach(surface, buffer, 0, 0)
    wl_surface_damage(surface, 0, 0, WIDTH, HEIGHT)
    wl_surface_commit(surface)
    c_close(fd)
    print("first frame committed — window should be visible now")

    # --- event loop: respond to pings, detect close ---
    var wm_queue_buf = stack_allocation[1, WLPtr]()
    if xdg_wm_base_listen(wm_base, wm_queue_buf) != 0:
        raise Error("xdg_wm_base_listen failed")
    var wm_queue = wm_queue_buf[0]
    var wargs = stack_allocation[MAX_EVENT_ARGS, WLArgument]()
    # NOTE: must be MAX_EVENT_ARGS — the shim's pop zeroes SHIM_MAX_ARGS
    # (16) entries unconditionally; a 1-entry buffer overflows the stack.
    var ping_args = stack_allocation[MAX_EVENT_ARGS, WLArgument]()
    var loops: Int = 0
    var running: Bool = True
    while running and loops < 600:
        loops += 1
        # answer pings (else compositor kills us after ~10s)
        while xdg_wm_base_next_ping(wm_queue, ping_args):
            xdg_wm_base_pong(wm_base, arg_as_u32(ping_args[0]))
        # drain configure events (reconfigure: keep current size)
        while xdg_toplevel_next_configure(top_queue, wargs):
            pass
        while xdg_surface_next_configure(xs_queue, wargs):
            pass
        # close event
        if xdg_toplevel_next_close(top_queue):
            print("close requested")
            running = False
        _ = wl_display_dispatch(display)

    c_munmap(pixels, POOL_SIZE)
    wl_display_disconnect(display)
    print("TEST OK")
