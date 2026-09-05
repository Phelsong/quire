# Live-compositor test for the wayland package.
# Flow: connect -> wl_display_get_registry -> registry_listen ->
#       dispatch -> pop REGISTRY_GLOBAL_OP events -> print globals ->
#       roundtrip -> disconnect
from std.ffi import CStringSlice
from wayland.core import (
    WLPtr,
    WLArgument,
    MAX_EVENT_ARGS,
    _shim_string_free,
    wl_display_connect,
    wl_display_disconnect,
    wl_display_dispatch,
    wl_display_roundtrip,
    stack_allocation,
)
from wayland.gen.wayland import (
    wl_display_get_registry,
    wl_registry_listen,
    wl_registry_next_global,
    REGISTRY_GLOBAL_OP,
)


# registry 'global' event layout on the wire:
#   arg0 = name (u), arg1 = interface (s, malloc'd copy), arg2 = version (i)


def arg_as_string(a: WLArgument) -> String:
    """Decode a malloc'd NUL-terminated 's' WLArgument into a Mojo String."""
    # reconstruct the pointer from the little-endian bytes in the slot
    var addr = 0
    for i in range(8):
        addr = addr | (Int(a.raw[i]) << (8 * i))
    var ptr = Pointer[Int8, MutAnyOrigin](unsafe_from_address=addr)
    return String(CStringSlice(unsafe_from_ptr=ptr))


def arg_as_cptr(a: WLArgument) -> Pointer[Int8, MutAnyOrigin]:
    var addr = 0
    for i in range(8):
        addr = addr | (Int(a.raw[i]) << (8 * i))
    return Pointer[Int8, MutAnyOrigin](unsafe_from_address=addr)


def arg_as_uint(a: WLArgument) -> UInt32:
    var v = 0
    for i in range(4):
        v = v | (Int(a.raw[i]) << (8 * i))
    return UInt32(v)


def arg_as_int(a: WLArgument) -> Int32:
    var v = arg_as_uint(a)
    return Int32(v)


def main() raises:
    var display = wl_display_connect(0)
    if Int(display) == 0:
        raise Error("failed to connect to compositor")
    print("connected")

    var registry = wl_display_get_registry(display)
    if Int(registry) == 0:
        wl_display_disconnect(display)
        raise Error("get_registry failed")

    # out-queue handle: shim writes the queue pointer into queue_buf[0]
    var queue_buf = stack_allocation[1, WLPtr]()
    var rc = wl_registry_listen(registry, queue_buf)
    if rc != 0:
        wl_display_disconnect(display)
        raise Error("registry_listen failed rc=" + String(rc))
    var queue = queue_buf[0]
    print("listener installed")

    # dispatch once: server sends the initial globals burst
    var dispatched = wl_display_dispatch(display)
    print("dispatched", dispatched)

    var args = stack_allocation[MAX_EVENT_ARGS, WLArgument]()
    var count = 0
    while wl_registry_next_global(queue, args):
        count += 1
        var iface_name = arg_as_string(args[1])
        print(
            "global",
            count,
            ":",
            iface_name,
            "name =",
            arg_as_uint(args[0]),
            "version =",
            arg_as_int(args[2]),
        )
        # rebuild the byte pointer for free (shim hands back malloc'd copies)
    _shim_string_free(
        Pointer[Byte, MutAnyOrigin](
            unsafe_from_address=Int(arg_as_cptr(args[1]))
        )
    )
    print("globals received:", count)

    # roundtrip to prove the request path works
    var rt = wl_display_roundtrip(display)
    print("roundtrip rc =", rt)

    wl_display_disconnect(display)
    print("TEST OK")
