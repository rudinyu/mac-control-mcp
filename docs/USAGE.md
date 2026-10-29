# Usage

English | [繁體中文](USAGE.zh-TW.md)

This guide explains how an agent controls your Mac with mac-control-mcp, with every tool and its parameters. Set the server up first with the [installation guide](INSTALL.md).

You normally do not call these tools yourself. You describe a task, and the agent picks the tools. Knowing how they work helps you write better requests and understand errors.

## The basic loop

1. **`mac_status`**: checks permissions and reports the frontmost app.
2. **`mac_screenshot`**: shows the agent the screen.
3. **Act**: click with `mac_mouse`, type with `mac_type_text` or `mac_key`, or read controls with `mac_ui_tree`.
4. **`mac_screenshot` again**: confirms the result before the next step.

Example requests:

> Open TextEdit, create a new document, and type "Meeting notes".

> Take a screenshot and tell me which apps are open.

> Record a 15-second video of my screen while you open Finder and go to Downloads.

## Two rules that prevent most mistakes

**Mouse coordinates come from the latest screenshot.** `mac_mouse` uses pixel positions in the most recent `mac_screenshot` image. On a Retina display the image usually has twice the pixels of the screen size that `mac_status` reports, for example 3840 × 2160 for a 1920 × 1080 display, and the server converts for you. Always go by the size the screenshot reports. Take a new screenshot after anything moves, and after the resolution changes.

**Always name the target app.** When the agent runs in a terminal or in Claude Desktop, focus often returns to that window between two tool calls. Input sent without a target then lands in the agent's own window, or in whatever app came to the front. Pass `app` to `mac_screenshot`, `mac_mouse`, `mac_scroll`, `mac_type_text`, and `mac_key`. The server brings that app to the front, checks again just before sending, and sends nothing if another app has taken focus. For `mac_mouse`, it also refuses to click when the last screenshot was not taken with that app in front, when its window has moved or resized since, or when the point is over another app, such as a window on top, the Dock, or a menu bar icon. `mac_scroll` refuses when the pointer is over another app. Some panels, such as Open and Save in sandboxed apps, run in a separate process; to click in one, leave out `app` for that click. Add a line like this to your request:

> Use `"app": "TextEdit"` with every mac-control tool.

## Tool reference

### `mac_status`

Reports Accessibility and Screen Recording permission, whether the screen is locked (`screen_locked` and `screen_locked_reason`), the frontmost app, the display size, the cursor position, and the size of the last screenshot. It takes no parameters and changes nothing. Call it first in every session.

### `mac_screenshot`

Captures the main display as a JPEG. The image size sets the coordinate space for `mac_mouse` until the next screenshot. It needs Screen Recording permission.

| Parameter | Type | Notes |
| --- | --- | --- |
| `app` | string | App to bring to the front before capturing, as for `mac_type_text`. Also brings its window back from the Stage Manager strip; an app with no open window may open a new one. Needs Accessibility permission. |

### `mac_request_screen_recording`

Shows the macOS Screen Recording permission prompt. Use it once if `mac_status` reports `"screen_recording": false`, then grant the permission and restart the host app.

### `mac_mouse`

| Parameter | Type | Notes |
| --- | --- | --- |
| `action` | string, required | `move`, `click`, `double_click`, `right_click`, or `drag` |
| `x`, `y` | number, required | Pixel position in the latest screenshot |
| `to_x`, `to_y` | number | End position, required for `drag` |
| `app` | string | App the click is meant for. Take the screenshot with the same `app` first. |

```json
{"action": "click", "x": 1039, "y": 2097}
{"action": "drag", "x": 400, "y": 300, "to_x": 900, "to_y": 300}
```

Coordinates outside the last screenshot are rejected. Calling `mac_mouse` before any screenshot is an error.

### `mac_scroll`

| Parameter | Type | Notes |
| --- | --- | --- |
| `vertical` | integer, -20 to 20 | Lines to scroll; positive scrolls up |
| `horizontal` | integer, -20 to 20 | Lines to scroll; positive scrolls left |
| `app` | string | App to bring to the front first, as for `mac_type_text` |

It scrolls wherever the pointer is, so move the pointer over the target with `mac_mouse` first. At least one value must be nonzero.

```json
{"vertical": -5}
```

### `mac_type_text`

| Parameter | Type | Notes |
| --- | --- | --- |
| `text` | string, required | 1 to 2000 characters; any Unicode, including Chinese and emoji |
| `app` | string | Name or bundle ID of a running app to type into, such as `TextEdit` or `com.apple.TextEdit` |

```json
{"text": "測試中文 abc", "app": "TextEdit"}
```

