import Darwin
import Foundation

// Finds mac-control and mac-exec processes started from this app that are older than the programs now on
// disk, which happens when MacControl was updated while a client was running.
enum RunningServers {
    struct Old: Equatable {
        // Client names, such as Claude Desktop, sorted; "unknown" counts servers whose client is not recognized.
        let clients: [String]
        let unknown: Int
    }

    static func old(programs: [URL]) -> Old {
        var modified: [String: Date] = [:]
        for program in programs {
            if let date = (try? FileManager.default.attributesOfItem(atPath: program.path))?[.modificationDate] as? Date {
                modified[program.path] = date
            }
        }
        var clients = Set<String>(), unknown = 0
        for pid in allPIDs() {
            guard let path = path(of: pid), let programDate = modified[path], let info = info(of: pid) else { continue }
            let started = Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec))
            guard OldServers.isOld(started: started, programModified: programDate) else { continue }
            if let name = OldServers.clientName(ancestors: ancestors(of: info)) { clients.insert(name) } else { unknown += 1 }
        }
        return Old(clients: clients.sorted(), unknown: unknown)
    }

    private static func allPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return pids.prefix(Int(max(filled, 0))).filter { $0 > 0 }
    }

    private static func path(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        return proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : nil
    }

    private static func info(of pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    private static func ancestors(of info: proc_bsdinfo) -> [String] {
        var paths: [String] = []
        var parent = pid_t(info.pbi_ppid)
        while parent > 1, paths.count < 8, let next = Self.info(of: parent) {
            paths.append(path(of: parent) ?? "")
            parent = pid_t(next.pbi_ppid)
        }
        return paths
    }
}
