import Foundation

struct WorkspaceFileError: Error, CustomStringConvertible {
    let description: String
}

// Opens workspace files one path component at a time, never following symbolic links. The sandbox
// can change the workspace at any moment, so a folder it replaces with a link after a path was
// checked makes the open fail instead of leading outside the workspace, and a FIFO or device it puts
// in place of a file is refused without blocking.
struct WorkspaceFiles {
    let root: String // with symbolic links resolved

    private func components(_ resolved: String) throws -> [String] {
        guard isSame(resolved, orInside: root) else {
            throw WorkspaceFileError(description: "The path is outside the workspace.")
        }
        return resolved.dropFirst(root.count).split(separator: "/").map(String.init)
    }

    private func failure(_ code: Int32) -> WorkspaceFileError {
        // Opening a FIFO for writing without a reader, or a device, fails with ENXIO when O_NONBLOCK is set.
        if code == ENXIO || code == EOPNOTSUPP {
            return WorkspaceFileError(description: "The path is not a regular file.")
        }
        if code == ELOOP || code == ENOTDIR {
            return WorkspaceFileError(description: "The path changed while it was being opened, or goes through a symbolic link.")
        }
        return WorkspaceFileError(description: String(cString: strerror(code)))
    }

    // Opens a folder given as components below the root, optionally creating missing folders.
    private func openFolder(_ names: [String], create: Bool) throws -> Int32 {
        var fd = open(root, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw failure(errno) }
        for name in names {
            if create, mkdirat(fd, name, 0o755) != 0, errno != EEXIST {
                let code = errno; close(fd); throw failure(code)
            }
            let next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let code = errno
            close(fd)
            guard next >= 0 else { throw failure(code) }
            fd = next
        }
        return fd
    }

    // Opens a regular file with `flags` (such as O_RDONLY or O_WRONLY | O_CREAT | O_APPEND).
    func openFile(_ resolved: String, flags: Int32, createFolders: Bool = false) throws -> FileHandle {
        let names = try components(resolved)
        guard let name = names.last else { throw WorkspaceFileError(description: "The path is the workspace folder itself.") }
        let folder = try openFolder(Array(names.dropLast()), create: createFolders)
        defer { close(folder) }
        // O_NONBLOCK keeps a FIFO from blocking the open; it has no effect on regular files.
        let fd = openat(folder, name, flags | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw failure(errno) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            close(fd)
            throw WorkspaceFileError(description: "The path is not a regular file.")
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    // Lists a folder without following symbolic links. Returns at most `limit` entries, sorted by name,
    // and whether there were more. The sandbox can fill a folder with any number of entries, so at most
    // `scanLimit` names are read; past that the listing is a sorted sample of the first names found.
    func list(_ resolved: String, limit: Int, scanLimit: Int = 10_000) throws -> (entries: [[String: Any]], truncated: Bool) {
        let fd = try openFolder(try components(resolved), create: false)
        guard let directory = fdopendir(fd) else { let code = errno; close(fd); throw failure(code) }
        defer { closedir(directory) }
        var names: [String] = []
        var scannedAll = true
        while let entry = readdir(directory) {
            if names.count >= scanLimit { scannedAll = false; break }
            let name = withUnsafeBytes(of: entry.pointee.d_name) { String(decoding: $0.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self) }
            if name != ".", name != ".." { names.append(name) }
        }
        names.sort()
        let entries: [[String: Any]] = names.prefix(limit).map { name in
            var info = stat()
            guard fstatat(dirfd(directory), name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                return ["name": name, "type": "other", "bytes": 0]
            }
            let type: String
            switch info.st_mode & S_IFMT {
            case S_IFDIR: type = "folder"
            case S_IFLNK: type = "link"
            case S_IFREG: type = "file"
            default: type = "other"
            }
            return ["name": name, "type": type, "bytes": Int(info.st_size)]
        }
        return (entries, !scannedAll || names.count > limit)
    }
}
