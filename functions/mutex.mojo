# Mutex[T] — BlockingSpinLock-backed mutex with RAII guard, safe Mojo (no pthread FFI).
#
# std.utils.lock.BlockingSpinLock is stdlib's only cross-thread lock atm,
# holds the CPU only for the few dozen ns the holder spends inside.
#
# The spinlock lives on the heap (one small cell) so guards can hold a
# stable Pointer to it — BlockingSpinLock is not ImplicitlyCopyable, and
# Mutex must stay Movable for the callers that move their state structs.
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
from std.utils.lock import BlockingSpinLock
from std.memory import Layout, alloc
from std.memory.unsafe_pointer import Pointer
from std.ffi import external_call

from platform.ffi import c_null


def _thread_owner() -> Int:
    """pthread_self() as the BlockingSpinLock owner id.

    Distinct per thread, stable for the thread's lifetime — exactly what the
    spinlock's ownership tracking wants. One cheap FFI call per lock().
    """
    return Int(
        external_call["pthread_self", Pointer[NoneType, MutUntrackedOrigin]]()
    )


struct MutexGuard[T: Movable](Movable):
    """RAII lock guard: unlocks in __deinit__ when the scope ends."""

    var _lock: Pointer[BlockingSpinLock, MutUntrackedOrigin]
    var _owner: Int
    var _item: Pointer[Self.T, MutUntrackedOrigin]

    def __init__(
        out self,
        lock: Pointer[BlockingSpinLock, MutUntrackedOrigin],
        owner: Int,
        item: Pointer[Self.T, MutUntrackedOrigin],
    ):
        self._lock = lock
        self._owner = owner
        self._item = item

    def __enter__(self) -> Pointer[Self.T, MutUntrackedOrigin]:
        return self._item

    def __exit__(self):
        pass

    def __deinit__(deinit self):
        self._lock[unsafe_offset=0].unlock(self._owner)


struct Mutex[T: Copyable & Deinitable](Movable):
    """Mutex-guarded shared state (BlockingSpinLock-backed, pure safe Mojo).
    with m.lock() as p: p[unsafe_offset=0].field = ...  # p is Pointer[T]"""

    var _lock: Pointer[BlockingSpinLock, MutUntrackedOrigin]
    var _item: Pointer[Self.T, MutUntrackedOrigin]

    def __init__(out self):
        # Both the spinlock and the guarded item live on the heap: the lock
        # is not ImplicitlyCopyable (can't be a plain field in a Movable
        # struct across moves) and the item must outlive callers (guards
        # hand out Pointer[T]).
        self._lock = Pointer[BlockingSpinLock, MutUntrackedOrigin](
            unsafe_from_address=Int(
                alloc(Layout[BlockingSpinLock](count=1)).unsafe_leak()
            )
        )
        self._lock[unsafe_offset=0] = BlockingSpinLock()
        self._item = Pointer[Self.T, MutUntrackedOrigin](
            unsafe_from_address=Int(
                alloc(Layout[Self.T](count=1)).unsafe_leak()
            )
        )

    def init_with(mut self, var item: Self.T):
        # T is Copyable for our use cases; explicit .copy() avoids the
        # move-then-abandoned-value problem with generic `item^` on 1.0.0.
        self._item[unsafe_offset=0] = item^

    def __moveinit__(mut self, mut existing: Self):
        # Steal ownership; null the source so a stray close() on it can't
        # double-free (close() is idempotent, but only if the source looks
        # closed).
        self._lock = existing._lock
        self._item = existing._item
        existing._item = c_null[Self.T]()

    def lock(mut self) -> MutexGuard[Self.T]:
        var owner = _thread_owner()
        self._lock[unsafe_offset=0].lock(owner)
        return MutexGuard[Self.T](self._lock, owner, self._item)

    def is_closed(self) -> Bool:
        """True after close() — the mutex owns no storage."""
        return Int(self._item) == 0

    def close(mut self):
        """Explicit teardown: free the guarded item's storage.
        Idempotent — a second call is a no-op, so a double-close can never
        double-free. Call only when no guards are alive."""
        if Int(self._item) == 0:
            return
        self._item.unsafe_free()
        self._item = c_null[Self.T]()
