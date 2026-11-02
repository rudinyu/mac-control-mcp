# Usage

English | [繁體中文](USAGE.zh-TW.md)

This guide explains how an agent controls your Mac with mac-control-mcp, with every tool and its parameters. Set the server up first with the [installation guide](INSTALL.md).

You normally do not call these tools yourself. You describe a task, and the agent picks the tools. Knowing how they work helps you write better requests and understand errors.

## The basic loop

1. **`mac_status`**: checks permissions and reports the frontmost app.
2. **`mac_screenshot`**: shows the agent the screen.
3. **Act**: click with `mac_mouse`, type with `mac_type_text` or `mac_key`, or read controls with `mac_ui_tree` and act on one by its ref with `mac_ax_action`.
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
| `root` | string | A ref to read below, instead of the focused window |
| `app` | string | App to read; default is the frontmost app |

Returns the Accessibility tree of the app's focused window as JSON, with each element's role, title, description, and value, plus the element that has keyboard focus. Use it to find buttons and fields by name instead of by pixel position. It reads at most 200 elements for at most 5 seconds, and cuts each value to 200 characters. Password field values are never included. With `app`, it reads that app without bringing it to the front.

Each element that can be acted on also has a `ref`, such as `"ref": "k3f9q2.12"`, and `actions`, the `mac_ax_action` actions it offers. An element whose children are not all listed shows `more_children`, the number left out, and also has a `ref`. Pass that ref as `root` to read below it. That happens for two reasons: `max_depth`, which you chose, and the read stopping early.

The result says whether the read stopped early:

| Field | Meaning |
| --- | --- |
| `complete` | `true` when everything down to `max_depth` was read. Elements left out only because of `max_depth` do not make it `false`. |
| `truncated` | `true` when the read stopped early |
| `stopped_by` | Why it stopped: `element_limit` (200 elements), `time_limit` (5 seconds), or `app_not_answering`; `null` when it did not |
| `elements_read` | How many elements were read |
| `unanswered` | How many elements the app did not answer for within 2 seconds. Each is marked `"unanswered": true`. |

When an app stops answering, as a busy or hung app does, the read stops there instead of waiting on every remaining element. Elements already read are kept. After that point, elements no longer list `actions`, but an element with children left out still has a `ref`, so you can read below it once the app responds again. A ref is the snapshot ID, a dot, and the element's number in that snapshot; the result's `snapshot` field names the snapshot. Reading the whole tree again for the same app starts a new snapshot and retires all of that app's earlier refs. Reading below a `root`, `mac_find`, `mac_wait`, and `mac_window list` add refs to the current snapshot, so earlier refs keep working. Snapshot IDs are random, so a ref kept from before mac-control restarted is refused instead of naming another element. For a large window, read it with a small `max_depth` first, then drill in.

```json
{"app": "TextEdit", "max_depth": 6}
{"app": "Slack", "max_depth": 2}
{"app": "Slack", "root": "p8w2kd.7", "max_depth": 6}
```

### `mac_find`

| Parameter | Type | Notes |
| --- | --- | --- |
| `role` | string | Such as `button` or `AXTextField`; the `AX` prefix and case do not matter |
| `text` | string | Matched in the title, description, or value, ignoring case and accents |
| `exact` | boolean | Match the whole text instead of part of it |
| `limit` | integer, 1 to 50 | Most matches to return; default 20 |
| `root` | string | A ref to search below, instead of all of the app's windows |
| `app` | string | App to search; default is the frontmost app |

Give `role`, `text`, or both. Searches every window of the app, the focused one first, in screen-reader order, up to 5000 elements and 40 levels deep, for at most 5 seconds. That is much further than `mac_ui_tree` reads. Matches come back with their `ref` and `actions`, ready for `mac_ax_action`, and the app's existing refs keep working. The result's `snapshot` names the snapshot the refs belong to. `"complete": false` means the search was cut short; narrow it with `root`. Menus in the menu bar are not searched. Password field values are never matched or returned.

```json
{"app": "TextEdit", "role": "button", "text": "Save"}
```

### `mac_wait`

| Parameter | Type | Notes |
| --- | --- | --- |
| `role`, `text`, `exact`, `root`, `app` | | Same as for `mac_find` |
| `state` | `present` or `absent` | Wait for a match to appear (default) or for none to be left |
| `timeout_seconds` | number, 0.5 to 30 | How long to wait; default 10 |

Checks about four times a second, looking up the app's windows each time, so a dialog that opens in a new window is found. With `present`, returns the matches with refs as soon as one appears. With `absent`, it returns only once a full search finds nothing. If time runs out, it fails with `TIMEOUT`. Use it after an action, for example to wait for a sheet to open or for a progress indicator to go away, instead of reading `mac_ui_tree` repeatedly.

