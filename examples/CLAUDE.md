# Mac desktop control in this project

For Mac desktop tasks, use the project `mac-control` MCP server instead of built-in computer-use. Call `mac_status` first. Call `mac_screenshot` before `mac_mouse`; mouse coordinates refer to the most recent screenshot. Use `mac_type_text` and `mac_key` for keyboard input, and pass `app` (for example `"app": "TextEdit"`) so input cannot land in the terminal running the agent. Use `mac_record_start`, `mac_record_status`, and `mac_record_stop` for video recording.

If macOS reports missing permission, ask the user to grant it in System Settings. Do not attempt to bypass macOS permissions. Ask the user before destructive or irreversible actions.

For running commands, installing packages, and working with files, use the `mac-exec` MCP server. Run commands with `sandbox_exec`, which runs them in an isolated Linux container, and keep files in the workspace (`/workspace`). Use `host_exec`, when it is available, only when the task cannot be done in the sandbox, for example to run a macOS program, and explain why in `reason`.
