import Darwin
import Foundation

// Finds mac-control and mac-exec processes started from this app that still run a program file that has
// since been replaced, which happens when MacControl was updated while a client was running. Comparing
// the file itself, rather than dates, works however the update was copied in.
enum RunningServers {
    struct Old: Equatable {
        // Client names, such as Claude Desktop, sorted; "unknown" counts servers whose client is not recognized.
        let clients: [String]
        let unknown: Int
    }

    static func old(programs: [URL]) -> Old {
        // Inodes of the programs on disk. The path is the same on both sides, so the volume is too.
        var current: [String: UInt64] = [:]
        for program in programs {
            let path = program.resolvingSymlinksInPath().path
            var info = stat()
            if stat(path, &info) == 0 { current[path] = UInt64(info.st_ino) }
        }
        var clients = Set<String>(), unknown = 0
        for pid in allPIDs() {
            guard let path = path(of: pid), let onDisk = current[path],
                  let running = runningInode(pid, path: path), running != onDisk, let info = info(of: pid) else { continue }
            if let name = OldServers.clientName(ancestors: ancestors(of: info)) { clients.insert(name) } else { unknown += 1 }
        }
        return Old(clients: clients.sorted(), unknown: unknown)
    }

    // A program maps its own file within its first few regions, ahead of libraries and the shared cache.
    private static let regionsToSearch = 64

    // The inode of the file the process mapped from its program path, which stays the replaced file's after
    // an update. Returns nil when it cannot be read, so the server counts as current: a wrong warning
    // would keep MacControl from reporting Ready, while a missed one only leaves the old advice.
    private static func runningInode(_ pid: pid_t, path: String) -> UInt64? {
        var region = proc_regionwithpathinfo()
        let size = Int32(MemoryLayout<proc_regionwithpathinfo>.size)
        var address: UInt64 = 0
        for _ in 0..<regionsToSearch {
            guard proc_pidinfo(pid, PROC_PIDREGIONPATHINFO, address, &region, size) == size else { return nil }
            let regionPath = withUnsafeBytes(of: region.prp_vip.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            let fileStat = region.prp_vip.vip_vi.vi_stat
            if fileStat.vst_ino != 0, regionPath == path { return fileStat.vst_ino }
            address = region.prp_prinfo.pri_address + region.prp_prinfo.pri_size
        }
        return nil
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
