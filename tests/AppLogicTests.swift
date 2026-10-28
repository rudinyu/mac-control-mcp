// Unit tests for MacControl.app's logic that does not need a window: client configuration and
// runtime selection. Built with App/Sources/ClientConfig.swift and RuntimePlan.swift by scripts/ci.sh.

import Foundation

private var failures = 0

private func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    if condition {
        print("ok   \(name)")
    } else {
        failures += 1
        print("FAIL \(name) \(detail())")
    }
}

private func json(_ data: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

@main
private enum AppLogicTests {
    static func main() {
        let control = ServerSpec(name: "mac-control", command: "/Applications/MacControl.app/Contents/Helpers/mac-control-mcp", environment: [:])
        let exec = ServerSpec(name: "mac-exec", command: "/Applications/MacControl.app/Contents/Helpers/mac-exec-mcp",
                              environment: ["MAC_EXEC_WORKSPACE": "/Users/me/Agent Workspace", "MAC_EXEC_ALLOW_HOST": "1"])

        // Claude Desktop merge
        let existing = Data(#"{"globalShortcut":"Cmd+Space","mcpServers":{"other":{"command":"/bin/other","args":["-x"]},"mac-control":{"command":"/old/path"}}}"#.utf8)
        let merged = try! ClientConfig.mergeClaudeDesktop(existing, servers: [control, exec])
        let root = json(merged)
        let servers = root["mcpServers"] as? [String: Any] ?? [:]
        check("merge keeps other settings", root["globalShortcut"] as? String == "Cmd+Space")
        check("merge keeps other servers", (servers["other"] as? [String: Any])?["command"] as? String == "/bin/other")
        check("merge replaces an old entry", (servers["mac-control"] as? [String: Any])?["command"] as? String == control.command)
        check("merge writes the environment", ((servers["mac-exec"] as? [String: Any])?["env"] as? [String: String]) == exec.environment)
        check("merge leaves no env for a server without one", (servers["mac-control"] as? [String: Any])?["env"] == nil)
        check("merging again changes nothing", (try? ClientConfig.mergeClaudeDesktop(merged, servers: [control, exec])) == merged)
        check("a merged file matches", ClientConfig.claudeDesktopMatches(merged, servers: [control, exec]))
        check("an old file does not match", !ClientConfig.claudeDesktopMatches(existing, servers: [control, exec]))
        check("a missing file does not match", !ClientConfig.claudeDesktopMatches(nil, servers: [control]))
        check("merge creates a file from nothing", (json((try? ClientConfig.mergeClaudeDesktop(nil, servers: [control])) ?? Data())["mcpServers"] as? [String: Any])?["mac-control"] != nil)
        check("malformed JSON is refused", (try? ClientConfig.mergeClaudeDesktop(Data("{not json".utf8), servers: [control])) == nil)
        check("a non-object mcpServers is refused", (try? ClientConfig.mergeClaudeDesktop(Data(#"{"mcpServers":[1]}"#.utf8), servers: [control])) == nil)

        let removed = json(try! ClientConfig.removeFromClaudeDesktop(merged))
        check("removal keeps only other servers", Set((removed["mcpServers"] as? [String: Any] ?? [:]).keys) == ["other"])
        check("removal keeps other settings", removed["globalShortcut"] as? String == "Cmd+Space")
        check("removal refuses malformed JSON", (try? ClientConfig.removeFromClaudeDesktop(Data("{".utf8))) == nil)
        check("servers detected after merge", ClientConfig.claudeDesktopHasServers(merged))
        check("servers not detected after removal", !ClientConfig.claudeDesktopHasServers(try! ClientConfig.removeFromClaudeDesktop(merged)))
        check("servers not detected in a missing file", !ClientConfig.claudeDesktopHasServers(nil))

        // CLI commands
        let claude = ClientConfig.claudeCodeCommands(exec)
        check("claude: remove first", claude[0] == ["mcp", "remove", "--scope", "user", "mac-exec"])
        check("claude: add for every project, environment sorted, command last",
              claude[1] == ["mcp", "add", "--scope", "user", "--transport", "stdio", "mac-exec",
                            "-e", "MAC_EXEC_ALLOW_HOST=1", "-e", "MAC_EXEC_WORKSPACE=/Users/me/Agent Workspace",
                            "--", exec.command], "\(claude[1])")
        let codex = ClientConfig.codexCommands(exec)
        check("codex: underscore name", codex[0] == ["mcp", "remove", "mac_exec"])
        check("codex: add", codex[1] == ["mcp", "add", "mac_exec", "--env", "MAC_EXEC_ALLOW_HOST=1",
                                         "--env", "MAC_EXEC_WORKSPACE=/Users/me/Agent Workspace", "--", exec.command], "\(codex[1])")
        check("display quotes spaces", ClientConfig.displayCommand("claude", ["-e", "A=b c"]) == "claude -e 'A=b c'")
        check("display quotes single quotes", ClientConfig.displayCommand("x", ["it's"]) == #"x 'it'\''s'"#)

        // Codex TOML option
        let toml = """
        model = "o3"

        [mcp_servers.mac_exec]
        command = "/x"

        [mcp_servers.mac_exec.env]
        tool_timeout_sec_note = "unrelated"

        [mcp_servers.other]
        tool_timeout_sec = 5
        """
        let added = ClientConfig.setCodexServerOption(toml, server: "mac_exec", key: "tool_timeout_sec", value: "620")
        check("toml: inserted under the server's own table",
              added.contains("[mcp_servers.mac_exec]\ntool_timeout_sec = 620\ncommand = \"/x\""), added)
        check("toml: other tables untouched", added.contains("[mcp_servers.other]\ntool_timeout_sec = 5")
              && added.contains("tool_timeout_sec_note = \"unrelated\""))
        let replaced = ClientConfig.setCodexServerOption(added.replacingOccurrences(of: "= 620", with: "= 30"),
                                                         server: "mac_exec", key: "tool_timeout_sec", value: "620")
        check("toml: an existing value is replaced, not duplicated",
              replaced.components(separatedBy: "tool_timeout_sec = 620").count == 2 && !replaced.contains("= 30"))
        check("toml: unchanged when the server is missing",
              ClientConfig.setCodexServerOption("a = 1", server: "mac_exec", key: "k", value: "1") == "a = 1")

        // Runtime selection
        check("Apple silicon on macOS 26 uses Apple container",
              RuntimeSelection.choose(cpu: .appleSilicon, macOSMajor: 26, workingDocker: "/usr/local/bin/docker") == .appleContainer)
        check("Apple silicon on macOS 15 reuses Docker",
              RuntimeSelection.choose(cpu: .appleSilicon, macOSMajor: 15, workingDocker: "/d") == .existingDocker("/d"))
        check("Intel reuses a working Docker", RuntimeSelection.choose(cpu: .intel, macOSMajor: 26, workingDocker: "/d") == .existingDocker("/d"))
        check("Intel without Docker installs Colima", RuntimeSelection.choose(cpu: .intel, macOSMajor: 26, workingDocker: nil) == .managedColima)

        // Version comparison for the update check
        check("newer patch", AppVersion.isNewer("v0.3.4", than: "0.3.3"))
        check("same version is not newer", !AppVersion.isNewer("v0.3.3", than: "0.3.3"))
        check("older is not newer", !AppVersion.isNewer("v0.3.2", than: "0.3.3"))
        check("numeric, not text, order", AppVersion.isNewer("0.3.10", than: "0.3.9"))
        check("missing parts count as zero", !AppVersion.isNewer("0.4", than: "0.4.0") && AppVersion.isNewer("0.4.1", than: "0.4"))
        check("suffix ignored", !AppVersion.isNewer("v0.3.3-beta", than: "0.3.3"))

        // Manifest and checksums
        for download in [Manifest.colima(.intel), Manifest.colima(.appleSilicon), Manifest.lima(.intel), Manifest.lima(.appleSilicon),
                         Manifest.dockerCLI(.intel), Manifest.dockerCLI(.appleSilicon), Manifest.appleContainer] {
            check("manifest: \(download.url.lastPathComponent) uses HTTPS and a full SHA-256",
                  download.url.scheme == "https" && download.sha256.count == 64 && download.sha256.allSatisfy(\.isHexDigit))
        }
        check("manifest: architectures pick different files",
              Manifest.lima(.intel).url != Manifest.lima(.appleSilicon).url && Manifest.dockerCLI(.intel).sha256 != Manifest.dockerCLI(.appleSilicon).sha256)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("maccontrol-checksum-\(UUID().uuidString)")
        try! Data("abc".utf8).write(to: file)
        check("sha256 of a known value", (try? Checksum.sha256(of: file)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        check("a wrong checksum does not match", !Checksum.matches(file, String(repeating: "0", count: 64)))
        try? FileManager.default.removeItem(at: file)

        if failures > 0 {
            print("\(failures) app logic test(s) failed")
            exit(1)
        }
        print("All app logic tests passed")
    }
}
