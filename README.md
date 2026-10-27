# mac-control-mcp

English | [繁體中文](README.zh-TW.md)

An MCP server that runs on your own Mac and lets a local Claude Code or Codex session use macOS screenshots, Accessibility, keyboard, mouse, and screen recording. It talks to the MCP host only over standard input and output. It opens no network port and does not offer arbitrary shell commands.

## Tools

| Tool | What it does |
| --- | --- |
| `mac_status` | Reports the display, the frontmost app, and permission status |
| `mac_request_screen_recording` | Triggers the macOS Screen Recording permission prompt |
| `mac_screenshot` | Captures the main display and returns a JPEG to the model |
| `mac_ui_tree` | Reads Accessibility elements of the frontmost app, or of the app named by `app`, with password field values hidden |
| `mac_mouse` | Moves, clicks, double-clicks, right-clicks, and drags |
| `mac_scroll` | Scrolls vertically or horizontally |
| `mac_type_text` | Types Unicode text by placing it on the clipboard and pressing Command-V, then restores the clipboard |
| `mac_key` | Presses Enter, arrow keys, letter keys, and combinations with Command and other modifiers |
| `mac_record_start` / `mac_record_status` / `mac_record_stop` | Records the main display to a local MOV file, up to 120 seconds at a time |

Mouse coordinates are **pixel coordinates in the most recent `mac_screenshot` image**. Take a new screenshot after the screen resolution changes. Recordings are saved in `.build/recordings/`, which is not tracked by Git, and the recording tools return the file path for local viewing or further processing. Recordings do not capture the microphone or system audio.

`mac_type_text`, `mac_key`, and `mac_ui_tree` accept an `app` parameter: the name or bundle ID of a running app with a Dock icon, such as `TextEdit` or `com.apple.TextEdit`. If a name matches several apps, the one in front is chosen; if none of them is in front, the tool reports an error that lists the candidates, and you should use a bundle ID instead. The input tools bring the app to the front first and check again just before sending. If another app has taken focus by then, no input is sent and the tool reports an error. With `app`, `mac_ui_tree` only reads and does not change which app is in front. When the agent runs in a terminal, focus often returns to the terminal between tool calls, so always pass `app` when sending input.

Terminals such as iTerm2 use NUL in Accessibility text both to pad wide characters and to mark blank cells. Padding after a wide character is removed, other NULs become spaces, and blanks at the end of each line are trimmed.

`mac_type_text` uses the system clipboard briefly and then restores what was there. If another program changes the clipboard during the paste, that change is not overwritten. Clipboard contents larger than 40 MB, or contents that cannot be fully preserved, cancel the input. Pasting works better than sending Unicode key events with input methods such as Zhuyin and with app text fields.

## Build and test

Requires macOS with the Xcode Command Line Tools, Swift, and Python 3.

```sh
sh scripts/ci.sh
```

This builds `.build/mac-control-mcp` and `.build/terminal-text-tests`, runs the terminal text unit tests, and runs MCP protocol tests that do not control the desktop. GitHub Actions runs the same script.

## Connect Claude Code and Codex

Claude Code's `.mcp.json` and Codex's `.codex/config.toml` contain local absolute paths, so they are not in the repository (they are listed in `.gitignore`). After cloning, create them in the project root and replace the path with the absolute path of your clone. Both start `scripts/run-server.sh`, which rebuilds the server when the binary is missing or a source file has changed.

`.mcp.json`:

```json
{
  "mcpServers": {
    "mac-control": {
      "type": "stdio",
      "command": "/bin/sh",
      "args": ["/path/to/mac-control-mcp/scripts/run-server.sh"]
    }
  }
}
```

`.codex/config.toml`:

```toml
[mcp_servers.mac_control]
command = "/bin/sh"
args = ["/path/to/mac-control-mcp/scripts/run-server.sh"]
default_tools_approval_mode = "prompt"
startup_timeout_sec = 30
tool_timeout_sec = 30
```

To have an agent use mac-control by default, you can also create a local `CLAUDE.md` or `AGENTS.md` with instructions. These files are not tracked either.

1. Start a **new local** Claude Code or Codex session in the project directory.
2. The first time Claude Code loads the project MCP server, review and approve it in Claude Code. Codex loads `.codex/config.toml` only after you trust the project.
3. Check that `mac-control` / `mac_control` is connected in the agent's MCP list, then call `mac_status` first.
4. Describe the task to the agent, for example: "Use mac-control to read the current screen, open Finder, then record a 10-second video of it."

This configuration applies only to this project. To use the server in every project, add the same local stdio command to your user-level MCP configuration, and do not keep a duplicate entry with the same name.

To use it in other projects, run these commands yourself, replacing the path with the location of your clone. They change each tool's user-level configuration; the project files are not changed for you:

```sh
codex mcp add mac_control -- /bin/sh /path/to/mac-control-mcp/scripts/run-server.sh
claude mcp add --scope user --transport stdio mac-control -- /bin/sh /path/to/mac-control-mcp/scripts/run-server.sh
```

The project build never runs the Claude CLI; the second command is only there if you want it.

## macOS permissions

`mac_status` shows `screen_recording` and `accessibility`. If Screen Recording is not granted, call `mac_request_screen_recording` and allow it in the macOS prompt or in System Settings > Privacy & Security > Screen & System Audio Recording. Keyboard, mouse, and Accessibility elements need System Settings > Privacy & Security > Accessibility. macOS may require restarting Claude Code, Codex, or their host app before the permission takes effect.

The server must run in a **logged-in Mac desktop session**. CI and some sandboxes have no graphical display, so the tests check only the MCP protocol and input validation and never click or record. Screenshots and recordings hand screen contents to the agent, so close private windows you do not want to share first.

## Usage

Call `mac_status` first, then `mac_screenshot`. To click, call `mac_mouse` with pixel positions from the screenshot. Type text with `mac_type_text` and press shortcuts with `mac_key`, for example `{"key":"c","modifiers":["cmd"]}`.

Recording example: call `mac_record_start` with `{"duration_seconds":10}` and keep the returned `recording_id`, then check it with `mac_record_status`. When the state is `ready`, it returns the absolute path of the MOV file. Call `mac_record_stop` to stop early. If macOS has not granted permission, the recording tools report the missing permission.
