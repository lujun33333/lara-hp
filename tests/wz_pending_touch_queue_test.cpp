#include "../lara/kexploit/wz/WZHUDPendingTouchQueue.h"

#include <cassert>
#include <cstdint>
#include <vector>

using wzhud_pending_touch::EnqueueResult;
using wzhud_pending_touch::Kind;
using wzhud_pending_touch::PendingTouchAction;
using wzhud_pending_touch::PendingTouchQueue;
using wzhud_pending_touch::PopResult;
using wzhud_pending_touch::canExecute;

static PendingTouchAction action(std::int64_t pointerID,
                                 Kind kind,
                                 double expirationTime,
                                 std::uint64_t generation,
                                 std::vector<int> &executed,
                                 int marker) {
    return PendingTouchAction{
        pointerID,
        kind,
        expirationTime,
        generation,
        [&executed, marker] { executed.push_back(marker); },
    };
}

static PendingTouchAction pop(PendingTouchQueue &queue,
                              double now,
                              std::uint64_t generation) {
    PendingTouchAction pending;
    assert(queue.popNext(now, generation, &pending) == PopResult::Action);
    return pending;
}

int main() {
    static_assert(static_cast<unsigned>(Kind::Began) == 0, "AX down kind");
    static_assert(static_cast<unsigned>(Kind::Moved) == 1, "AX move kind");
    static_assert(static_cast<unsigned>(Kind::Ended) == 2, "AX up kind");
    static_assert(static_cast<unsigned>(Kind::AtomicGesture) == 3,
                  "AX point-only/timed kind");
    static_assert(wzhud_pending_touch::kExpirationInterval == 0.75,
                  "AX 0x10087b06c expiration interval");

    std::vector<int> executed;

    // AX preserves FIFO for Begin -> Move -> End; terminal actions neither
    // jump the queue nor evict an earlier action.
    PendingTouchQueue ordered;
    assert(ordered.enqueue(action(7, Kind::Began, 10, 1, executed, 1), 1, 1) ==
           EnqueueResult::Appended);
    assert(ordered.enqueue(action(7, Kind::Moved, 10, 1, executed, 2), 2, 1) ==
           EnqueueResult::Appended);
    assert(ordered.enqueue(action(7, Kind::Ended, 10, 1, executed, 3), 3, 1) ==
           EnqueueResult::Appended);
    for (int expected = 1; expected <= 3; ++expected) {
        PendingTouchAction pending = pop(ordered, 4, 1);
        pending.actionBlock();
        assert(executed.back() == expected);
    }

    // 0x1008784bc selects the tail (count-1).  A same-pointer Move replaces
    // only a Move tail; this is AX's actual coalescing rule.
    PendingTouchQueue coalesced;
    assert(coalesced.enqueue(action(8, Kind::Began, 20, 1, executed, 10), 1, 1) ==
           EnqueueResult::Appended);
    assert(coalesced.enqueue(action(8, Kind::Moved, 20, 1, executed, 11), 2, 1) ==
           EnqueueResult::Appended);
    assert(coalesced.enqueue(action(8, Kind::Moved, 20, 1, executed, 12), 3, 1) ==
           EnqueueResult::CoalescedMove);
    assert(coalesced.size() == 2);
    PendingTouchAction pending = pop(coalesced, 4, 1);
    pending.actionBlock();
    pending = pop(coalesced, 4, 1);
    pending.actionBlock();
    assert((executed.end()[-2] == 10 && executed.back() == 12));

    PendingTouchQueue noCrossPointerMerge;
    assert(noCrossPointerMerge.enqueue(
               action(9, Kind::Moved, 20, 1, executed, 20), 1, 1) ==
           EnqueueResult::Appended);
    assert(noCrossPointerMerge.enqueue(
               action(10, Kind::Moved, 20, 1, executed, 21), 2, 1) ==
           EnqueueResult::Appended);
    assert(noCrossPointerMerge.size() == 2);

    PendingTouchQueue noTerminalMerge;
    assert(noTerminalMerge.enqueue(
               action(11, Kind::Moved, 20, 1, executed, 30), 1, 1) ==
           EnqueueResult::Appended);
    assert(noTerminalMerge.enqueue(
               action(11, Kind::Ended, 20, 1, executed, 31), 2, 1) ==
           EnqueueResult::Appended);
    assert(noTerminalMerge.enqueue(
               action(11, Kind::Moved, 20, 1, executed, 32), 3, 1) ==
           EnqueueResult::Appended);
    assert(noTerminalMerge.size() == 3);

    // AX 0x10085aedc removes expired kind 3 rows one by one.  Equality is
    // expired because its live branch is strictly expirationTime > now.
    PendingTouchQueue atomicExpiry;
    assert(atomicExpiry.enqueue(
               action(9, Kind::AtomicGesture, 5, 1, executed, 40), 1, 1) ==
           EnqueueResult::Appended);
    assert(atomicExpiry.enqueue(
               action(12, Kind::Began, 10, 1, executed, 41), 1, 1) ==
           EnqueueResult::Appended);
    pending = pop(atomicExpiry, 5, 1);
    assert(pending.pointerID == 12 && pending.kind == Kind::Began);

    // The first expired kind 0/1/2 sets the enumeration stop flag and clears
    // the entire lifecycle batch at AX 0x10085ab90.
    PendingTouchQueue lifecycleExpiry;
    assert(lifecycleExpiry.enqueue(
               action(9, Kind::AtomicGesture, 2, 1, executed, 50), 1, 1) ==
           EnqueueResult::Appended);
    assert(lifecycleExpiry.enqueue(
               action(13, Kind::Began, 4, 1, executed, 51), 1, 1) ==
           EnqueueResult::Appended);
    assert(lifecycleExpiry.enqueue(
               action(13, Kind::Moved, 6, 1, executed, 52), 1, 1) ==
           EnqueueResult::Appended);
    std::int64_t expiredPointerID = -1;
    assert(lifecycleExpiry.popNext(4, 1, &pending, &expiredPointerID) ==
           PopResult::DroppedExpiredLifecycle);
    assert(expiredPointerID == 13 && lifecycleExpiry.size() == 0);

    PendingTouchQueue pruneBeforeAppend;
    assert(pruneBeforeAppend.enqueue(
               action(9, Kind::AtomicGesture, 2, 1, executed, 60), 1, 1) ==
           EnqueueResult::Appended);
    assert(pruneBeforeAppend.enqueue(
               action(14, Kind::Began, 10, 1, executed, 61), 2, 1) ==
           EnqueueResult::AppendedAfterPruningAtomic);
    assert(pruneBeforeAppend.size() == 1);

    PendingTouchQueue dropBeforeAppend;
    assert(dropBeforeAppend.enqueue(
               action(15, Kind::Began, 2, 1, executed, 70), 1, 1) ==
           EnqueueResult::Appended);
    assert(dropBeforeAppend.enqueue(
               action(16, Kind::Began, 10, 1, executed, 71), 2, 1) ==
           EnqueueResult::AppendedAfterDroppingLifecycle);
    assert(dropBeforeAppend.size() == 1);
    assert(pop(dropBeforeAppend, 3, 1).pointerID == 16);

    // A block already dispatched to main is checked again.  The queue owner
    // clears the remaining batch when that popped lifecycle action expires.
    PendingTouchQueue mainStall;
    assert(mainStall.enqueue(
               action(17, Kind::Began, 8, 1, executed, 80), 4, 1) ==
           EnqueueResult::Appended);
    assert(mainStall.enqueue(
               action(17, Kind::Moved, 9, 1, executed, 81), 4, 1) ==
           EnqueueResult::Appended);
    pending = pop(mainStall, 4, 1);
    assert(canExecute(pending, 7.99, 1));
    assert(!canExecute(pending, 8, 1));
    mainStall.discardAll();
    assert(mainStall.size() == 0);

    // Scene/hosting generation replacement invalidates both queued and
    // already-dispatched work without inventing an AX action kind.
    PendingTouchQueue generations;
    assert(generations.enqueue(
               action(18, Kind::Began, 20, 1, executed, 90), 1, 1) ==
           EnqueueResult::Appended);
    pending = pop(generations, 2, 1);
    generations.reset(2);
    assert(!canExecute(pending, 2, 2));
    assert(generations.enqueue(
               action(18, Kind::Moved, 20, 2, executed, 91), 2, 2) ==
           EnqueueResult::Appended);

    // AX uses a mutable array and has no evidenced fixed-depth eviction.
    // Preserve every non-coalescible live row rather than silently applying
    // the former guessed maxDepth=64/terminal-priority policy.
    PendingTouchQueue noInventedDepthLimit;
    for (int i = 0; i != 256; ++i) {
        assert(noInventedDepthLimit.enqueue(
                   action(1000 + i, Kind::Began, 100, 1, executed, 100 + i),
                   1, 1) == EnqueueResult::Appended);
    }
    assert(noInventedDepthLimit.size() == 256);

    PendingTouchQueue rejected;
    assert(rejected.enqueue(
               action(19, static_cast<Kind>(4), 10, 1, executed, 399),
               1, 1) == EnqueueResult::Rejected);
    assert(rejected.enqueue(
               action(19, Kind::Began, 1, 1, executed, 400), 1, 1) ==
           EnqueueResult::Rejected);
    assert(rejected.enqueue(
               action(19, Kind::Began, 10, 2, executed, 401), 1, 1) ==
           EnqueueResult::Rejected);
}
