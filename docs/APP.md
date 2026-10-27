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

## Permissions

macOS grants Accessibility and Screen Recording to the app that starts the servers, not to MacControl. The Permissions section lists which app to turn on for each client and opens the right System Settings pages:

- **Claude Desktop**: Claude
- **Claude Code**: the terminal app you run it in, such as Terminal or iTerm2
- **Codex**: the Codex app, or the terminal app you run `codex` in

Then quit and reopen that app, and ask the agent to call `mac_status` to confirm.

## Settings

- **Run commands in a sandbox (mac-exec)**: turn off if you only want screen control.
- **Workspace**: the only Mac folder the sandbox can write to. The default is `~/AgentWorkspace`. Folders with credentials or settings, such as `~/.ssh` or `~/Library`, are refused.
- **Allow host_exec**: lets the agent run commands directly on the Mac, outside the sandbox. Off by default; see [mac-exec](EXEC.md#when-to-use-host_exec).

Changing a setting marks the clients as not connected. Click **Connect** to update them.

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
