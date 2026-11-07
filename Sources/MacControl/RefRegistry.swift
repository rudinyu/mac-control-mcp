import AppKit
import ApplicationServices
import Foundation

// An element mac_ui_tree gave a ref, kept alive so mac_ax_action acts on that exact object and never on
// another element that merely looks the same.
struct AXRef {
    let element: AXUIElement
    let pid: pid_t
    // A relaunched app, or another process given the same PID, has a different start time.
    let processStart: timeval
    let role: String
}

// The app and snapshot new refs belong to.
struct AXOwner {
    let pid: pid_t
    let start: timeval
    let snapshot: String
}

// A ref is "<snapshot>.<element>", such as k3f9q2.12. Snapshot IDs are random, so a ref from before the
// server restarted cannot name an element of a new snapshot that happens to reuse its number.
func parseRef(_ name: String) -> (snapshot: String, element: Int)? {
    let parts = name.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 2, parts[0].count == 6, let first = parts[0].first, first.isASCII, first.isLowercase,
          parts[0].allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber) }),
          parts[1].first != "0", parts[1].allSatisfy({ $0.isASCII && $0.isNumber }), let element = Int(parts[1]), element > 0 else { return nil }
    return (String(parts[0]), element)
}

// When a process started, which tells a relaunched app from the run its refs came from.
func processStartTime(_ pid: pid_t) -> timeval? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_pid == UInt32(pid) else { return nil }
    return timeval(tv_sec: Int(info.pbi_start_tvsec), tv_usec: Int32(info.pbi_start_tvusec))
}

private func sameStart(_ a: timeval, _ b: timeval) -> Bool {
    a.tv_sec == b.tv_sec && a.tv_usec == b.tv_usec
}

// How many replaced snapshots are remembered, so a ref from one is reported as replaced rather than unknown.
private let retiredSnapshotLimit = 200
// How many refs a snapshot gives out before the app's next read starts a new one, so a long session does not
// keep every element it ever saw.
private let snapshotRefLimit = 5000

// Why a snapshot's refs stopped working. The description finishes a sentence that starts "snapshot <id>".
enum RetireReason: Equatable, CustomStringConvertible {
    // The snapshot named took over after this one gave out as many refs as a snapshot may.
    case replaced(by: String, app: String)
    case earlierRun(app: String)
    case quit

    var description: String {
        switch self {
        case .replaced(let snapshot, let app): return "was replaced by snapshot \(snapshot) of \(app) after giving out as many refs as a snapshot may"
        case .earlierRun(let app): return "belongs to an earlier run of \(app), which has since quit or relaunched"
        case .quit: return "belongs to an app that has quit"
        }
    }
}

// What a ref name names: its element, or why it names none.
enum RefLookup {
    case found(AXRef)
    case notARef
    case retired(snapshot: String, reason: RetireReason)
    // The snapshot is current, but the element went away (existed) or was never given out.
    case missing(snapshot: String, element: Int, existed: Bool)
    // Not a snapshot of this server, as when the ref is from before it restarted.
    case unknownSnapshot(String)
}

// The refs mac_ui_tree, mac_find, mac_wait, and mac_window give out. Each app has a current snapshot, and every
// read adds refs to it, so an element read again keeps its ref and refs keep working until their element goes
// away. A snapshot that has given out its limit of refs is replaced at the app's next read.
final class RefRegistry {
    private var refs: [String: AXRef] = [:]
    // Ref names by element hash, so finding an element's ref does not compare it with every ref.
    private var byHash: [CFHashCode: [String]] = [:]
    private var apps: [pid_t: AXOwner] = [:]
    private var counts: [String: Int] = [:]
    // Snapshots that were replaced or whose app quit, oldest first, with what happened to them.
    private var retired: [(snapshot: String, reason: RetireReason)] = []
    private let processStart: (pid_t) -> timeval?
    private let isRunning: (pid_t) -> Bool
    private let appName: (pid_t) -> String?
    private let refLimit: Int

    // The process checks can be replaced, so tests can relaunch and quit apps, and the limit lowered.
    init(processStart: @escaping (pid_t) -> timeval? = processStartTime,
         isRunning: @escaping (pid_t) -> Bool = { NSRunningApplication(processIdentifier: $0) != nil },
         appName: @escaping (pid_t) -> String? = { NSRunningApplication(processIdentifier: $0)?.localizedName },
         refLimit: Int = snapshotRefLimit) {
        self.processStart = processStart
        self.isRunning = isRunning
        self.appName = appName
        self.refLimit = refLimit
    }

