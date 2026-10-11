# Mutex[T] — BlockingSpinLock-backed mutex with RAII guard, safe Mojo (no pthread FFI).
#
# std.utils.lock.BlockingSpinLock is stdlib's only cross-thread lock atm,
# holds the CPU only for the few dozen ns the holder spends inside.
#
# The spinlock and the guarded item live in typed heap Boxes (platform.ffi):
# guards hand out stable Pointer[T]s, the boxes move with the Mutex (moves
# transfer ownership — no double-free), and BOTH cells are freed on
# close() — nothing leaks per instance.
#
# Usage:
#     var m = Mutex[Counter]()
#     m.init_with(counter)          # T must be Copyable + Deinitable
#     with m.lock() as p:           # p is Pointer[T]
#         p[0].n += 1               # unlocked automatically at scope end
#     m.close()                     # when no guards are alive
#
# Requirement discovered while porting: T needs `Copyable & Deinitable` in
# the constraint or copy-assignment into the generic field fails with
# "value abandoned without being explicitly destroyed" (the compiler must
# know it may destroy the moved-from source).
from std.utils.lock import BlockingSpinLock
from std.memory.unsafe_pointer import Pointer
from std.ffi import external_call

from platform.ffi import Box


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
        _ = self._lock[unsafe_offset=0].unlock(self._owner)


struct Mutex[T: Copyable & Deinitable](Movable):
    """Mutex-guarded shared state (BlockingSpinLock-backed, pure safe Mojo).
    with m.lock() as p: p[unsafe_offset=0].field = ...  # p is Pointer[T]

    Both cells are heap Boxes (stable addresses for guards and threads).
    Ownership moves with the Mutex; close() frees the guarded item AND the
    lock cell, so a closed-and-dropped mutex leaks nothing."""

    var _lock: Optional[Box[BlockingSpinLock]]
    var _item: Optional[Box[Self.T]]

    def __init__(out self):
        # The spinlock and the guarded item live on the heap: the lock is
        # not ImplicitlyCopyable (can't be a plain field in a Movable
        # struct across moves) and the item must outlive callers (guards
        # hand out Pointer[T]). Box aborts on OOM — fail fast, no error
        # path to thread through callers.
        var lock_cell = Box[BlockingSpinLock]()
        lock_cell.ptr().unsafe_write(BlockingSpinLock())
        self._lock = Optional[Box[BlockingSpinLock]](lock_cell^)
        self._item = Optional[Box[Self.T]](Box[Self.T]())

    def __init__(out self, *, deinit move: Self):
        # Steal ownership: the moved-from Mutex holds no boxes, so a deinit
        # or stray close() on it is a no-op (no double-free).
        self._lock = move._lock.take()
        self._item = move._item.take()

    def init_with(mut self, var item: Self.T):
        # T is Copyable for our use cases; explicit `item^` transfer avoids
        # the move-then-abandoned-value problem with generic `item` on the
        # pinned toolchain.
        self._item.value().ptr()[unsafe_offset=0] = item^

    def lock(mut self) -> MutexGuard[Self.T]:
        # Use after close() (or on a moved-from Mutex) aborts in the
        # Optional unwrap — fail fast — instead of dereferencing freed
        # storage.
        var owner = _thread_owner()
        var lock_cell = self._lock.value().ptr()
        lock_cell[unsafe_offset=0].lock(owner)
        return MutexGuard[Self.T](lock_cell, owner, self._item.value().ptr())

    def is_closed(self) -> Bool:
        """True after close() or on a moved-from Mutex — no owned storage."""
        return not self._item

    def close(mut self):
        """Explicit teardown: free the guarded item AND the lock cell.
        Idempotent — a second call (or a close() on a moved-from Mutex)
        is a no-op, so a double-close can never double-free. Call only
        when no guards are alive."""
        if not self._item:
            return
        _ = self._item.take()  # Box dropped here -> frees the item
        _ = self._lock.take()  # Box dropped here -> frees the lock cell
