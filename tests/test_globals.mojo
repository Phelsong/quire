# Live-compositor test for the wayland package.
# Flow: connect -> wl_display_get_registry -> registry_listen ->
#       dispatch -> pop REGISTRY_GLOBAL_OP events -> print globals ->
#       roundtrip -> disconnect
from wayland.core import (
    WLPtr,
    WLArgument,
    MAX_EVENT_ARGS,
    wl_display_connect,
    wl_display_disconnect,
    wl_display_dispatch,
    wl_display_roundtrip,
    stack_allocation,
)
from platform.wl_args import (
    arg_as_string,
    arg_as_u32,
    arg_as_i32,
    free_string_arg,
)
from wayland.gen.wayland import (
    wl_display_get_registry,
    wl_registry_listen,
    wl_registry_next_global,
)


# registry 'global' event layout on the wire:
#   arg0 = name (u), arg1 = interface (s, malloc'd copy), arg2 = version (i)
# Arg decoding/freeing helpers are shared with platform/window.mojo via
# platform.wl_args (was a local arg_as_string/cptr/uint/int copy).


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
            arg_as_u32(args[0]),
            "version =",
            arg_as_i32(args[2]),
        )
        # the shim hands back malloc'd copies — return the string arg
        free_string_arg(args[1])
    print("globals received:", count)

    # roundtrip to prove the request path works
    var rt = wl_display_roundtrip(display)
    print("roundtrip rc =", rt)

    wl_display_disconnect(display)
    print("TEST OK")
