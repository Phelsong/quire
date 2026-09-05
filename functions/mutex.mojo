# Mutex[T] — pthread-backed mutex with RAII guard, portable Mojo 1.0.0.
# Ported from a newer-Mojo sample that used os.atomic. std.atomic DOES exist
# on 1.0.0, but it only provides scalar atomics (Atomic[DType]) — no mutex,
# no condvar — so the locking primitives bind glibc's pthread mutex via
# external_call instead.
#
# Usage:
#     var m = Mutex[Counter]()
#     m.init_with(counter)          # T must be Copyable + Deinitable
#     with m.lock() as p:           # p is Pointer[T]
#         p[0].n += 1               # unlocked automatically at scope end
#     m.close()                     # when no guards are alive
#
# Requirement discovered while porting: T needs `& Deinitable` in the
# constraint or copy-assignment into the generic field fails with
# "value abandoned without being explicitly destroyed" (the compiler must
# know it may destroy the moved-from source).
from std.ffi import external_call
from std.memory import Layout, alloc
from std.memory.unsafe_pointer import Pointer

from platform.ffi import c_null as _null

comptime MUTEX_BYTES = 40  # sizeof(pthread_mutex_t) on glibc/x86_64


def _mutex_init(mem: Pointer[Byte, MutUntrackedOrigin]) -> Int32:
    return external_call["pthread_mutex_init", Int32](
        mem.unsafe_bitcast[Pointer[NoneType, MutUntrackedOrigin]](),
        _null[NoneType](),
    )


def _mutex_lock(mem: Pointer[Byte, MutUntrackedOrigin]) -> Int32:
    return external_call["pthread_mutex_lock", Int32](
        mem.unsafe_bitcast[Pointer[NoneType, MutUntrackedOrigin]]()
    )


def _mutex_unlock(mem: Pointer[Byte, MutUntrackedOrigin]) -> Int32:
    return external_call["pthread_mutex_unlock", Int32](
        mem.unsafe_bitcast[Pointer[NoneType, MutUntrackedOrigin]]()
    )


def _mutex_destroy(mem: Pointer[Byte, MutUntrackedOrigin]) -> Int32:
    return external_call["pthread_mutex_destroy", Int32](
        mem.unsafe_bitcast[Pointer[NoneType, MutUntrackedOrigin]]()
    )


struct MutexGuard[T: Movable](Movable):
    """RAII lock guard: unlocks in __deinit__ when the scope ends."""

    var _mem: Pointer[Byte, MutUntrackedOrigin]
    var _item: Pointer[Self.T, MutUntrackedOrigin]

    def __init__(
        out self,
        mem: Pointer[Byte, MutUntrackedOrigin],
        item: Pointer[Self.T, MutUntrackedOrigin],
    ):
        self._mem = mem
        self._item = item

    def __enter__(self) -> Pointer[Self.T, MutUntrackedOrigin]:
        return self._item

    def __exit__(self):
        pass

    def __deinit__(deinit self):
        _ = _mutex_unlock(self._mem)


struct Mutex[T: Copyable & Deinitable](Movable):
    """Mutex-guarded shared state (pthread-backed on Mojo 1.0.0).
    with m.lock() as p: p[unsafe_offset=0].field = ...  # p is Pointer[T]"""

    var _mem: Pointer[Byte, MutUntrackedOrigin]
    var _item: Pointer[Self.T, MutUntrackedOrigin]

    def __init__(out self):
        # Layout-based alloc (deprecated without one), then leak into raw
        # pointer fields: Allocation is not Deinitable so it cannot be a
        # struct field, and ownership transfers to close()'s unsafe_free().
        self._mem = alloc[Byte](Layout[Byte](count=MUTEX_BYTES)).unsafe_leak()
        _ = _mutex_init(self._mem)
        self._item = alloc[Self.T](Layout[Self.T](count=1)).unsafe_leak()

    def init_with(mut self, item: Self.T):
        # T is Copyable for our use cases; explicit .copy() avoids the
        # move-then-abandoned-value problem with generic `item^` on 1.0.0.
        self._item[unsafe_offset=0] = item.copy()

    def __moveinit__(mut self, existing: Self):
        self._mem = existing._mem
        self._item = existing._item

    def lock(mut self) -> MutexGuard[Self.T]:
        _ = _mutex_lock(self._mem)
        return MutexGuard[Self.T](self._mem, self._item)

    def close(mut self):
        """Explicit teardown: destroy the mutex and free storage.
        Call only when no guards are alive."""
        _ = _mutex_destroy(self._mem)
        self._mem.unsafe_free()
        self._item.unsafe_free()
        self._mem = Pointer[Byte, MutUntrackedOrigin](
            unsafe_from_address=Int(self._item) * 0
        )
