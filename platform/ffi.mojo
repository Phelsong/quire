# Shared C-FFI helpers for the pinned Mojo 1.0.0 toolchain.
#
# Pointer is non-nullable by design: `Pointer(unsafe_from_address=0)` with a
# *literal* zero fails at instantiation, but a *runtime* zero yields a true
# C NULL (verified: libc free(NULL) accepts it as a no-op). Pointer is
# a deprecated alias of Pointer — call sites still spelling Pointer
# interop with these helpers unchanged (same type, same layout).
#
# C string views: String.as_c_string_slice() forces a NUL terminator and
# rebind reinterprets the slice as a raw char* (borrowed — lifetime of the
# source String; C callees must not retain it).
from std.ffi import external_call


def c_null[T: AnyType]() -> Pointer[T, MutUntrackedOrigin]:
    """NULL Pointer[T] — address 0, materialized via a runtime zero.

    A literal `unsafe_from_address=0` is rejected at instantiation; routing
    the address through a runtime variable produces the true C NULL.
    """
    var zero = 0
    return Pointer[T, MutUntrackedOrigin](unsafe_from_address=zero)


def cstr(mut s: String) -> Pointer[Int8, MutUntrackedOrigin]:
    """Borrow s's buffer as a NUL-terminated char*.

    Borrowed view: the pointer is valid only while `s` lives — C callees
    must not retain it. as_c_string_slice() mutates `s` in place to append
    the NUL terminator, hence the `mut s`. Nullability is NOT modeled here:
    for nullable char* use c_null[T]() explicitly, or Optional[CStringSlice]
    for C functions whose return may be NULL (docs-sanctioned pattern).
    """
    var cs = s.as_c_string_slice()
    return rebind[Pointer[Int8, MutUntrackedOrigin]](cs)


def heap_malloc(n: Int) -> Pointer[NoneType, MutUntrackedOrigin]:
    """libc malloc — caller owns the memory. Everything shared with the
    writer thread MUST come from here — stack_allocation memory belongs to
    the caller's frame and is clobbered once create() returns (the original
    writer-thread segfault)."""
    return external_call["malloc", Pointer[NoneType, MutUntrackedOrigin]](
        UInt64(n)
    )


def heap_free(p: Pointer[NoneType, MutUntrackedOrigin]):
    """libc free."""
    external_call["free", NoneType](p)


def heap_free_byte(p: Pointer[Byte, MutUntrackedOrigin]):
    """libc free (byte-typed pointer)."""
    external_call["free", NoneType](p)
