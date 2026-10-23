# wl_args.mojo — Wayland wire-argument marshaling helpers, shared by
# platform/window.mojo and the tests (single source of truth for the
# formerly-duplicated copies).
#
# Borrowed-vs-retained ledger (who owns what string memory):
# - REQUEST strings (`wlstring`): BORROWED views into the caller's string.
#   Safe because request marshaling (wl_proxy_marshal_array ->
#   wl_closure_marshal) copies 's' args into the wire buffer synchronously
#   and never retains the pointer — the borrow only has to outlive the
#   request call itself. Callers pass `"...".as_c_string_span()` on a
#   literal (static bytes already carry the NUL) or on a MUTABLE String
#   that outlives the call (`as_c_string_span` may append a terminating
#   zero and can move the buffer, so rvalues and imm strings cannot be the
#   source). This replaced the old leaked per-call heap copies: the
#   per-process alloc(Layout) leak is intentionally gone.
# - EVENT strings (arg_as_string + free_string_arg): the shim deep-copies
#   's' event args at dispatch time (shim.c copy_args -> malloc) and
#   RETAINS each copy until it is freed. The pointer decoded here is
#   shim-owned, NOT borrowed; free_string_arg hands it back
#   (wayland_shim_string_free) and MUST be called once per popped 's'
#   event arg.
#
# Byte layout matches wl_argument: little-endian slots, 8B strings, 4B
# uint/int/fixed. wl_fixed is int24.8 (value * 256).
# `c_char` (not `Int8`) is 1.2-correct here: c_char's signedness now
# follows the target ABI. `String(...)` conversions go through `as_bytes()`.
from std.ffi import c_char, CStringSpan
from std.ffi.unsafe_union import UnsafeUnion
from std.memory import unsafe_memcpy
from std.memory.unsafe_pointer import Pointer

from wayland.core import WLArgument, WLString, _shim_string_free

# Untagged view of one wl_argument slot — exactly the C union shape: 8
# bytes, no discriminant, and as in C the wire signature (never the slot)
# decides which member is active. Little-endian: the signed/unsigned/fixed
# members occupy the LOW 4 bytes, string/object args fill all 8.
comptime WLUnion = UnsafeUnion[Int32, UInt32, Int64]


def wlstring(cs: CStringSpan) -> WLString:
    """Borrowed protocol-string arg for a Wayland REQUEST (see the ledger
    in the module notes: copy-on-marshal means the view only has to
    outlive the request call)."""
    return rebind[Pointer[Int8, MutUntrackedOrigin]](cs).unsafe_bitcast[Byte]()


def arg_view(a: WLArgument) -> WLUnion:
    """View one event slot's raw bytes as the wl_argument union.

    The bytes are copied (not pointer-viewed) so the type-pun is
    alignment-proof: `raw` is plain byte-array storage with no 8-byte
    alignment guarantee. Probe-verified byte-identical to the previous
    byte-loop decode on boundary values (0x80000000, negative fixeds, max
    pointers)."""
    var u = WLUnion(unsafe_uninitialized=Tuple())
    unsafe_memcpy(
        dest=u.unsafe_ptr[Int64]().unsafe_bitcast[Byte](),
        src=a.raw.unsafe_ptr(),
        count=8,
    )
    return u


def _arg_addr(a: WLArgument) -> Int:
    """Reassemble the pointer stored in a string-typed (8-byte) arg slot."""
    return Int(arg_view(a).unsafe_get[Int64]())


def arg_as_string(a: WLArgument) raises -> String:
    """Decode a shim-owned malloc'd NUL-terminated 's' WLArgument into a
    Mojo String (the shim retains the copy until it is freed)."""
    var ptr = Pointer[c_char, MutUntrackedOrigin](
        unsafe_from_address=_arg_addr(a)
    )
    # 1.2: `String(...)` has no implicit from-bytes init (it would hit the
    # Writable overload and render "[104,101,...]"); the explicit byte
    # converter is the `from_utf8` kwarg.
    return String(from_utf8=CStringSpan(unsafe_from_ptr=ptr).as_bytes())


def arg_as_u32(a: WLArgument) -> UInt32:
    """Unsigned 32-bit wire arg (low 4 slot bytes)."""
    return arg_view(a).unsafe_get[UInt32]()


def arg_as_i32(a: WLArgument) -> Int32:
    """Signed 32-bit wire arg (toplevel configure width/height are Int)."""
    return arg_view(a).unsafe_get[Int32]()


def arg_as_fixed(a: WLArgument) -> Float64:
    """wl_fixed (int24.8) → pixels. Wayland fixed-point = value * 256.

    Conversion semantics unchanged from the byte-loop version: the signed
    low 32 bits divided by 256.0."""
    return Float64(arg_view(a).unsafe_get[Int32]()) / 256.0


def free_string_arg(a: WLArgument):
    """Return a popped 's' event arg's shim-owned copy to the shim
    allocator. Must run once per decoded 's' event string."""
    _shim_string_free(
        Pointer[Byte, MutUntrackedOrigin](unsafe_from_address=_arg_addr(a))
    )
