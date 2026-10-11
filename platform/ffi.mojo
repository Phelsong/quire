# Shared C-FFI helpers for the pinned Mojo 1.1.x toolchain.
#
# Pointer is non-nullable by design: `Pointer(unsafe_from_address=0)` with a
# *literal* zero fails at instantiation, but a *runtime* zero yields a true
# C NULL (verified: libc free(NULL) accepts it as a no-op). UnsafePointer is
# a deprecated alias of Pointer — call sites still spelling UnsafePointer
# interop with these helpers unchanged (same type, same layout).
#
# C string views: String.as_c_string_span() forces a NUL terminator and
# rebind reinterprets the slice as a raw char* (borrowed — lifetime of the
# source String; C callees must not retain it).
from std.ffi import (
    external_call,
    c_int,
    c_long,
    c_ulong,
    c_size_t,
    CStringSpan,
)
from std.memory import Layout, alloc, dealloc, ThinAllocation
from std.memory.unsafe_pointer import Pointer
from std.collections import Optional


def c_null[T: AnyType]() -> Pointer[T, MutUntrackedOrigin]:
    """NULL Pointer[T] — address 0, materialized via a runtime zero.
    produces the true C NULL.
    """
    var zero = 0
    return Pointer[T, MutUntrackedOrigin](unsafe_from_address=zero)


def cstr(mut s: String) -> Pointer[Int8, MutUntrackedOrigin]:
    """Borrow s's buffer as a NUL-terminated char*.

    Borrowed view: the pointer is valid only while `s` lives — C callees
    must not retain it. as_c_string_span() mutates `s` in place to append
    the NUL terminator, hence the `mut s`. Nullability is NOT modeled here:
    for nullable char* use c_null[T]() explicitly, or Optional[CStringSlice]
    for C functions whose return may be NULL (docs-sanctioned pattern).
    """
    var cs = s.as_c_string_span()
    return rebind[Pointer[Int8, MutUntrackedOrigin]](cs)


def heap_malloc(n: Int) raises -> Pointer[NoneType, MutUntrackedOrigin]:
    """libc malloc — caller owns the memory. Everything shared with the
    writer thread MUST come from here — stack_allocation memory belongs to
    the caller's frame and is clobbered once create() returns (the original
    writer-thread segfault).

    Raises on OOM instead of returning NULL: raw malloc signals failure
    with a null pointer, and every caller here immediately writes through
    the result — a null would be a silent segfault. Fail fast instead.
    """
    var p = external_call["malloc", Pointer[NoneType, MutUntrackedOrigin]](
        c_size_t(n)
    )
    if Int(p) == 0:
        raise Error("heap_malloc: out of memory (" + String(n) + " bytes)")
    return p


def heap_free_byte(p: Pointer[Byte, MutUntrackedOrigin]):
    """libc free (byte-typed pointer) — the companion of heap_malloc."""
    external_call["free", NoneType](p)


def c_read(
    fd: Int32, buf: Pointer[NoneType, MutUntrackedOrigin], n: Int
) -> Int:
    return external_call["__read", Int](fd, buf, n)


def c_close(fd: Int32):
    _ = external_call["close", Int32](fd)


def pthread_create[
    E: AnyType
](
    tid: Pointer[c_ulong, MutUntrackedOrigin],
    entry_fn: E,
    arg: Pointer[NoneType, MutUntrackedOrigin],
) -> Int32:
    """pthread_create wrapper: `entry_fn` is the Mojo thread entry (a bare
    top-level `def`), `arg` is passed through as the entry's void*.

    Everything `arg` points at MUST be heap-allocated with a lifetime
    outliving the thread — stack_allocation memory belongs to the caller's
    frame and is clobbered once the spawning function returns (the original
    writer-thread segfault). The tid out-param may be a stack cell: libc
    writes it before pthread_create returns and the value is copied out by
    the caller."""
    return external_call["pthread_create", Int32](
        tid, c_null[NoneType](), entry_fn, arg
    )