The text is pasted: the server puts it on the clipboard, presses Command-V, and then restores your previous clipboard. Pasting works with input methods such as Zhuyin, where simulated key presses would not. If another app changes the clipboard during the paste, the server leaves that change alone. A clipboard over 40 MB, or one that cannot be saved exactly, cancels the input instead of losing your data.

The result names the app that received the text, for example `Inserted 8 characters into TextEdit via Command-V.`

### `mac_key`

| Parameter | Type | Notes |
| --- | --- | --- |
| `key` | string, required | `a`–`z`, `0`–`9`, `enter`/`return`, `tab`, `space`, `backspace`, `delete`, `escape`, `home`, `end`, `pageup`, `pagedown`, `left`, `right`, `up`, `down` |
| `modifiers` | array | Any of `cmd`, `shift`, `alt`, `ctrl` |
| `app` | string | Same as for `mac_type_text` |

```json
{"key": "n", "modifiers": ["cmd"], "app": "TextEdit"}
{"key": "enter"}
```

Function keys, punctuation keys, and media keys are not supported. To type punctuation, use `mac_type_text`.

### `mac_ui_tree`

| Parameter | Type | Notes |
| --- | --- | --- |
| `max_depth` | integer, 0 to 8 | How deep to read; default 5 |
| `app` | string | App to read; default is the frontmost app |

Returns the Accessibility tree of the app's focused window as JSON, with each element's role, title, description, and value, plus the element that has keyboard focus. Use it to find buttons and fields by name instead of by pixel position. It reads at most 200 elements, cuts each value to 200 characters, and reports `"truncated": true` when it hits a limit. Password field values are never included. With `app`, it reads that app without bringing it to the front.

```json
{"app": "TextEdit", "max_depth": 6}
```

### `mac_record_start`, `mac_record_status`, `mac_record_stop`

| Tool | Parameter | Notes |
| --- | --- | --- |
| `mac_record_start` | `duration_seconds`, integer, 1 to 120, required | Starts recording the main display and returns a `recording_id` |
| `mac_record_status` | `recording_id`, required | Reports `recording`, `ready`, or `failed`, with the file path once ready |
| `mac_record_stop` | `recording_id`, required | Stops early |

Only one recording runs at a time. Files are QuickTime MOV, saved in `.build/recordings/` inside the clone. Recordings have no audio. After `mac_record_stop`, the file may need a moment before `mac_record_status` reports `ready`.

## Troubleshooting

| Message or symptom | What to do |
| --- | --- |
| `Accessibility permission is missing` or `Screen Recording permission is missing` Grant the permission to the terminal app, or to MacControlHelper.app for Claude Desktop and the Codex app, then quit and reopen that app. See [installation, section 5](INSTALL.md#5-grant-macos-permissions). |
| `No running app with a Dock icon matches "…"` | Open the app first. Only apps with a Dock icon can be targeted, and names must match exactly, ignoring case. |
| `"…" matches N running apps` | Several apps share the name. Use the bundle ID shown in the message. |
| `… has focus instead of …; no input was sent` | Another app took focus right before sending. Nothing was typed. Ask the agent to try again. |
| `The screen is locked` | Input is refused while the Mac is locked or another user is on the display, because it would go to the login window. Unlock the Mac, then ask the agent to continue. Screenshots still work but show the lock screen. |
| `Could not determine which app has focus` | Accessibility could not report the focused app. Check the Accessibility permission. |
| `Call mac_screenshot before mac_mouse` or coordinates rejected | Take a screenshot first, and use coordinates from that image. |
| `… was not steadily in front for the last mac_screenshot`, `… window moved, resized, or changed`, or `… is not over …` | Nothing was clicked. Take a new screenshot with the same `app`, then click using its coordinates. |
| Clicks land in the wrong place | The screen changed after the screenshot. Take a new one, and pass `app` so the server can check. |
| Text or a click went to the agent's own window or another app | `app` was not passed. Always pass it. |
| The tools do not appear in the client | Restart the client, then check the server path in its configuration. In Claude Code, run `/mcp`. |

## Privacy and safety

- Screenshots, recordings, and UI tree values send what is on your screen to the agent's model. Close private windows first.
- `mac_type_text` briefly puts the text on the system clipboard, where clipboard history tools and Universal Clipboard on your other devices can capture it. Do not have the agent type passwords or other secrets.
- Recordings stay in `.build/recordings/` inside the clone until you delete them. Delete the ones you no longer need.
- The server only reads and acts on your desktop. It opens no network port, does not run arbitrary shell commands, and talks only to the client that started it.
- The agent can click and type anything you could. Keep your client's approval prompts on, and do not let it confirm purchases, deletions, or messages without checking.
