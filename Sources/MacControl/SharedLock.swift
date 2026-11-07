import Foundation

// A lock shared by every mac-control server of this user. Each client starts its own server, so input from two
// clients could interleave, or one could restore the clipboard over the other's paste, and each server's check
// for a running recording sees only its own. The lock is an flock on a file in the user's temporary folder, so
// the system releases it when the server holding it ends, however it ends. Each SharedLock object is one holder.
final class SharedLock {
    private let path: String
    private var descriptor: Int32 = -1
    // The recording lock is released from the recording process's termination handler, on another thread.
    private let guardLock = NSLock()

    init(_ name: String) {
        path = (Self.folder as NSString).appendingPathComponent("mac-control-\(name).lock")
    }

    // The user's temporary folder as the system assigns it. A client can start its server with another TMPDIR,
    // which would put its lock files somewhere the other servers do not look.
    private static let folder: String = {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        return length > 0 && length <= buffer.count ? String(cString: buffer) : NSTemporaryDirectory()
    }()

    var isHeld: Bool {
        guardLock.lock(); defer { guardLock.unlock() }
        return descriptor >= 0
    }

    // Takes the lock if no other server holds it. Throws only when the lock file cannot be used.
    func tryLock() throws -> Bool {
        guardLock.lock(); defer { guardLock.unlock() }
        if descriptor >= 0 { return true }
        let opened = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard opened >= 0 else {
            throw ToolFailure("Could not open \(path) to coordinate with other mac-control servers: \(String(cString: strerror(errno))).", .internalError)
        }
        // Another account could have made the file first; it must not be able to hold this user's lock.
        var info = stat()
        guard fstat(opened, &info) == 0, info.st_uid == getuid() else {
            close(opened)
            throw ToolFailure("\(path) belongs to another user, so mac-control cannot coordinate with your other servers. Remove it and try again.", .setup)
        }
        guard flock(opened, LOCK_EX | LOCK_NB) == 0 else {
            close(opened)
            return false
        }
        descriptor = opened
        return true
    }

    // Waits up to timeout for the lock, checking for cancellation, and returns whether it was taken.
    func lock(timeout: TimeInterval, cancellation: Cancellation) throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if try tryLock() { return true }
            try cancellation.check()
            if Date() >= deadline { return false }
            usleep(50_000)
        }
    }

    func unlock() {
        guardLock.lock(); defer { guardLock.unlock() }
        guard descriptor >= 0 else { return }
        close(descriptor)
        descriptor = -1
    }
}
