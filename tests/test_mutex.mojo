"""Tests for functions.mutex — Mutex/MutexGuard lifecycle, move semantics,
close()-frees-everything (both the guarded item AND the lock cell), and use
from a spawned thread. The Box-backed mutex closes exactly two heap cells
per instance; close() is idempotent and a close() on a moved-from Mutex is
a no-op (the boxes were transferred away).

Run with: pixi run test  (mojo test_mutex.mojo)
"""

from std.testing import assert_equal, assert_true, assert_false
from std.memory import stack_allocation
from std.ffi import c_ulong, external_call
from std.memory.unsafe_pointer import Pointer

from functions.mutex import Mutex
from platform.ffi import pthread_create, pthread_join, Box


def _thread_owner() -> Int:
    return Int(
        external_call["pthread_self", Pointer[NoneType, MutUntrackedOrigin]]()
    )


def _null() -> Pointer[NoneType, MutUntrackedOrigin]:
    var zero = 0
    return Pointer[NoneType, MutUntrackedOrigin](unsafe_from_address=zero)


struct Counter(Copyable, Movable):
    """Trivial item type — the shape Mutex stores in the wild."""

    var n: Int

    def __init__(out self):
        self.n = 0

    def __init__(out self, *, copy: Self):
        self.n = copy.n


def test_guard_acquire_release() raises:
    """A guard locks on lock() and releases when the with-scope ends:
    increments done inside the scope are visible to a later re-acquire."""
    var m = Mutex[Counter]()
    m.init_with(Counter())
    with m.lock() as p:
        p[unsafe_offset=0].n += 1
        p[unsafe_offset=0].n += 2
    # after the guard dropped, another lock must succeed and see the writes
    with m.lock() as p:
        assert_equal(p[unsafe_offset=0].n, 3)
    m.close()


def test_move_transfers_ownership() raises:
    """A moved Mutex keeps working; the moved-from source must not double
    free when deinit'd (implicit at scope end after the move)."""
    var m = Mutex[Counter]()
    m.init_with(Counter())
    with m.lock() as p:
        p[unsafe_offset=0].n = 7
    var moved = m^
    # `m` is consumed here: its moved-from boxes were transferred, so the
    # implicit deinit of the source must be a no-op (this test double-frees
    # at scope exit if the move broke that).
    assert_false(moved.is_closed())
    with moved.lock() as p:
        assert_equal(p[unsafe_offset=0].n, 7)
    moved.close()
    assert_true(moved.is_closed())


def test_close_is_idempotent() raises:
    """Closes exactly once: item and lock cell are freed by the first
    close(); a second call cannot double-free."""
    var m = Mutex[Counter]()
    m.init_with(Counter())
    assert_false(m.is_closed())
    m.close()
    assert_true(m.is_closed())
    m.close()
    assert_true(m.is_closed())


def test_close_after_guard() raises:
    """Hold a guard, release it, THEN close().

    The lifetime contract: every guard must be dropped before close(), and
    any cross-thread lock user must be joined (pthread_join) before close()
    — exactly the order platform.Gamepad.close() follows. There is no
    close-while-guarded detection in the Mutex itself; ordering is the
    caller's responsibility. This test stays single-threaded to prove the
    plain main-thread path: guard released -> both cells free cleanly
    without a double-free at the implicit scope deinit."""
    var m = Mutex[Counter]()
    m.init_with(Counter())
    assert_false(m.is_closed())
    with m.lock() as p:
        p[unsafe_offset=0].n = 5
    # Guard has fully released the lock cell at this point: the close()
    # below frees both boxes. (Locking after close would abort — fail fast
    # in the Optional unwrap — which is the intended closed-mutex behavior.)
    m.close()
    assert_true(m.is_closed())


def _bump_entry(
    arg: Pointer[NoneType, MutUntrackedOrigin],
) -> Pointer[NoneType, MutUntrackedOrigin]:
    """Thread entry: lock/unlock the heap-boxed mutex 1000 times."""
    var m = Pointer[Mutex[Counter], MutUntrackedOrigin](
        unsafe_from_address=Int(arg)
    )
    for _ in range(1000):
        with m[unsafe_offset=0].lock() as p:
            p[unsafe_offset=0].n += 1
    return _null()


def test_threaded_use() raises:
    """The mutex is heap-boxed (Box), a spawned thread locks/unlocks it 1000
    times, main joins and observes all increments. Uses the platform.ffi
    pthread_create/pthread_join helpers."""
    var m_box = Box[Mutex[Counter]]()
    m_box.ptr().unsafe_write(Mutex[Counter]())
    m_box.ptr()[unsafe_offset=0].init_with(Counter())

    var tid_cell = stack_allocation[1, c_ulong]()
    var rc = pthread_create(
        tid_cell,
        _bump_entry,
        rebind[Pointer[NoneType, MutUntrackedOrigin]](m_box.ptr()),
    )
    assert_equal(rc, 0)
    pthread_join(tid_cell[unsafe_offset=0])

    with m_box.ptr()[unsafe_offset=0].lock() as p:
        assert_equal(p[unsafe_offset=0].n, 1000)
    m_box.ptr()[unsafe_offset=0].close()
    _ = m_box^  # Box frees; the Mutex cells were closed first

    print("mutex lifecycle OK")


def main() raises:
    test_guard_acquire_release()
    test_move_transfers_ownership()
    test_close_is_idempotent()
    test_close_after_guard()
    test_threaded_use()
    print("All mutex tests passed.")