def pthread_join(tid: c_ulong):
    """Block until the thread with pthread handle `tid` exits."""
    _ = external_call["pthread_join", Int32](tid, c_null[NoneType]())


def c_munmap(addr: Pointer[NoneType, MutUntrackedOrigin], length: Int):
    _ = external_call["munmap", Int32](addr, c_size_t(length))


def c_ftruncate(fd: Int32, length: Int) -> Int32:
    return external_call["ftruncate", Int32](fd, c_long(length))


# mmap constants (linux)
comptime PROT_READ = c_int(1)
comptime PROT_WRITE = c_int(2)
comptime MAP_SHARED = c_int(1)


def c_mmap(
    addr: Int,
    length: Int,
    prot: c_int,
    flags: c_int,
    fd: c_int,
    offset: Int,
) -> Pointer[NoneType, MutUntrackedOrigin]:
    """mmap(2) with ABI-exact arg widths: void* addr (a runtime-zero
    address is the true C NULL = kernel picks), size_t length, int
    prot/flags/fd, off_t offset. Returns the mapping; failure is
    MAP_FAILED = (void*)-1, NOT a null pointer — callers must check for
    -1 (a null check never fires and a failed mmap segfaults on first
    pixel write)."""
    return external_call["mmap", Pointer[NoneType, MutUntrackedOrigin]](
        Pointer[NoneType, MutUntrackedOrigin](unsafe_from_address=addr),
        c_size_t(length),
        prot,
        flags,
        fd,
        c_long(offset),
    )


def c_memfd_create(name: CStringSpan, flags: UInt32) -> Int32:
    """memfd_create(2) — borrowed NUL-terminated name view.

    Borrowed, not leaked: the kernel consumes the name during the syscall
    only, so the view only has to outlive the call (see the borrowed-vs-
    retained ledger in platform/wl_args.mojo)."""
    return external_call["memfd_create", Int32](
        rebind[Pointer[Int8, MutUntrackedOrigin]](name), flags
    )


struct Box[T: AnyType](Movable):
    """Owning heap block of exactly `count` Ts. Sized by Layout[T] (no
    hand-computed byte counts, no bitcasts); freed via the matched
    ThinAllocation/Layout dealloc path when the box is dropped.

    Moves transfer ownership: operating on a moved-from box aborts in the
    Optional unwrap instead of double-freeing. NOT Copyable — copying heap
    storage is caller policy (a shared block needs a pointer, see FontSet).

    Raw storage, not value-managing: destructors of stored values do NOT
    run at box teardown — the owner closes resources explicitly first
    (the same contract every alloc/leak/free site in this codebase
    follows; Mutex.close() is the canonical example). alloc() aborts on
    OOM, so there is no error path to thread through callers.

    Usage:
        var b = Box[PaSampleSpec]()            # one value, uninitialized
        b.ptr().unsafe_write(PaSampleSpec(...))
        _ = external_call[...](b.ptr(), ...)   # pass to C by pointer
        var block = Box[UInt8](count=32768)    # raw byte block
    """

    var _ptr: Optional[Pointer[Self.T, MutUntrackedOrigin]]
    var _count: Int

    def __init__(out self, count: Int = 1):
        self._ptr = Optional[Pointer[Self.T, MutUntrackedOrigin]](
            alloc(Layout[Self.T](count=count)).unsafe_leak()
        )
        self._count = count

    def __init__(out self, *, deinit move: Self):
        self._ptr = move._ptr.take()
        self._count = move._count

    def ptr(self) -> Pointer[Self.T, MutUntrackedOrigin]:
        """Mutable storage pointer (count elements, untracked origin).
        Aborts if the box was moved from or already closed."""
        return self._ptr.value()

    def count(self) -> Int:
        return self._count

    def __deinit__(deinit self):
        if self._ptr:
            dealloc(
                ThinAllocation(
                    unsafe_owned_ptr=self._ptr.value()
                ).unsafe_with_layout(Layout[Self.T](count=self._count))
            )
