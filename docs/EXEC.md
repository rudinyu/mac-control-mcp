# mac-exec: sandboxed commands and files

English | [繁體中文](EXEC.zh-TW.md)

`mac-exec` is a second MCP server in this repository. It lets an agent run commands, install packages, and read and write files. By default everything runs in an isolated Linux container, so a mistaken or malicious command cannot touch the rest of your Mac. It is separate from `mac-control`, so clients ask you to approve it separately, and you can use either one without the other.

## How it protects your Mac

| Protection | What it means |
| --- | --- |
| Fresh container per command | Each `sandbox_exec` starts a new container and deletes it afterwards. Nothing carries over except files in the workspace. |
| Only the workspace is shared | The workspace folder, `~/AgentWorkspace` by default, is the only Mac folder the container can write to. It appears at `/workspace`. Your home folder, SSH keys, keychains, and browser data are not visible. |
| Sensitive folders are refused | The workspace and any read-only folders may not be, contain, or sit inside `~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.config`, `~/Library`, shell startup files such as `~/.zshrc`, agent settings such as `~/.claude` and `~/.codex`, and similar locations, or overlap this project, whose scripts run on the Mac. Sharing your whole home folder is refused for the same reason. |
| No root, no privileges | Commands run as the user `agent` (uid 1000) with every Linux capability dropped and `no-new-privileges`, so they cannot become root. |
| Read-only system | The container's system files are read-only. Only `/workspace`, `/tmp`, and the home folder `/home/agent` are writable, and the last two are erased when the command ends. |
| Resource limits | 2 GB of memory, 2 CPUs, and 256 processes per command, and a timeout of 120 seconds by default, up to 600. A command that runs too long is killed with its container, and `host_exec` kills every process in the command's process group. |
| Audit log | Every command is written to `~/Library/Logs/mac-exec/audit.log` before it runs, with its result afterwards. Each entry names the client that sent it, such as `claude-ai` or `codex`, as the client reports itself. If the log cannot be written, the command does not run. |
| Approval prompts | Command and write tools are marked as destructive. Whether the client asks you before each call depends on its permission settings: keep Claude Code's prompts on, and keep `default_tools_approval_mode = "prompt"` in Codex. `sandbox_write_file` can overwrite files in the workspace. |
| Running on the Mac is off by default | `host_exec`, which runs a command directly on the Mac, exists only when you turn it on. Each call must give a reason, and `sudo`, `su`, and `doas` are refused. |

The container has normal internet access, so it can download packages and call web APIs. It can also reach your Mac and your local network through Docker's network, for example `host.docker.internal` or your router. If that matters to you, do not run services on your Mac or network that trust connections without a password.

## Setup

