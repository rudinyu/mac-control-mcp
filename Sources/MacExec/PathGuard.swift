import Foundation

// Locations in the home folder that hold credentials, or that run code on the Mac when changed.
// Nothing at, inside, or above one of these may be mounted into the sandbox, and the workspace
// may not be one of them.
let sensitiveHomePaths = [
    // Credentials and keys
    ".ssh", ".gnupg", ".aws", ".azure", ".kube", ".docker", ".netrc", ".npmrc", ".pypirc",
    ".git-credentials", ".terraform.d", ".cargo", ".gem", ".m2", ".gradle",
    // Settings that run code: shells, editors, and agents, whose hooks and MCP servers run on the Mac
    ".config", ".local", ".gitconfig", ".claude", ".claude.json", ".codex", ".vscode", ".oh-my-zsh",
    ".zshrc", ".zprofile", ".zshenv", ".zlogin", ".zlogout", ".zsh_history",
    ".bashrc", ".bash_profile", ".bash_login", ".bash_history", ".profile",
    "Library",
]

// Resolves every symbolic link in an existing path, or in the deepest existing ancestor of a path
// that does not exist yet, then appends the components that do not exist.
func resolvedPath(_ url: URL) -> String {
    var existing = url.standardizedFileURL
    var missing: [String] = []
    while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
        missing.insert(existing.lastPathComponent, at: 0)
        existing.deleteLastPathComponent()
    }
    var result = existing.resolvingSymlinksInPath()
    for component in missing { result.appendPathComponent(component) }
    return result.standardizedFileURL.path
}

func isSame(_ path: String, orInside root: String) -> Bool {
    path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
}

// Maps a path from the agent to a host path inside the workspace. Accepts paths relative to the
// workspace and paths under /workspace, the workspace's location inside the container. Returns nil
// for anything that resolves outside the workspace, including through symbolic links.
func resolveInWorkspace(_ path: String, workspace: URL) -> URL? {
    guard !path.isEmpty, !path.contains("\u{0}") else { return nil }
    var relative = path
    if path == "/workspace" {
        relative = "."
    } else if path.hasPrefix("/workspace/") {
        relative = String(path.dropFirst("/workspace/".count))
    } else if path.hasPrefix("/") || path.hasPrefix("~") {
        return nil
    }
    let root = resolvedPath(workspace)
    let target = resolvedPath(URL(fileURLWithPath: root).appendingPathComponent(relative))
    return isSame(target, orInside: root) ? URL(fileURLWithPath: target) : nil
}

// Explains why a folder may not be shared with the sandbox, or returns nil when it may.
// `protected` lists further folders, such as this project, that the sandbox must not reach.
func mountRejection(_ folder: URL, home: URL, protected: [URL] = []) -> String? {
    let path = resolvedPath(folder)
    let homePath = resolvedPath(home)
    if path == "/" { return "\(path) is the whole disk." }
    // Docker's --mount option is a comma-separated list, so a comma would add mount options.
    if path.contains(",") || path.contains("\n") || path.contains("\r") {
        return "\(path) contains a comma or line break, which cannot be passed to Docker safely."
    }
    for protectedFolder in protected {
        let other = resolvedPath(protectedFolder)
        if isSame(path, orInside: other) || isSame(other, orInside: path) {
            return "\(path) overlaps \(other), which runs on the Mac and must not be changed from the sandbox."
        }
    }
    for name in sensitiveHomePaths {
        let sensitive = resolvedPath(URL(fileURLWithPath: homePath).appendingPathComponent(name))
        if isSame(path, orInside: sensitive) { return "\(path) is or is inside \(sensitive), which holds credentials or settings." }
        if isSame(sensitive, orInside: path) { return "\(path) contains \(sensitive), which holds credentials or settings." }
    }
    return nil
}
