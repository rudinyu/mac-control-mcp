# MacControl.app

English | [繁體中文](APP.zh-TW.md)

MacControl.app is the easiest way to use mac-control and mac-exec. It contains both MCP servers, and when you open it, it installs what is missing and connects Claude Desktop, Claude Code, and Codex for you. Nothing needs to be built, and Xcode is not required.

## Install

1. Download `MacControl-<version>.dmg` from the [Releases page](https://github.com/rudinyu/mac-control-mcp/releases).
2. Open it and drag **MacControl** into **Applications**. If you open it from somewhere else, the app offers to move itself.
3. Open MacControl from Applications and click **Set Up**.

Requires macOS 14 or later, on Apple silicon or Intel. The app is signed with a Developer ID and notarized by Apple, so it opens without warnings.

## What Set Up does

| Step | What happens |
| --- | --- |
| Location | Checks that the app is in `/Applications`, so client settings keep pointing at it. |
| Sandbox runtime | Only when "Run commands in a sandbox" is on. On **Apple silicon with macOS 26 or later**, it downloads Apple's signed `container` installer and opens it, and you confirm with your password. On other Macs it uses a Docker that already runs (Docker Desktop, OrbStack, Colima). If there is none, it downloads Colima, Lima, and the Docker CLI (about 80 MB) and starts a small VM named `maccontrol`. Once the runtime works, MacControl keeps using it, even after an update, a macOS upgrade, or when another Docker appears; if it stops working, the row says so instead of switching. If the Docker it used is uninstalled, it chooses again. To make it choose again otherwise, run `defaults delete tw.com.eaman.MacControl runtime` and reopen the window. |
| Sandbox image | Builds the Linux image that sandbox commands run in, then runs one test container. |
| Clients | Adds `mac-control` and `mac-exec` to every client it finds: Claude Desktop's configuration (keeping your other servers; the file as it was before MacControl first changed it is kept as `claude_desktop_config.json.before-maccontrol`), and Claude Code and Codex through their own `claude mcp add` and `codex mcp add` commands, for all projects. Only the two entries change in Claude Desktop's file; the rest keeps its layout, and a file that is a symbolic link stays one. If a client refuses a new entry, the previous one is put back, except a Claude Code entry with more than MacControl writes, such as arguments, a URL, headers, or other environment variables: `claude mcp add-json` would show them to other processes, so the error asks you to add it again yourself. Disconnecting and Remove from This Mac remove only entries that run MacControl, so an entry with the same name that runs a source build is kept. |

Every download has its version and SHA-256 checksum fixed inside the signed app. A file that does not match is refused, and Apple's installer must also be signed and notarized by Apple. The app never changes your own Docker settings: the Colima it installs uses a separate profile and its own Docker configuration.

After setting up, quit and reopen Claude Desktop, or start a new Claude Code or Codex session, to load the tools.

> Apple container was verified on Apple silicon with macOS 26: the sandbox runs as an unprivileged user with a read-only system, and files in the workspace appear on the Mac. If something fails on your Mac, please open an issue.

## Using it day to day

After Set Up finishes, the window closes and MacControl stays in the **menu bar**. The menu shows the current status and has **Open MacControl…**, **Check Now**, **Open at Login**, and **Quit**. The Dock icon appears only while the window is open, and closing the window keeps MacControl running. If your menu bar is full, macOS may hide the icon; open MacControl again from Applications or Spotlight to get the window back.

The header shows one line about the whole setup, such as "Ready: 3 clients connected, sandbox running." Each client has a switch: turning it on connects it, and turning it off asks first, then removes `mac-control` and `mac-exec` from that client. When you change a setting, a banner lists the clients that still use the old settings, and **Apply** updates them. Clients can only be connected once MacControl is in Applications, so they never point at a copy in Downloads.

The **Help** section shows the version and opens the release notes, this guide, the workspace, the command log (every sandbox and `host_exec` command), and MacControl's own setup log. When MacControl runs its own Linux VM, the Sandbox row shows its CPUs and memory, with **Stop VM** to free the memory; the VM starts again by itself when an agent needs it. With Apple container, the row has **Start** and **Stop** for the container service in the same way. On Apple silicon, Set Up downloads the Apple container installer, checks that Apple signed and notarized it, and opens it; once you finish the installer, setup continues by itself. If a step fails, **Copy Error** and **Show Log** give you the full message. **Remove from This Mac…** (in the **More** menu) disconnects every client, deletes the sandbox and the downloaded tools, and resets the settings and MacControlHelper's permissions, keeping your workspace, logs, and recordings in `~/Movies/MacControl`. If macOS keeps Screen Recording on for MacControlHelper, MacControl opens that page so you can remove it with –. The sandbox means MacControl's own Linux VM, or the `mac-exec-sandbox` image when you use your own Docker or Apple container; your Docker and Apple container stay installed. Apple container can be removed separately with `/usr/local/bin/uninstall-container.sh` if nothing else uses it. Dragging MacControl to the Trash without Remove leaves all of this behind.

When MacControl runs its own Linux VM, macOS may show a notification that "colima" can run in the background; that is the VM, and it is expected.

If MacControl says macOS is running a protected copy, it was opened straight from the DMG or from Downloads. Quit it, drag it into Applications in Finder, and open it from there.

MacControl checks GitHub for a newer release when it starts and at most once a day. It only reads the public release list and sends nothing about your Mac; when a newer version exists, the window and the menu show **Download**.

MacControl follows your Mac's language: it is in Traditional Chinese when that is your preferred language, and in English otherwise.

## Updating

MacControl does not replace itself. To update:

1. Click **Download** in the window or the menu, or open the [latest release](https://github.com/rudinyu/mac-control-mcp/releases/latest), and download the DMG.
2. Quit MacControl with **Quit MacControl** in its menu. Closing the window is not enough.
3. Open the DMG and drag MacControl into Applications, choosing **Replace**.
4. Open MacControl from Applications.

Permissions, connected clients, and the sandbox stay as they are; you do not need to click Set Up again. A client keeps running the mac-control and mac-exec it started until you restart it, so quit and reopen Claude Desktop and the Codex app, and start a new Claude Code or Codex session. Until then, MacControl names the clients that still use the previous version and does not report Ready.

## Permissions

macOS grants Accessibility and Screen Recording to whichever process is responsible for mac-control. That is never MacControl itself:

- **Claude Desktop, and the Codex app**: they run mac-control on its own behalf, so turn on **MacControlHelper.app**. Set Up asks macOS for these permissions once, which adds MacControlHelper.app to both lists; you only turn on the switches. **Ask macOS** in the Permissions section does the same again, or opens System Settings once macOS has already asked, and the section shows whether each permission is on. Until both are on, MacControl does not report Ready.
- **Claude Code, or Codex in a terminal**: the terminal app you run it in, such as Terminal or iTerm2.

A permission prompt names the app that asks, which is not always the one you expect:

| The prompt or the list names | What it is | What to do |
| --- | --- | --- |
| **MacControlHelper** | mac-control, started by Claude Desktop or the Codex app | Allow it. |
| Your terminal app, such as **iTerm2** | mac-control, started by Claude Code or Codex in that terminal | Allow it if you use those. |
| **Claude** or **ChatGPT** / **Codex** itself | A feature of that app, such as its own computer use, not mac-control | mac-control does not need it; allow it only if you use that feature. |
| **mac-control-mcp** | A copy of mac-control built from source and started by a desktop app | Allow it if you set that up yourself. |

macOS does not let any app turn these switches on for you. After turning them on, quit and reopen the client, and ask the agent to call `mac_status` to confirm. On macOS 27, Accessibility is called **Device Control and Data Access**.

## Settings

- **Run commands in a sandbox (mac-exec)**: turn off if you only want screen control.
- **Workspace**: the only Mac folder the sandbox can write to. The default is `~/AgentWorkspace`. Folders with credentials or settings, such as `~/.ssh` or `~/Library`, are refused. Keep it a folder only for the agent's work, not a project you develop on the Mac: files the sandbox writes there, such as Git hooks, can run on the Mac later. See [What the workspace can do](EXEC.md#what-the-workspace-can-do). When MacControl runs its own Linux VM, **Apply** or **Set Up** restarts the VM so it shares the new workspace.
- **Allow host_exec**: lets the agent run commands directly on the Mac, outside the sandbox. Off by default; see [mac-exec](EXEC.md#when-to-use-host_exec).

After changing a setting, click **Apply** in the banner to update the clients. Turning on host_exec asks you to confirm first.

## After a restart

You do not need to open MacControl again. When an agent sends its first sandbox command, mac-exec starts the `maccontrol` VM (or Apple's container service) by itself, which takes about half a minute, and writes the start to the audit log.

## Where things are

| Item | Location |
| --- | --- |
| The servers | `/Applications/MacControl.app/Contents/Helpers/`: `MacControlHelper.app` (mac-control) and `mac-exec-mcp` |
| Settings | `~/Library/Preferences/tw.com.eaman.MacControl.plist` |
| Setup log | `~/Library/Logs/MacControl/setup.log` |
| Colima, Lima, Docker CLI (when installed by the app) | `~/Library/Application Support/MacControl/runtime/` |
| The Colima VM | `~/.colima/maccontrol/` and `~/.colima/_lima/colima-maccontrol/` |
| Sandbox workspace | `~/AgentWorkspace`, or the folder you chose |
| Audit log | `~/Library/Logs/mac-exec/audit.log` |

## Uninstall

### The easy way

1. Open MacControl and choose **Remove from This Mac…**. From 0.3.4 it is in the **More** (…) menu at the bottom right; earlier versions have it as a button in the Help section.
2. Move MacControl from Applications to the Trash.

Dragging MacControl to the Trash without step 1 leaves the client entries, the sandbox, and the downloaded tools behind, and clients keep pointing at a program that no longer exists.

What **Remove from This Mac…** removes depends on the version:

| | 0.3.4 and earlier | 0.3.5 and later |
| --- | --- | --- |
| Claude Desktop, Claude Code, and Codex entries | Yes | Yes |
| MacControl's own Linux VM and the downloaded tools | Yes | Yes |
| The `mac-exec-sandbox` image in your own Docker or in Apple container | No | Yes |
| Permission entries in System Settings | No | Accessibility yes; Screen Recording may stay, and MacControl then opens that page |
| Settings | Yes | Yes |

After removing 0.3.4 or earlier, also do steps 3 and 5 below.

### By hand

Each step is safe to run when that part is not installed.

1. Quit MacControl:

   ```sh
   osascript -e 'tell application id "tw.com.eaman.MacControl" to quit'
   ```

2. Disconnect the clients:

   ```sh
   claude mcp remove --scope user mac-control; claude mcp remove --scope user mac-exec
   codex mcp remove mac_control; codex mcp remove mac_exec
   ```

   For Claude Desktop, delete the `mac-control` and `mac-exec` entries under `mcpServers` in `~/Library/Application Support/Claude/claude_desktop_config.json`, then quit and reopen Claude.

3. Remove the sandbox, for the runtime you used:

   ```sh
   # MacControl's own Linux VM (Colima profile "maccontrol")
   S="$HOME/Library/Application Support/MacControl"
   PATH="$S/runtime/bin:$S/runtime/lima-2.2.1/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
   DOCKER_CONFIG="$S/docker-config" "$S/runtime/bin/colima" delete --profile maccontrol --force

   # Your own Docker (Docker Desktop, OrbStack, or your own Colima)
   docker image rm mac-exec-sandbox:latest

   # Apple container (Apple silicon)
   container image delete mac-exec-sandbox:latest
   ```

   Apple container itself is a separate tool from Apple, and other programs may use it. If nothing else does, `/usr/local/bin/uninstall-container.sh -d` removes it with its data, and `-k` keeps the data.

4. Delete the downloaded tools and the settings:

   ```sh
   rm -rf "$HOME/Library/Application Support/MacControl"
   defaults delete tw.com.eaman.MacControl
   ```

5. Remove the permission entries. In **System Settings > Privacy & Security > Accessibility** (called **Device Control and Data Access** on macOS 27), select **MacControlHelper.app**, or `mac-control-mcp` if you added it by hand for an older version, and click **–**. Do the same under **Screen & System Audio Recording**. If **Open at Login** was on, also remove MacControl under **System Settings > General > Login Items**.

6. Move MacControl.app to the Trash:

   ```sh
   mv /Applications/MacControl.app ~/.Trash/
   ```

Both ways keep your workspace (`~/AgentWorkspace`, or the folder you chose) and the logs (`~/Library/Logs/MacControl` and `~/Library/Logs/mac-exec`), since they may hold your own work. Delete them yourself if you no longer need them.

## For maintainers: building a release

One-time setup on the build Mac:

1. Install the **Developer ID Application** certificate with its private key, then check it with `security find-identity -v -p codesigning`.
2. Store the notarization key: `xcrun notarytool store-credentials maccontrol --key AuthKey_<id>.p8 --key-id <id> --issuer <issuer id>`. Keep the `.p8` out of the repository; `.gitignore` refuses it.

Then:

```sh
sh scripts/build-app.sh --sign   # universal app, signed
sh scripts/notarize.sh           # notarize and staple the app, then make, notarize, and staple the DMG, and check with Gatekeeper
```

`sh scripts/build-app.sh` without `--sign` builds an ad-hoc signed app for local testing. To release, run `sh scripts/ci.sh`, push a tag such as `v0.3.0` that matches `App/Info.plist`, then build with `sh scripts/build-app.sh --sign`, notarize with `sh scripts/notarize.sh`, and publish the DMG and its `.sha256` with `gh release create`. On GitHub Actions the tag is checked against `App/Info.plist` and the tests run; if the repository has the signing secrets listed in the workflow, Actions builds, notarizes, and publishes instead. On Actions, `scripts/ci.sh` runs on every push to `main`, on pull requests, and before each release, which waits for it to pass; the sandbox tests are skipped there, since the runner has no Docker. The pinned download versions and checksums live in `App/Sources/RuntimePlan.swift`; update them together, after checking each file against its project's published checksum. `swift scripts/make-icon.swift` redraws the icon. The app's decisions that need no window, such as which runtime to use and what the summary says, are in files that `tests/AppLogicTests.swift` checks; `scripts/sources.sh` lists them and the sandbox files the app shares with `mac-exec`, for both `build-app.sh` and `ci.sh`.

To test a runtime that this Mac would not choose by itself: `defaults write tw.com.eaman.MacControl runtimeOverride managedColima` (or `appleContainer`), and `defaults delete tw.com.eaman.MacControl runtimeOverride` to undo it. To let MacControl choose the runtime again, as after installing Docker Desktop, run `defaults delete tw.com.eaman.MacControl runtime` and reopen the window.
