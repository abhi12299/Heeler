import Foundation

/// One local git exec at a time for a Host, including lazy patch and directory
/// reads. Cancellation removes queued work; the owner releases only when its
/// Transport call returns, even when a remote process may still be draining.
///
/// Also serializes Notification Registration file writes across Hosts
/// (`NotificationRegistrationCeremony`): a FIFO, cancellable, non-reentrant
/// critical section is all either use needs.
actor GitExecGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var occupied = false
    private var waiters: [Waiter] = []

    func run<Value: Sendable>(
        _ operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    /// Keeps ungated stores useful for transports whose independent reads are
    /// scripted concurrently. Production supplies the Console's per-Host gate.
    nonisolated static func wrapping<Request: Sendable, Response: Sendable>(
        _ gate: GitExecGate?,
        operation: @escaping @Sendable (Request) async throws -> Response
    ) -> @Sendable (Request) async throws -> Response {
        { request in
            guard let gate else { return try await operation(request) }
            return try await gate.run { try await operation(request) }
        }
    }

    private func acquire() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if !occupied {
                    occupied = true
                    continuation.resume()
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release() {
        if waiters.isEmpty {
            occupied = false
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }
}