    // The owner for new refs in an app: its current snapshot, or a new one when the app has none, relaunched, or
    // filled its current one. Without the start time a ref could not tell a relaunched app apart, so there are
    // then no refs.
    func owner(_ pid: pid_t) -> AXOwner? {
        guard let start = processStart(pid) else { return nil }
        // Release the refs of apps that have quit, so a long session does not keep their elements.
        let quit = apps.keys.filter { $0 != pid && !isRunning($0) }
        for other in quit { retire(apps.removeValue(forKey: other)!.snapshot, .quit) }
        let current = apps[pid]
        if let current, sameStart(current.start, start), counts[current.snapshot, default: 0] < refLimit {
            if !quit.isEmpty { drop { quit.contains($0.pid) } }
            return current
        }
        let snapshot = newSnapshotID()
        let name = appName(pid) ?? "the app"
        if let current {
            retire(current.snapshot, sameStart(current.start, start) ? .replaced(by: snapshot, app: name) : .earlierRun(app: name))
        }
        drop { $0.pid == pid || quit.contains($0.pid) }
        let owner = AXOwner(pid: pid, start: start, snapshot: snapshot)
        apps[pid] = owner
        counts = counts.filter { count in apps.values.contains { $0.snapshot == count.key } }
        return owner
    }

    // The app's current snapshot, if it has one.
    func snapshot(of pid: pid_t) -> String? {
        apps[pid]?.snapshot
    }

    // An element found again, by another read or as the focused element, keeps its ref.
    func ref(for element: AXUIElement, role: String, owner: AXOwner) -> String {
        let prefix = "\(owner.snapshot)."
        let hash = CFHash(element)
        if let existing = byHash[hash]?.first(where: { $0.hasPrefix(prefix) && refs[$0].map { CFEqual($0.element, element) } == true }) {
            return existing
        }
        counts[owner.snapshot, default: 0] += 1
        let name = prefix + String(counts[owner.snapshot]!)
        refs[name] = AXRef(element: element, pid: owner.pid, processStart: owner.start, role: role)
        byHash[hash, default: []].append(name)
        return name
    }

    func lookup(_ name: String) -> RefLookup {
        guard let parsed = parseRef(name) else { return .notARef }
        if let ref = refs[name] { return .found(ref) }
        if let entry = retired.last(where: { $0.snapshot == parsed.snapshot }) {
            return .retired(snapshot: parsed.snapshot, reason: entry.reason)
        }
        if apps.values.contains(where: { $0.snapshot == parsed.snapshot }) {
            return .missing(snapshot: parsed.snapshot, element: parsed.element,
                            existed: parsed.element <= counts[parsed.snapshot, default: 0])
        }
        return .unknownSnapshot(parsed.snapshot)
    }

    // Checks that the ref's app is still the run the ref came from. When it is not, this drops all of that
    // app's refs, remembers its snapshot as belonging to an earlier run, and returns false.
    func confirmCurrentRun(_ ref: AXRef) -> Bool {
        if let start = processStart(ref.pid), sameStart(start, ref.processStart) { return true }
        drop { $0.pid == ref.pid }
        if let owner = apps.removeValue(forKey: ref.pid) {
            counts[owner.snapshot] = nil
            retire(owner.snapshot, .earlierRun(app: appName(ref.pid) ?? "the app"))
        }
        return false
    }

    // Drops one ref whose element went away; the others in its snapshot keep working.
    func forget(_ name: String) {
        guard let ref = refs.removeValue(forKey: name) else { return }
        let hash = CFHash(ref.element)
        byHash[hash]?.removeAll { $0 == name }
        if byHash[hash]?.isEmpty == true { byHash[hash] = nil }
    }

    private func drop(where gone: (AXRef) -> Bool) {
        refs = refs.filter { !gone($0.value) }
        byHash = Dictionary(grouping: refs.keys) { CFHash(refs[$0]!.element) }
    }

    // A six-character ID, starting with a letter, that no current or remembered snapshot uses.
    private func newSnapshotID() -> String {
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        let characters = letters + Array("0123456789")
        while true {
            let id = String(letters.randomElement()!) + String((0..<5).map { _ in characters.randomElement()! })
            if !apps.values.contains(where: { $0.snapshot == id }) && !retired.contains(where: { $0.snapshot == id }) {
                return id
            }
        }
    }

    private func retire(_ snapshot: String, _ reason: RetireReason) {
        retired.append((snapshot, reason))
        if retired.count > retiredSnapshotLimit { retired.removeFirst(retired.count - retiredSnapshotLimit) }
    }
}