```json
{"app": "TextEdit", "role": "sheet", "timeout_seconds": 5}
{"app": "Safari", "role": "progressindicator", "state": "absent", "timeout_seconds": 20}
```

### `mac_window`

| Parameter | Type | Notes |
| --- | --- | --- |
| `action` | string, required | `list`, `focus`, `move`, `resize`, `minimize`, or `restore` |
| `window` | string | A window ref from `list`, `mac_find`, or `mac_ui_tree` |
| `x`, `y` | number | For `move`: the new top-left corner |
| `width`, `height` | number | For `resize` |
| `app` | string | For `list`, the app to list; otherwise, act on this app's focused window when `window` is left out |

`list` returns each window's app, title, `frame`, `minimized`, `main`, and `focused`, and a `ref`. Without `app` it lists the windows of every app with a Dock icon, up to 100. Frames are in screen points, the units of `main_display` in `mac_status`, not the pixels of `mac_screenshot`.

`focus` restores a minimized window, raises it, and brings its app to the front. `move` and `resize` return the window with `as_requested`, which is `false` when the app placed or sized it differently, for example to keep it on screen. A window whose size is fixed is refused with `ACTION_UNSUPPORTED`. `minimize` and `restore` send nothing when the window is already in that state. With Stage Manager on, macOS can ignore them; the tool then reports `OUTCOME_UNKNOWN`.

```json
{"action": "list", "app": "TextEdit"}
{"action": "move", "window": "m4c7tj.2", "x": 0, "y": 25}
{"action": "resize", "app": "TextEdit", "width": 900, "height": 700}
```

### `mac_ax_action`

| Parameter | Type | Notes |
| --- | --- | --- |
| `ref` | string, required | A ref from `mac_ui_tree`, `mac_find`, or `mac_wait`, still current for the app |
| `action` | string, required | `press`, `show_menu`, `increment`, `decrement`, `confirm`, `cancel`, `raise`, `scroll_to_visible`, `set_value`, `focus`, `select`, `deselect`, `expand`, `collapse`, `check`, or `uncheck` |
| `value` | string, up to 2000 characters | The text for `set_value`; not allowed with other actions |
| `app` | string | If given, must be the ref's app |

Acts on the element through Accessibility, so it works without coordinates, does not move the pointer, does not bring the app to the front, and does not use the clipboard. Before sending, it checks that the app has not quit or relaunched, that the element still exists with the same role, and that it still offers the action. Password fields cannot be set. `select` and `deselect` set whether a row or item is selected; `expand` and `collapse` open or close an outline row or disclosure; `check` and `uncheck` press a checkbox only when it is not already in that state. These four pairs send nothing when the element is already in the asked-for state. `scroll_to_visible` scrolls the element into view; it is mostly offered by web content. `set_value` sends a number to an element that holds one, such as a slider or stepper, and refuses anything other than a finite decimal number there.

After sending, the element is read back where there is something to read:

| Action | Read back | When it does not match |
| --- | --- | --- |
| `select`, `deselect`, `expand`, `collapse`, `check`, `uncheck` | The state attribute, such as `AXSelected` | `OUTCOME_UNKNOWN` |
| `focus` | `AXFocused` | `OUTCOME_UNKNOWN` when it reads false; not verified when the element does not report focus, as some web elements do not |
| `set_value` with text | `AXValue` shows the new text | `OUTCOME_UNKNOWN`; many web fields need `mac_type_text` instead |
| `set_value` with a number | `AXValue` equals the number | Not verified, since a slider can round to its step |
| `increment`, `decrement` | `AXValue` went up or down | Not verified, since the element may be at its limit |
| `press`, `show_menu`, `confirm`, `cancel`, `raise`, `scroll_to_visible` | Nothing; these leave no state on the element | Never verified |

A successful result has two text parts, like an error: a message, and a JSON object that says what was checked. The value read back is never included, since it may be private:

```json
{"result": {"delivered": true, "verified": true, "checked": "AXSelected"}}
```

`delivered` is false when nothing was sent because the element was already in that state. `verified` is true only when the attribute named in `checked` was read back and matched. When it is false, read `mac_ui_tree` to see the result.

The result also lists what the action opened and closed, so after pressing a pop-up button or choosing `show_menu` you can pick a menu item at once:

```json
{"result": {"delivered": true, "verified": false, "checked": null,
  "opened": [{"kind": "menu", "role": "AXMenu", "ref": "aflg2p.5", "children": [
    {"role": "AXMenuItem", "title": "Apple", "ref": "aflg2p.2", "actions": ["cancel", "press", "select", "deselect"]}]}],
  "closed": []}}
```

