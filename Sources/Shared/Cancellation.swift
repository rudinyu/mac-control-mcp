import Foundation

// Set when the client cancels a request. Tools check it only where stopping is safe: while reading or waiting,
// before any input is sent, never halfway through an action.
final class Cancellation {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
    }

    // Stops the tool with CancelledError once the request is cancelled.
    func check() throws {
        if isCancelled { throw CancelledError() }
    }
}

// Thrown by a tool that stopped because its request was cancelled. The client no longer waits for an
// answer, so none is sent.
struct CancelledError: Error, CustomStringConvertible {
    var description: String { "The request was cancelled." }
}
