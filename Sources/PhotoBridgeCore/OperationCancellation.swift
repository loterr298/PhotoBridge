import Foundation

/// One flag per operation; a UI pause can interrupt a background hash/replay.
/// Cancellation never returns a partial receipt or authorizes a Photos retry.
public final class OperationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    public init() {}
    public func cancel() { lock.lock(); defer { lock.unlock() }; stopped = true }
    public func check() throws {
        lock.lock(); let value = stopped; lock.unlock()
        if value || Task.isCancelled { throw CancellationError() }
    }
}
