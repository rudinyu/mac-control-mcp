# Installation

English | [繁體中文](INSTALL.zh-TW.md)

This guide sets up mac-control-mcp on your Mac and connects it to Claude Code, Claude Desktop, or Codex. When you are done, see the [usage guide](USAGE.md).

## 1. Requirements

- macOS, signed in to a desktop session. The server cannot see a display over SSH or in a headless session.
- Xcode Command Line Tools, which provide Swift: `xcode-select --install`
- Python 3, for the tests. The `/usr/bin/python3` that ships with macOS is enough.
- At least one MCP client: [Claude Code](https://claude.com/claude-code), Claude Desktop, or Codex.

## 2. Get the code and build it

```sh
git clone https://github.com/rudinyu/mac-control-mcp.git
cd mac-control-mcp
sh scripts/ci.sh
```

`scripts/ci.sh` builds the server into `.build/mac-control-mcp` and runs every test. None of the tests click, type, or record, so they are safe to run at any time. A run that ends in `OK` means the build works.

You do not need to rebuild by hand later. Clients start the server through `scripts/run-server.sh`, which rebuilds it whenever the binary is missing or a source file has changed.

## 3. Create the client configuration

```sh
sh scripts/init-agents.sh
```

This writes the following files into the project root, using the absolute path of your clone. Existing files are kept; pass `--force` to replace them.

| File | Client | Purpose |
| --- | --- | --- |
| `.mcp.json` | Claude Code | Starts the server for this project (required) |
| `CLAUDE.md` | Claude Code | Tells Claude to use mac-control and how (optional) |
| `.codex/config.toml` | Codex | Starts the server for this project (required) |
| `AGENTS.md` | Codex | Tells Codex to use mac-control and how (optional) |

These files contain a machine-specific path, so they are listed in `.gitignore` and never committed. The templates they come from are in [`examples/`](../examples/), if you prefer to copy them by hand.

The script also prints a Claude Desktop entry. Claude Desktop's configuration holds your other servers too, so the script never edits it. Section 4 shows how to add the entry.

To also run commands and work with files in a sandbox, set up mac-exec as described in [mac-exec: sandboxed commands and files](EXEC.md#setup). It needs Docker.

## 4. Connect a client

### Claude Code

1. Start a new Claude Code session in the project directory: `claude`
2. Claude Code asks whether to trust the project's MCP server the first time. Approve `mac-control`.
3. Run `/mcp` and check that `mac-control` shows as connected.

To use mac-control from every project instead of only this one, register it at user scope. Run this from the clone's root directory, because it uses `$PWD`:

```sh
claude mcp add --scope user --transport stdio mac-control -- /bin/sh "$PWD/scripts/run-server.sh"
```

Do not keep a project entry and a user entry with the same name.

### Claude Desktop

1. Open `~/Library/Application Support/Claude/claude_desktop_config.json`. Create it with `{"mcpServers": {}}` if it does not exist.
2. Add the `mac-control` entry printed by `init-agents.sh` inside `mcpServers`, next to any servers already there:

   ```json
   "mac-control": {
     "command": "/bin/sh",
     "args": ["/absolute/path/to/mac-control-mcp/scripts/run-server.sh"]
   }
   ```

3. Quit Claude Desktop completely with ⌘Q, then open it again.

Claude Desktop does not read `CLAUDE.md`. To give it the same instructions, paste the contents of [`examples/CLAUDE.md`](../examples/CLAUDE.md) into a project's instructions.

### Codex

1. Start Codex in the project directory and trust the project when asked. Codex reads `.codex/config.toml` only for trusted projects.
2. Check that `mac_control` appears in Codex's MCP server list.

To use it from every project instead, run this from the clone's root directory:

```sh
codex mcp add mac_control -- /bin/sh "$PWD/scripts/run-server.sh"
```

Codex names the server `mac_control`, with an underscore. Claude clients name it `mac-control`.

## 5. Grant macOS permissions

macOS grants permissions to the app that starts the server, not to the server itself:

| You use | Grant permission to |
| --- | --- |
| Claude Code or Codex in a terminal | That terminal app, such as Terminal or iTerm2 |
| Claude Desktop | Claude |
| Codex desktop app | Codex |

In **System Settings > Privacy & Security**, turn the app on under both:

- **Accessibility**: needed for the mouse, keyboard, text input, and UI tree tools.
- **Screen & System Audio Recording**: needed for screenshots and screen recording.

Then quit and reopen that app. macOS applies these permissions only to newly started processes.

## 6. Check that it works

Ask the agent:

> Call mac_status.

The result should include `"accessibility": true` and `"screen_recording": true`. If either is `false`, recheck section 5, and make sure you restarted the app that you granted. You can also ask the agent to call `mac_request_screen_recording`, which shows the macOS Screen Recording prompt.

Then try a screenshot:

> Use mac-control to take a screenshot and describe what is on my screen.

## 7. Optional: run the checks before every commit

If you plan to change the code, enable the project's Git hook once:

```sh
git config core.hooksPath .githooks
```

The hook runs `scripts/ci.sh` before each commit. If `codex-precommit-check` and the `claude` CLI are installed, it also runs a Claude code review. Without them, the review is skipped. Set `CODEX_SKIP_REVIEW=1` to skip the review for one commit.

## Update

```sh
git pull
```

The next time a client starts the server, `run-server.sh` rebuilds it. Restart the client, or reconnect the server with `/mcp` in Claude Code, to pick up the new version. If the examples changed, rerun `sh scripts/init-agents.sh --force`. This replaces all four generated files, including any edits you made to `CLAUDE.md` and `AGENTS.md`, so compare them with `examples/` and copy your edits first.

## Uninstall

1. Remove the client entries:
   - **Claude Code**: delete `.mcp.json`, or run `claude mcp remove --scope user mac-control` if you added it at user scope.
   - **Claude Desktop**: delete the `mac-control` entry from `claude_desktop_config.json` and restart Claude.
   - **Codex**: delete `.codex/config.toml`, or run `codex mcp remove mac_control`.
2. Optionally turn off the permissions from section 5.
3. Delete the clone. Recordings are stored inside it, in `.build/recordings/`, so they are deleted too.
