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
| Sandbox runtime | Only when "Run commands in a sandbox" is on. On **Apple silicon with macOS 26 or later**, it downloads Apple's signed `container` installer and opens it, and you confirm with your password. On other Macs it uses a Docker that already runs (Docker Desktop, OrbStack, Colima). If there is none, it downloads Colima, Lima, and the Docker CLI (about 80 MB) and starts a small VM named `maccontrol`. |
| Sandbox image | Builds the Linux image that sandbox commands run in, then runs one test container. |
| Clients | Adds `mac-control` and `mac-exec` to every client it finds: Claude Desktop's configuration (keeping your other servers; the file as it was before MacControl first changed it is kept as `claude_desktop_config.json.before-maccontrol`), and Claude Code and Codex through their own `claude mcp add` and `codex mcp add` commands, for all projects. |

Every download has its version and SHA-256 checksum fixed inside the signed app. A file that does not match is refused, and Apple's installer must also be signed and notarized by Apple. The app never changes your own Docker settings: the Colima it installs uses a separate profile and its own Docker configuration.

After setting up, quit and reopen Claude Desktop, or start a new Claude Code or Codex session, to load the tools.

> Apple container support has not yet been verified on Apple silicon hardware. If something fails there, please open an issue.

## Using it day to day

After Set Up finishes, the window closes and MacControl stays in the **menu bar**. The menu shows the current status and has **Open MacControl…**, **Check Now**, **Open at Login**, and **Quit**. The Dock icon appears only while the window is open, and closing the window keeps MacControl running. If your menu bar is full, macOS may hide the icon; open MacControl again from Applications or Spotlight to get the window back.

The header shows one line about the whole setup, such as "Ready: 3 clients connected, sandbox running." Each client has a switch: turning it on connects it, and turning it off asks first, then removes `mac-control` and `mac-exec` from that client. When you change a setting, a banner lists the clients that still use the old settings, and **Apply** updates them. Clients can only be connected once MacControl is in Applications, so they never point at a copy in Downloads.

The **Help** section shows the version and opens the release notes, this guide, the workspace, the command log (every sandbox and `host_exec` command), and MacControl's own setup log. When MacControl runs its own Linux VM, the Sandbox row shows its CPUs and memory, with **Stop VM** to free the memory; the VM starts again by itself when an agent needs it. With Apple container, the row has **Start** and **Stop** for the container service in the same way. On Apple silicon, Set Up downloads the Apple container installer, checks that Apple signed and notarized it, and opens it; once you finish the installer, setup continues by itself. If a step fails, **Copy Error** and **Show Log** give you the full message. **Remove from This Mac…** (in the **More** menu) disconnects every client, deletes the sandbox and the downloaded tools, and resets the settings and MacControlHelper's permissions, keeping your workspace and logs. If macOS keeps Screen Recording on for MacControlHelper, MacControl opens that page so you can remove it with –. The sandbox means MacControl's own Linux VM, or the `mac-exec-sandbox` image when you use your own Docker or Apple container; your Docker and Apple container stay installed. Apple container can be removed separately with `/usr/local/bin/uninstall-container.sh` if nothing else uses it. Dragging MacControl to the Trash without Remove leaves all of this behind.

When MacControl runs its own Linux VM, macOS may show a notification that "colima" can run in the background; that is the VM, and it is expected.

If MacControl says macOS is running a protected copy, it was opened straight from the DMG or from Downloads. Quit it, drag it into Applications in Finder, and open it from there.

MacControl checks GitHub for a newer release when it starts and at most once a day. It only reads the public release list and sends nothing about your Mac; when a newer version exists, the window and the menu show **Download**.

MacControl follows your Mac's language: it is in Traditional Chinese when that is your preferred language, and in English otherwise.

## Permissions

macOS grants Accessibility and Screen Recording to whichever process is responsible for mac-control. That is never MacControl itself:

- **Claude Desktop, and the Codex app**: they run mac-control on its own behalf, so turn on **MacControlHelper.app**. Set Up asks macOS for these permissions once, which adds MacControlHelper.app to both lists; you only turn on the switches. **Ask macOS** in the Permissions section does the same again, and the section shows whether each permission is on.
- **Claude Code, or Codex in a terminal**: the terminal app you run it in, such as Terminal or iTerm2.

macOS does not let any app turn these switches on for you. After turning them on, quit and reopen the client, and ask the agent to call `mac_status` to confirm. On macOS 27, Accessibility is called **Device Control and Data Access**.

## Settings

- **Run commands in a sandbox (mac-exec)**: turn off if you only want screen control.
- **Workspace**: the only Mac folder the sandbox can write to. The default is `~/AgentWorkspace`. Folders with credentials or settings, such as `~/.ssh` or `~/Library`, are refused.
- **Allow host_exec**: lets the agent run commands directly on the Mac, outside the sandbox. Off by default; see [mac-exec](EXEC.md#when-to-use-host_exec).

After changing a setting, click **Apply** in the banner to update the clients. Turning on host_exec asks you to confirm first.

## After a restart

You do not need to open MacControl again. When an agent sends its first sandbox command, mac-exec starts the `maccontrol` VM (or Apple's container service) by itself, which takes about half a minute, and writes the start to the audit log.

## Where things are

| Item | Location |
| --- | --- |
| The servers | `/Applications/MacControl.app/Contents/Helpers/` |
| Colima, Lima, Docker CLI (when installed by the app) | `~/Library/Application Support/MacControl/runtime/` |
| The Colima VM | `~/.colima/maccontrol/` and `~/.colima/_lima/colima-maccontrol/` |
| Sandbox workspace | `~/AgentWorkspace`, or the folder you chose |
| Audit log | `~/Library/Logs/mac-exec/audit.log` |

## Uninstall

1. Remove the client entries: `claude mcp remove --scope user mac-control` and `mac-exec`; `codex mcp remove mac_control` and `mac_exec`; and delete the two entries from Claude Desktop's configuration.
2. If the app installed Colima: `~/Library/Application\ Support/MacControl/runtime/bin/colima delete --profile maccontrol`, then delete `~/Library/Application Support/MacControl`.
3. If the app installed Apple container, see Apple's uninstall instructions for `container`.
4. Move MacControl.app to the Trash.

## For maintainers: building a release

One-time setup on the build Mac:

1. Install the **Developer ID Application** certificate with its private key, then check it with `security find-identity -v -p codesigning`.
2. Store the notarization key: `xcrun notarytool store-credentials maccontrol --key AuthKey_<id>.p8 --key-id <id> --issuer <issuer id>`. Keep the `.p8` out of the repository; `.gitignore` refuses it.

Then:

```sh
sh scripts/build-app.sh --sign                         # universal app, signed, plus a signed DMG
sh scripts/notarize.sh .build/app/MacControl-<version>.dmg   # notarize, staple, and check with Gatekeeper
```

`sh scripts/build-app.sh` without `--sign` builds an ad-hoc signed app for local testing. Pushing a tag such as `v0.3.0` that matches `App/Info.plist` runs the same steps on GitHub Actions and publishes the DMG; the workflow lists the secrets it needs. The pinned download versions and checksums live in `App/Sources/RuntimePlan.swift`; update them together, after checking each file against its project's published checksum. `swift scripts/make-icon.swift` redraws the icon.

To test a runtime that this Mac would not choose by itself: `defaults write tw.com.eaman.MacControl runtimeOverride managedColima` (or `appleContainer`), and `defaults delete tw.com.eaman.MacControl runtimeOverride` to undo it.
