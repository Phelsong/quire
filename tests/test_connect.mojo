# Minimal connect probe: does wl_display_connect alone work in a fresh binary?
from std.ffi import external_call

from wayland.core import wl_display_connect, wl_display_disconnect


def main() raises:
    var display = wl_display_connect(0)
    print("connect returned:", display)
    if Int(display) == 0:
        print("FAILED TO CONNECT")
        return
    wl_display_disconnect(display)
    print("MINI OK")
