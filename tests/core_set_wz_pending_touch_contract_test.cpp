#include "../lara/overlay/CoreSetPendingTouchQueue.h"

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <limits>
#include <vector>

using namespace coreset_pending_touch;

#define CHECK(condition) do { \
    if (!(condition)) { \
        std::fprintf(stderr, "pending touch contract failed at %d: %s\n", \
                     __LINE__, #condition); \
        std::exit(1); \
    } \
} while (false)

static PendingTouchAction action(std::int64_t pointer, Kind kind, double expiry,
                                 std::uint64_t generation, std::vector<int> &delivered,
                                 int marker) {
    return {pointer, kind, expiry, generation,
            [&delivered, marker] { delivered.push_back(marker); }};
}

static void testOrderedMainDeliveryAndCoalescing() {
    PendingTouchQueue queue;
    std::vector<int> delivered;
    CHECK(queue.enqueue(action(7, Kind::Began, 10, 1, delivered, 1), 1, 1) ==
          EnqueueResult::Appended);
    CHECK(queue.enqueue(action(7, Kind::Moved, 10, 1, delivered, 2), 2, 1) ==
          EnqueueResult::Appended);
    CHECK(queue.enqueue(action(7, Kind::Moved, 10, 1, delivered, 3), 3, 1) ==
          EnqueueResult::CoalescedMove);
    CHECK(queue.enqueue(action(7, Kind::Ended, 10, 1, delivered, 4), 4, 1) ==
          EnqueueResult::Appended);
    CHECK(queue.size() == 3);

    // The serial owner pops one entry at a time and rechecks it on main.
    PendingTouchAction pending;
    for (int marker : {1, 3, 4}) {
        CHECK(queue.popNext(5, 1, &pending) == PopResult::Action);
        CHECK(canExecute(pending, 5.1, 1));
        pending.actionBlock();
        CHECK(delivered.back() == marker);
    }
    CHECK(queue.popNext(5, 1, &pending) == PopResult::Empty);
    CHECK((delivered == std::vector<int>{1, 3, 4}));

    // Neither another pointer nor a terminal tail is a Move coalescing target.
    CHECK(queue.enqueue(action(7, Kind::Moved, 12, 1, delivered, 5), 6, 1) ==
          EnqueueResult::Appended);
    CHECK(queue.enqueue(action(8, Kind::Moved, 12, 1, delivered, 6), 6, 1) ==
          EnqueueResult::Appended);
    CHECK(queue.enqueue(action(8, Kind::Ended, 12, 1, delivered, 7), 6, 1) ==
          EnqueueResult::Appended);
    CHECK(queue.enqueue(action(8, Kind::Moved, 12, 1, delivered, 8), 6, 1) ==
          EnqueueResult::Appended);
    CHECK(queue.size() == 4);
}

static void testCancelAndGenerationInvalidation() {
    static_assert(static_cast<unsigned>(Kind::Began) == 0, "WZ begin kind");
    static_assert(static_cast<unsigned>(Kind::Moved) == 1, "WZ move kind");
    static_assert(static_cast<unsigned>(Kind::Ended) == 2, "WZ end kind");
    static_assert(static_cast<unsigned>(Kind::AtomicGesture) == 3,
                  "Kind 3 is not a physical cancel");

    PendingTouchQueue queue;
    std::vector<int> delivered;
    CHECK(queue.enqueue(action(3, Kind::Began, 2, 1, delivered, 10), 1, 1) ==
          EnqueueResult::Appended);
    PendingTouchAction inFlight;
    CHECK(queue.popNext(1, 1, &inFlight) == PopResult::Action);
    CHECK(queue.enqueue(action(3, Kind::Moved, 2, 1, delivered, 11), 1, 1) ==
          EnqueueResult::Appended);

    // Physical Cancel has no queue kind in WZ. Its owner invalidates the
    // lifecycle generation; both queued and already-popped work then fail.
    queue.reset(2);
    CHECK(queue.size() == 0);
    CHECK(!canExecute(inFlight, 1.1, 2));
    CHECK(queue.enqueue(action(3, Kind::Ended, 3, 1, delivered, 12), 1.1, 2) ==
          EnqueueResult::Rejected);
    CHECK(queue.enqueue(action(3, Kind::Began, 3, 2, delivered, 13), 1.1, 2) ==
          EnqueueResult::Appended);
}

static void testExpiryAndStaleInputs() {
    PendingTouchQueue queue;
    std::vector<int> delivered;
    static_assert(kExpirationInterval == 0.75, "WZ expiration interval");
    CHECK(queue.enqueue(action(1, Kind::Began, 1.75, 1, delivered, 1), 1, 1) ==
          EnqueueResult::Appended);
    PendingTouchAction pending;
    CHECK(queue.popNext(1.1, 1, &pending) == PopResult::Action);
    CHECK(canExecute(pending, 1.749, 1));
    CHECK(!canExecute(pending, 1.75, 1)); // Main was delayed to the deadline.
    CHECK(delivered.empty());

    CHECK(queue.enqueue(action(2, Kind::Began, 2, 1, delivered, 2), 1, 1) ==
          EnqueueResult::Appended);
    CHECK(queue.enqueue(action(2, Kind::Moved, 3, 1, delivered, 3), 1, 1) ==
          EnqueueResult::Appended);
    std::int64_t expired = -1;
    CHECK(queue.popNext(2, 1, &pending, &expired) ==
          PopResult::DroppedExpiredLifecycle);
    CHECK(expired == 2 && queue.size() == 0);

    const double nan = std::numeric_limits<double>::quiet_NaN();
    CHECK(queue.enqueue(action(-1, Kind::Began, 4, 1, delivered, 4), 1, 1) ==
          EnqueueResult::Rejected);
    CHECK(queue.enqueue(action(5, Kind::Began, nan, 1, delivered, 5), 1, 1) ==
          EnqueueResult::Rejected);
    CHECK(queue.enqueue(action(5, Kind::Began, 4, 1, delivered, 6), nan, 1) ==
          EnqueueResult::Rejected);
    CHECK(queue.enqueue(action(5, static_cast<Kind>(4), 4, 1, delivered, 7), 1, 1) ==
          EnqueueResult::Rejected);
}

static void testAtomicPruningAndNoInventedDepthLimit() {
    PendingTouchQueue queue;
    std::vector<int> delivered;
    CHECK(queue.enqueue(action(1, Kind::AtomicGesture, 2, 1, delivered, 1), 1, 1) ==
          EnqueueResult::Appended);
    CHECK(queue.enqueue(action(2, Kind::Began, 10, 1, delivered, 2), 2, 1) ==
          EnqueueResult::AppendedAfterPruningAtomic);
    CHECK(queue.size() == 1);

    // WZ's recovered mutable-array policy has no fixed 64-entry eviction.
    for (int i = 0; i < 512; ++i) {
        CHECK(queue.enqueue(action(100 + i, Kind::Began, 10, 1, delivered, i), 3, 1) ==
              EnqueueResult::Appended);
    }
    CHECK(queue.size() == 513);
    PendingTouchAction pending;
    CHECK(queue.popNext(4, 1, &pending) == PopResult::Action);
    CHECK(pending.pointerID == 2);
    CHECK(queue.size() == 512);
}

int main() {
    testOrderedMainDeliveryAndCoalescing();
    testCancelAndGenerationInvalidation();
    testExpiryAndStaleInputs();
    testAtomicPruningAndNoInventedDepthLimit();
    std::puts("CoreSet WZ pending touch contract passed");
    return 0;
}
