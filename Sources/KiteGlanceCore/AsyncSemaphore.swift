import Foundation

/// A one-permit gate so two refreshes never overlap. Cancellation-aware: a
/// cancelled waiter must not leave its continuation orphaned, which would close
/// the gate permanently and freeze every later refresh.
///
/// Lives in `KiteGlanceCore` so the test target can exercise the
/// cancellation behaviour without importing the executable. The Kite
/// refresh path is the canonical user; tests in `AsyncSemaphoreTests`
/// cover the edge cases (orphaned continuation, double-signal,
/// FIFO ordering) that the path itself cannot easily hit.
public actor AsyncSemaphore {
    private var value: Int
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    /// Insertion order of parked waiters. `Dictionary` iteration is
    /// hash-seeded, not FIFO, so ordering is tracked explicitly to honour
    /// the fairness contract (first parked is first released).
    private var order: [UUID] = []

    public init(value: Int) { self.value = value }

    /// Acquire the permit. Throws `CancellationError` if the task is cancelled
    /// while parked -- the caller must NOT release a permit it never acquired,
    /// so this propagates instead of swallowing the cancel (a swallowed cancel
    /// let a later `defer { signal() }` inject a phantom permit and let two
    /// refreshes run at once).
    public func wait() async throws {
        if value > 0 {
            value -= 1
            return
        }

        let id = UUID()
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    waiters[id] = continuation
                    order.append(id)
                }
            } onCancel: {
                Task { await self.cancelWaiter(id) }
            }
        } catch {
            // Cancelled (or otherwise failed) before acquiring: ensure we are
            // not left parked, then propagate so the caller skips its release.
            cancelWaiter(id)
            throw error
        }
    }

    private func cancelWaiter(_ id: UUID) {
        order.removeAll { $0 == id }
        if let continuation = waiters.removeValue(forKey: id) {
            continuation.resume(throwing: CancellationError())
        }
    }

    public func signal() {
        // Release the oldest still-parked waiter. The loop skips ids left in
        // `order` by a race with cancellation, so a signal never silently
        // drops a permit.
        while let id = order.first {
            order.removeFirst()
            if let continuation = waiters.removeValue(forKey: id) {
                continuation.resume()
                return
            }
        }
        value += 1
    }

    /// `defer` cannot `await`, so the gate is released via a detached hop.
    public nonisolated func signalFromDefer() {
        Task { await signal() }
    }
}