1. Install and start [Docker Desktop](https://www.docker.com/products/docker-desktop/), or another Docker-compatible runtime that provides the `docker` command, such as [Colima](https://github.com/abiosoft/colima) or OrbStack. With Colima (`brew install colima docker`, then `colima start`), keep the workspace and any read-only folders inside your home folder: Colima shares the home folder with its VM by default, but not other locations such as the system temporary folder. To share another folder, add it with `colima start --mount <folder>:w`.
2. Build the sandbox image once:

   ```sh
   sh scripts/build-sandbox.sh
   ```

   Run it again after `sandbox/Dockerfile` changes. The image is based on Debian and includes bash, Python 3, Node.js, git, curl, and jq. Install Python packages with `pip install --user`, or in a virtual environment under `/workspace`; both last only as long as their location does.
3. Run `sh scripts/init-agents.sh`. The generated `.mcp.json`, `.codex/config.toml`, and Claude Desktop entry include `mac-exec` next to `mac-control`. If you created those files before, merge the `mac-exec` entry from [`examples/`](../examples/) by hand, or rerun with `--force`.
4. Restart the client and ask it to call `exec_status`. It should report `"docker_running": true` and `"image_present": true`.

## Settings

Set these in the `env` section of the server's entry in your client configuration.

| Variable | Default | Meaning |
| --- | --- | --- |
| `MAC_EXEC_WORKSPACE` | `~/AgentWorkspace` | The folder shared read-write at `/workspace`. It is created if it does not exist. |
| `MAC_EXEC_READONLY_DIRS` | none | Extra folders to share read-only, separated by `:`. Each appears at `/mnt/readonly/<folder name>`. A folder may not be inside the workspace, and each one is checked again before every command. |
| `MAC_EXEC_ALLOW_HOST` | off | Set to `1` to make `host_exec` available. |
| `MAC_EXEC_IMAGE` | `mac-exec-sandbox:latest` | The Docker image to run. |
| `MAC_EXEC_DOCKER` | found automatically | Path of the `docker` program, if it is not in a usual place. |
| `MAC_EXEC_AUDIT_LOG` | `~/Library/Logs/mac-exec/audit.log` | Where commands are logged. It may not be inside the workspace, and it is never written through a link. |

Example `.mcp.json` entry that shares a project folder read-only and allows `host_exec`:

```json
"mac-exec": {
  "type": "stdio",
  "command": "/bin/sh",
  "args": ["/path/to/mac-control-mcp/scripts/run-exec-server.sh"],
  "env": {
    "MAC_EXEC_WORKSPACE": "~/AgentWorkspace",
    "MAC_EXEC_READONLY_DIRS": "~/Documents/reports",
    "MAC_EXEC_ALLOW_HOST": "1"
  }
}
```

## Tools

| Tool | Parameters | What it does |
| --- | --- | --- |
| `exec_status` | none | Reports Docker, the image, the workspace, read-only folders, whether `host_exec` is on, and any setting problems. |
| `sandbox_exec` | `command` (required), `cwd`, `timeout_seconds` (1–600, default 120) | Runs `bash -c command` in a new container. `cwd` is relative to the workspace. Returns `exit_code`, `stdout`, `stderr` (each cut to 100 KB), `timed_out`, and `duration_ms`. |
| `sandbox_read_file` | `path` (required), `max_bytes` (up to 1 MB, default 200 KB) | Reads a UTF-8 text file from the workspace. |
| `sandbox_write_file` | `path`, `content` (required), `append` | Creates or replaces a text file in the workspace, up to 1 MB, creating folders as needed. |
| `sandbox_list` | `path` | Lists a workspace folder, up to 500 entries. |
| `host_exec` | `command`, `reason` (required), `cwd`, `timeout_seconds` | Only when `MAC_EXEC_ALLOW_HOST=1`. Runs `zsh -lc command` on the Mac with your permissions. |

Paths for the file tools may be relative, such as `notes/a.txt`, or start with `/workspace/`. Anything that resolves outside the workspace, including through a symbolic link, is refused.

Example requests:

> Use mac-exec to download the CSV from this URL into the workspace and summarize it with Python.

> In the sandbox, clone this repository into /workspace and run its tests.

## When to use host_exec

The sandbox is Linux. It cannot run macOS programs such as `open`, `osascript`, `defaults`, or Xcode tools, and it cannot see files outside the workspace. For those tasks, either share a folder read-only, or turn on `host_exec`.

`host_exec` runs with all of your permissions. The `sudo` check is a convenience, not a security boundary: what protects you is reading each command in the approval prompt before allowing it. Keep `MAC_EXEC_ALLOW_HOST` off unless you need it, and do not approve `host_exec` calls you did not expect, especially after the agent has read web pages or documents from someone else.

## Troubleshooting

| Message | What to do |
| --- | --- |
| `Docker was not found` | Install Docker Desktop, or set `MAC_EXEC_DOCKER`. |
| `exec_status` shows `docker_running: false` | Start Docker Desktop and wait until it is ready. |
| `The sandbox image … is missing` | Run `sh scripts/build-sandbox.sh`. |
| `sandbox_exec` fails with a mount or `invalid mount config` error | The Docker VM cannot see the workspace. With Colima, keep it inside your home folder or add it with `colima start --mount`. |
| `MAC_EXEC_WORKSPACE cannot be used` | The workspace is, contains, or sits inside a sensitive folder. Choose another folder. |
| `… must stay inside the workspace` | The path points outside the workspace. Use a relative path or one under `/workspace/`. |
| `Could not write the audit log` | Check that `~/Library/Logs/mac-exec` is writable, or set `MAC_EXEC_AUDIT_LOG`. |
| Codex stops long commands at 30 seconds | Raise `tool_timeout_sec` for `mac_exec`; the example uses 620. |