| `kind` | What it is |
| --- | --- |
| `menu` | A pop-up or context menu, under the element that opened it or under the app |
| `sheet` | A sheet attached to a window |
| `dialog` | A window with the `AXDialog` or `AXSystemDialog` subrole, such as an alert |
| `popover` | A popover |
| `panel` | A floating window, such as a tool palette |
| `window` | Any other new window |

Each entry in `opened` has a `ref` and its direct children, up to 30 elements; read below the ref with `mac_ui_tree` `root` for more. Each entry in `closed` has `kind` and `title`. After `press`, `show_menu`, `confirm`, and `cancel`, changes are watched for about 0.3 seconds, and for about a second after an action on a menu item, since the item flashes before its menu closes.

Some apps answer an action that opens a modal dialog only once the dialog is up, so `mac_ax_action` reports `OUTCOME_UNKNOWN`. Its JSON part then lists the dialog under `opened`, which shows that the action happened.

Menus in the menu bar are not covered, since `mac_find` and `mac_ui_tree` give no refs for them. A submenu, which a menu item lists whether or not it is open, is not reported as opened.

```json
{"ref": "k3f9q2.12", "action": "press", "app": "Calculator"}
{"ref": "h5r1zb.4", "action": "set_value", "value": "Meeting notes", "app": "TextEdit"}
```

### `mac_record_start`, `mac_record_status`, `mac_record_stop`

| Tool | Parameter | Notes |
| --- | --- | --- |
| `mac_record_start` | `duration_seconds`, integer, 1 to 120, required | Starts recording the main display and returns a `recording_id` |
| `mac_record_status` | `recording_id`, required | Reports `recording`, `ready`, or `failed`, with the file path once ready |
| `mac_record_stop` | `recording_id`, required | Stops early |

Only one recording runs at a time. Files are QuickTime MOV, saved in `~/Movies/MacControl/` with MacControl.app, or in `.build/recordings/` inside the clone for a source build. Only your account can open the folder. Recordings have no audio. After `mac_record_stop`, the file may need a moment before `mac_record_status` reports `ready`.

## Error results

When a tool fails, the result has two text parts: a message for people, and a JSON object for the agent:

```json
{"error": {"code": "STALE_REF", "delivered": false, "retry": "refresh"}}
```

`delivered` is `false` when nothing reached the app, and `"unknown"` when an action was sent but not confirmed. `retry` says what to do next:

| `retry` | Meaning | Codes |
| --- | --- | --- |
| `fix` | Change the arguments, or what they name, such as launching the app | `INVALID_ARGS`, `APP_NOT_FOUND`, `APP_AMBIGUOUS`, `ACTION_UNSUPPORTED` |
| `refresh` | Take a new `mac_screenshot` or `mac_ui_tree`, and use its coordinates or refs | `STALE_SCREENSHOT`, `STALE_REF` |
| `safe` | The same call can be repeated | `FOCUS_LOST`, `APP_UNRESPONSIVE`, `BUSY`, `INTERNAL`, `TIMEOUT` |
| `user` | The user must act: grant a permission, unlock the Mac, or fix the setup | `PERMISSION_DENIED`, `SCREEN_LOCKED`, `SETUP_PROBLEM`, `CLIPBOARD_UNSAFE` |
| `check` | The action may have happened; look before repeating it | `OUTCOME_UNKNOWN` |

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
| `Unknown or expired ref`, `Expired ref … was replaced by snapshot …`, `… no longer exists or has changed`, or `… has quit or relaunched since mac_ui_tree` | Nothing was sent. Read `mac_ui_tree` again and use a ref from it. |
| `… is not a ref` | The value is not shaped like a ref, such as `k3f9q2.12`; refs from earlier versions of mac-control look like `3.12` and no longer work. Read `mac_ui_tree` and use a ref from it. |
| `… may or may not have happened` | The app did not confirm the action. Read `mac_ui_tree` to see whether it happened before trying again. |
| Clicks land in the wrong place | The screen changed after the screenshot. Take a new one, and pass `app` so the server can check. |
| Text or a click went to the agent's own window or another app | `app` was not passed. Always pass it. |
| The tools do not appear in the client | Restart the client, then check the server path in its configuration. In Claude Code, run `/mcp`. |

## Privacy and safety

- Screenshots, recordings, and UI tree values send what is on your screen to the agent's model. Close private windows first.
- `mac_type_text` briefly puts the text on the system clipboard, where clipboard history tools and Universal Clipboard on your other devices can capture it. Do not have the agent type passwords or other secrets.
- Recordings stay in `~/Movies/MacControl/` or `.build/recordings/` until you delete them. Delete the ones you no longer need.
- The server only reads and acts on your desktop. It opens no network port, does not run arbitrary shell commands, and talks only to the client that started it.
- The agent can click and type anything you could. Keep your client's approval prompts on, and do not let it confirm purchases, deletions, or messages without checking.
