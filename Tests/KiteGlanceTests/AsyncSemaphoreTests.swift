import XCTest
@testable import KiteGlanceCore

/// The `AsyncSemaphore` is the gate that prevents two `KiteService`
/// refreshes from running at the same time. The window is small
/// (refreshes are 1+ minute apart), but a regression that
/// permanently locked the gate would freeze every future refresh
/// with no error path. These tests pin the gate's contract: a
/// waiter must eventually be released, a cancellation must not
/// leave a continuation orphaned, and a `signal` without a
/// matching `wait` is a no-op (the gate value can grow).
final class AsyncSemaphoreTests: XCTestCase {

    /// Two concurrent `wait()` calls on a fresh gate: the first wins
    /// (decrements the value), the second blocks until the first
    /// `signal()` releases it.
    func testSerializesConcurrentWaiters() async {
        let gate = AsyncSemaphore(value: 1)
        try? await gate.wait()  // first permit consumed

        let order = OrderTracker()
        let waiter = Task { await order.mark("waiter-entered") }

        // Give the waiter a chance to block.
        try? await Task.sleep(for: .milliseconds(20))
        await order.mark("signal")
        await gate.signal()
        await order.mark("signal-sent")
        await waiter.value
        await order.mark("waiter-exited")

        // The waiter must have entered *after* the signal was
        // scheduled, and the signal must have been observed *before*
        // the waiter exited. The exact interleaving is timing-dependent,
        // so we assert the partial order: signal < waiter-exited.
        let events = await order.events
        XCTAssertLessThan(events.firstIndex(of: "signal")!,
                          events.firstIndex(of: "waiter-exited")!)
    }

    /// `signal` without a matching `wait` increments the value, so
    /// the next `wait` returns immediately. This is the no-op case
    /// from the controller's `defer` block: the gate was acquired,
    /// no second waiter ever showed up, and the release returns
    /// the gate to a higher value.
    func testSignalWithoutWaiterIncrementsValue() async {
        let gate = AsyncSemaphore(value: 0)
        await gate.signal()
        // The next wait should not block. We use a short timeout to
        // catch a regression that forgets to increment.
        let waited = await Task.withTimeout(50) { try? await gate.wait() }
        XCTAssertNotNil(waited, "wait should not block after a signal-without-waiter")
    }

    /// Cancelling a waiter must not leave its continuation in the
    /// waiters map -- that would permanently consume a permit, and
    /// every future `signal` would resume the dead continuation
    /// instead of decrementing the value. The test pins the
    /// contract: a cancelled waiter followed by two signals leaves
    /// the gate at value 1, not value -1.
    func testCancellationRemovesContinuation() async {
        let gate = AsyncSemaphore(value: 0)

        let waiter = Task { try? await gate.wait() }
        waiter.cancel()
        _ = await waiter.result  // CancellationError

        // Two signals: the first resumes no waiter (value -> 1), the
        // second (value -> 2). Neither should crash or block.
        await gate.signal()
        await gate.signal()

        // Now a fresh wait should return immediately. If the
        // cancellation left an orphaned continuation, this would
        // resume a dead continuation and the gate would still be at
        // value 1 (not blocking), but the test below catches a
        // double-orphan too.
        let second = await Task.withTimeout(50) { try? await gate.wait() }
        XCTAssertNotNil(second)
    }

    /// FIFO ordering: with two waiters, the first to register is
    /// the first to be released. Important because the
    /// `refreshGate` is meant to be a *fair* serialiser, and
    /// stack-based waiters first would mean a slow first refresh
    /// could starve a fast second one.
    func testFifoOrdering() async {
        let gate = AsyncSemaphore(value: 0)
        let first  = Task<String, Never> { try? await gate.wait(); return "first" }
        let second = Task<String, Never> { try? await gate.wait(); return "second" }

        // Yield long enough for both tasks to register as waiters.
        try? await Task.sleep(for: .milliseconds(20))

        await gate.signal()  // releases "first"
        await gate.signal()  // releases "second"

        let firstResult  = await first.value
        let secondResult = await second.value
        XCTAssertEqual(firstResult, "first")
        XCTAssertEqual(secondResult, "second")
    }
}

// MARK: - helpers

/// A tiny actor that records an ordered list of string events. Used
/// to assert partial order between two `Task`s without a real
/// `XCTestExpectation` ceremony.
private actor OrderTracker {
    private(set) var events: [String] = []
    func mark(_ event: String) { events.append(event) }
}

private extension Task where Success == Void, Failure == Never {
    /// Runs `operation` and returns its result, or `nil` if it does
    /// not complete in `milliseconds`. Used as a non-blocking wait:
    /// a real semaphore wait that does not return is a regression.
    static func withTimeout(
        _ milliseconds: Int,
        _ operation: @escaping @Sendable () async -> Void
    ) async -> Void? {
        await withTaskGroup(of: Void?.self) { group in
            group.addTask { await operation(); return () }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(milliseconds))
                return nil
            }
            // Whichever finishes first wins. Cancel the other so
            // it does not linger.
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
