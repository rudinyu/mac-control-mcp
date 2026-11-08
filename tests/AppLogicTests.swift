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
        let control = ServerSpec(name: "mac-control", command: "/Applications/MacControl.app/Contents/Helpers/MacControlHelper.app/Contents/MacOS/mac-control-mcp", environment: [:])
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

        // Claude Desktop's file keeps its layout
        let laidOut = """
        {
            "zeta": 1,
            "mcpServers": {
                "other": {"command": "/bin/other"},
                "mac-control": {"command": "/Applications/MacControl.app/Contents/Helpers/MacControlHelper.app/Contents/MacOS/mac-control-mcp"}
            },
            "alpha": [1, 2]
        }

        """
        let edited = String(data: try! ClientConfig.mergeClaudeDesktop(Data(laidOut.utf8), servers: [control, exec]), encoding: .utf8)!
        check("merge keeps the other lines as they were", edited.hasPrefix("{\n    \"zeta\": 1,\n    \"mcpServers\": {\n        \"other\": {\"command\": \"/bin/other\"},")
              && edited.hasSuffix("    },\n    \"alpha\": [1, 2]\n}\n"), edited)
        check("merge adds the new server at the members' indent, indenting by the file's step",
              edited.contains("\n        \"mac-exec\": {\n            \"args\": [],\n            \"command\": "), edited)
        check("the edited file has the expected content", ClientConfig.claudeDesktopMatches(Data(edited.utf8), servers: [control, exec]))
        let unedited = String(data: try! ClientConfig.removeFromClaudeDesktop(Data(edited.utf8)), encoding: .utf8)!
        check("removal leaves the rest of the file as it was",
              unedited == "{\n    \"zeta\": 1,\n    \"mcpServers\": {\n        \"other\": {\"command\": \"/bin/other\"}\n    },\n    \"alpha\": [1, 2]\n}\n", unedited)
        for (name, start) in [("no mcpServers", #"{"a": 1}"#), ("an empty mcpServers", #"{"mcpServers": {}}"#), ("an empty file object", "{}")] {
            let result = try! ClientConfig.mergeClaudeDesktop(Data(start.utf8), servers: [control])
            check("merge into \(name) works", ClientConfig.claudeDesktopMatches(result, servers: [control]), String(data: result, encoding: .utf8)!)
            let back = try! ClientConfig.removeFromClaudeDesktop(result)
            check("removal after merging into \(name) leaves no server", !ClientConfig.claudeDesktopHasServers(back), String(data: back, encoding: .utf8)!)
        }
        let first = #"{"mcpServers": {"mac-control": {"command": "\#(control.command)"}, "other": {"command": "x"}}}"#
        check("removing the first server keeps the second", String(data: try! ClientConfig.removeFromClaudeDesktop(Data(first.utf8)), encoding: .utf8)! == #"{"mcpServers": {"other": {"command": "x"}}}"#)

        // A development entry with the same name is not this app's
        let development = Data(#"{"mcpServers": {"mac-control": {"command": "/bin/sh", "args": ["/src/mac-control-mcp/scripts/run-server.sh"]}}}"#.utf8)
        check("a development entry is not counted as connected", !ClientConfig.claudeDesktopHasServers(development))
        check("a development entry is not removed", (try? ClientConfig.removeFromClaudeDesktop(development)) == development)
        check("an app helper is this app's", ClientConfig.isAppCommand(exec.command))
        check("a source build is not", !ClientConfig.isAppCommand("/src/mac-control-mcp/.build/mac-control-mcp"))

        // More layouts: these keep their text, or fall back to a full rewrite with the same content
        let middle = #"{"mcpServers": {"a": 1, "mac-control": {"command": "\#(control.command)"}, "b": 2}}"#
        check("removing the middle of three keeps the others", String(data: try! ClientConfig.removeFromClaudeDesktop(Data(middle.utf8)), encoding: .utf8)! == #"{"mcpServers": {"a": 1, "b": 2}}"#)
        let tabbed = "{\n\t\"mcpServers\": {\n\t\t\"other\": 1\n\t}\n}\n"
        let tabbedMerged = String(data: try! ClientConfig.mergeClaudeDesktop(Data(tabbed.utf8), servers: [control]), encoding: .utf8)!
        check("a tab-indented file gets tab-indented members", tabbedMerged.hasPrefix("{\n\t\"mcpServers\": {\n\t\t\"other\": 1,\n\t\t\"mac-control\": {\n\t\t\t\"args\": []"), tabbedMerged)
        let replacedEntry = String(data: try! ClientConfig.mergeClaudeDesktop(Data(#"{"mcpServers": {"mac-control": {"command": "/old"}, "z": 1}}"#.utf8), servers: [control]), encoding: .utf8)!
        check("an old entry is replaced where it was", replacedEntry.hasPrefix(#"{"mcpServers": {"mac-control": {"#) && replacedEntry.hasSuffix(#"}, "z": 1}}"#), replacedEntry)
        for (name, text) in [("CRLF line endings", "{\r\n  \"mcpServers\": {\r\n    \"other\": 1\r\n  }\r\n}\r\n"),
                             ("a byte order mark", "\u{FEFF}{\"mcpServers\": {\"other\": 1}}"),
                             ("escaped and non-ASCII keys", #"{"caf\u00e9": "\"x\"", "名稱": 1, "mcpServers": {"other": 1}}"#)] {
            guard let result = try? ClientConfig.mergeClaudeDesktop(Data(text.utf8), servers: [control]) else {
                check("a file with \(name) can be merged", false); continue
            }
            let content = String(data: result, encoding: .utf8)!
            check("a file with \(name) gets the expected content", ClientConfig.claudeDesktopMatches(result, servers: [control]), content)
            check("a file with \(name) keeps its other server", (json(result)["mcpServers"] as? [String: Any])?["other"] != nil, content)
            check("a file with \(name) does not get mixed line endings", !content.contains("\r") || !content.replacingOccurrences(of: "\r\n", with: "").contains("\n"), content)
        }

        // `mcp get` output
        let claudeGet = """
        mac-control:
          Scope: User config (available in all your projects)
          Status: ✔ Connected
          Type: stdio
          Command: /Users/me/My Apps/MacControl.app/Contents/Helpers/MacControlHelper.app/Contents/MacOS/mac-control-mcp
          Args:

        To remove this server, run: claude mcp remove "mac-control" -s user
        """
        check("claude's output with a path containing a space is this app's", ClientConfig.describesAppCommand(claudeGet))
        let codexGet = """
        mac_exec
          enabled: true
          transport: stdio
          command: /Applications/MacControl.app/Contents/Helpers/mac-exec-mcp
          args: -
          env: MAC_EXEC_WORKSPACE=*****
        """
        check("codex's output is this app's", ClientConfig.describesAppCommand(codexGet))
        let developmentGet = """
        mac_control
          command: /bin/sh
          args: /Users/me/Apps/MacControl.app/Contents/Helpers/mac-control-mcp
        """
        check("a command that only names the helper in its arguments is not this app's", !ClientConfig.describesAppCommand(developmentGet))
        check("output without a command line falls back to its words", ClientConfig.describesAppCommand("mac-exec \"\(exec.command)\""))

        // Claude Code's saved entry
        func saved(_ text: String) -> ClientConfig.SavedEntry { ClientConfig.claudeCodeEntry(Data(text.utf8), name: "mac-exec") }
        check("no entry, nothing to restore", saved(#"{"mcpServers": {}}"#) == .none && ClientConfig.claudeCodeEntry(nil, name: "mac-exec") == .none)
        check("an entry with this app's settings can be restored",
              saved(#"{"mcpServers": {"mac-exec": {"type": "stdio", "command": "/x/mac-exec-mcp", "env": {"MAC_EXEC_WORKSPACE": "/w"}}}}"#)
                == .restorable(#"{"command":"/x/mac-exec-mcp","env":{"MAC_EXEC_WORKSPACE":"/w"},"type":"stdio"}"#))
        check("an entry with other variables is not restored on a command line",
              saved(#"{"mcpServers": {"mac-exec": {"command": "/x", "env": {"API_TOKEN": "secret"}}}}"#) == .notRestorable)
        check("an entry with headers is not restored on a command line",
              saved(#"{"mcpServers": {"mac-exec": {"type": "http", "url": "https://x", "headers": {"Authorization": "Bearer x"}}}}"#) == .notRestorable)

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
        for choice in [RuntimeChoice.appleContainer, .managedColima, .existingDocker("/usr/local/bin/docker")] {
            check("a remembered \(choice.stored) reads back", RuntimeChoice(stored: choice.stored) == choice)
        }
        for stored in ["", "existingDocker:", "docker", "AppleContainer"] {
            check("\"\(stored)\" is not a remembered runtime", RuntimeChoice(stored: stored) == nil)
        }
        check("a remembered Docker that is gone is not kept", !RuntimeChoice.existingDocker("/nonexistent/docker").programExists)
        check("a remembered Docker that exists is kept", RuntimeChoice.existingDocker("/bin/sh").programExists)
        check("Intel without Docker installs Colima", RuntimeSelection.choose(cpu: .intel, macOSMajor: 26, workingDocker: nil) == .managedColima)

        // Version comparison for the update check
        check("newer patch", AppVersion.isNewer("v0.3.4", than: "0.3.3"))
        check("same version is not newer", !AppVersion.isNewer("v0.3.3", than: "0.3.3"))
        check("older is not newer", !AppVersion.isNewer("v0.3.2", than: "0.3.3"))
        check("numeric, not text, order", AppVersion.isNewer("0.3.10", than: "0.3.9"))
        check("missing parts count as zero", !AppVersion.isNewer("0.4", than: "0.4.0") && AppVersion.isNewer("0.4.1", than: "0.4"))
        check("suffix ignored", !AppVersion.isNewer("v0.3.3-beta", than: "0.3.3"))

        // Privacy pane name
        check("Accessibility keeps its name on macOS 26", !PrivacyPane.accessibilityRenamed(macOSMajor: 26))
        check("Accessibility is renamed on macOS 27", PrivacyPane.accessibilityRenamed(macOSMajor: 27))

        // Servers left running from before an update
        check("Claude Desktop through disclaimer", OldServers.clientName(ancestors: [
            "/Applications/Claude.app/Contents/Helpers/disclaimer", "/Applications/Claude.app/Contents/MacOS/Claude"]) == "Claude Desktop")
        check("Codex app", OldServers.clientName(ancestors: [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"]) == "Codex app")
        check("Claude Code from Homebrew", OldServers.clientName(ancestors: [
            "/usr/local/Caskroom/claude-code/2.1.308/claude", "/bin/zsh", "/Applications/iTerm.app/Contents/MacOS/iTerm2"]) == "Claude Code")
        check("Claude Code from the native installer", OldServers.clientName(ancestors: [
            "/Users/me/.local/share/claude/versions/2.1.308", "/bin/zsh"]) == "Claude Code")
        check("Codex CLI", OldServers.clientName(ancestors: ["/opt/homebrew/bin/codex", "/bin/zsh"]) == "Codex")
        check("ChatGPT without Codex", OldServers.clientName(ancestors: ["/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"]) == "ChatGPT")
        check("unknown client", OldServers.clientName(ancestors: ["/bin/zsh", "/usr/bin/login"]) == nil)

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
