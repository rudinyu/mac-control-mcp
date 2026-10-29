# MacControl.app

[English](APP.md) | 繁體中文

MacControl.app 是使用 mac-control 和 mac-exec 最簡單的方式。它內含兩個 MCP 伺服器；打開後會自動安裝缺少的元件，並幫你連接 Claude Desktop、Claude Code 和 Codex。不需要自己編譯，也不需要 Xcode。

## 安裝

1. 從 [Releases 頁面](https://github.com/rudinyu/mac-control-mcp/releases) 下載 `MacControl-<版本>.dmg`。
2. 打開它，把 **MacControl** 拖進「**應用程式**」。如果從其他位置打開，App 會提議把自己移過去。
3. 從「應用程式」打開 MacControl，按 **Set Up**（中文介面為「開始設定」）。

需要 macOS 14 或以上，Apple Silicon 和 Intel 都可以。App 有 Developer ID 簽章並通過 Apple 公證，打開時不會出現警告。

## Set Up 會做什麼

| 步驟 | 內容 |
| --- | --- |
| 位置 | 確認 App 在 `/Applications`，讓客戶端的設定一直指得到它。 |
| Sandbox 執行環境 | 只在開啟「Run commands in a sandbox」時才做。**Apple Silicon 搭配 macOS 26 或以上**：下載 Apple 簽章的 `container` 安裝程式並打開，由你輸入密碼確認。其他 Mac：使用已經在跑的 Docker（Docker Desktop、OrbStack、Colima）；如果沒有，就下載 Colima、Lima 和 Docker CLI（約 80 MB），並啟動一台叫 `maccontrol` 的小型 VM。 |
| Sandbox 映像檔 | 建置 sandbox 指令使用的 Linux 映像檔，然後跑一個測試容器。 |
| 客戶端 | 把 `mac-control` 和 `mac-exec` 加進找到的每個客戶端：Claude Desktop 的設定檔（保留你其他的伺服器；MacControl 第一次修改前的原檔會保存為 `claude_desktop_config.json.before-maccontrol`）；Claude Code 和 Codex 則用它們自己的 `claude mcp add`、`codex mcp add` 指令，套用到所有專案。 |

每個下載檔的版本和 SHA-256 校驗碼都固定在已簽章的 App 裡，不符合就拒絕安裝；Apple 的安裝程式還必須經過 Apple 簽章和公證。App 不會改動你自己的 Docker 設定：它安裝的 Colima 使用獨立的 profile 和自己的 Docker 設定。

設定完成後，完全結束並重開 Claude Desktop，或開一個新的 Claude Code、Codex 工作階段，就會載入這些工具。

> Apple container 已在 Apple Silicon 搭配 macOS 26 上驗證過：sandbox 以非特權使用者執行、系統為唯讀，工作資料夾裡的檔案會出現在 Mac 上。如果在你的 Mac 上出問題，請開 issue 回報。

## 日常使用

Set Up 完成後，視窗會關閉，MacControl 會常駐在**選單列**。選單會顯示目前狀態，並有 **Open MacControl…**、**Check Now**、**Open at Login** 和 **Quit**。只有視窗開著時才會出現 Dock 圖示；關閉視窗不會結束 MacControl。如果選單列太滿，macOS 可能會把圖示藏起來；這時從「應用程式」或 Spotlight 再打開 MacControl，就會出現視窗。

視窗頂端會用一行字說明整體狀態，例如「Ready: 3 clients connected, sandbox running.」。每個客戶端都有一個開關：打開就會連接；關閉時會先詢問，再從該客戶端移除 `mac-control` 和 `mac-exec`。修改設定後，橫幅會列出還在用舊設定的客戶端，按 **Apply** 就會更新。MacControl 必須放在「應用程式」裡才能連接客戶端，以免客戶端指到「下載項目」裡的副本。

**說明**區塊會顯示版本，並可以打開版本說明、這份使用說明、工作資料夾、指令紀錄（每一個 sandbox 和 `host_exec` 指令），以及 MacControl 自己的設定紀錄。當 MacControl 使用自己管理的 Linux VM 時，Sandbox 那一列會顯示它的 CPU 和記憶體，並有**停止 VM** 可以釋放記憶體；代理需要時 VM 會自己再啟動。使用 Apple container 時，這一列同樣有**啟動**和**停止**，用來控制 container 服務。在 Apple Silicon 上，「開始設定」會下載 Apple container 安裝程式，確認它經過 Apple 簽章和公證後打開；你完成安裝程式後，設定會自己接著進行。某個步驟失敗時，**拷貝錯誤訊息**和**顯示紀錄**可以看到完整的錯誤。**從這台 Mac 移除…**（在**更多**選單裡）會中斷所有客戶端、刪除 sandbox 和下載的工具，並重設設定和 MacControlHelper 的權限，你的工作資料夾、紀錄，以及 `~/Movies/MacControl` 裡的錄影檔會保留。如果 macOS 仍保留 MacControlHelper 的螢幕錄製權限，MacControl 會打開那一頁，讓你用「–」移除。sandbox 指的是 MacControl 自己的 Linux VM；如果用的是你自己的 Docker 或 Apple container，則是裡面的 `mac-exec-sandbox` image，Docker 和 Apple container 本身會保留。如果沒有其他程式在用 Apple container，可以另外執行 `/usr/local/bin/uninstall-container.sh` 移除。沒有先按「移除」就把 MacControl 丟到垃圾桶，這些都會留在 Mac 上。

MacControl 使用自己管理的 Linux VM 時，macOS 可能會通知「colima」可以在背景執行，那就是這台 VM，屬於正常現象。

如果 MacControl 顯示 macOS 正在執行受保護的副本，表示它是直接從 DMG 或「下載項目」打開的。請結束它，在 Finder 裡把它拖進「應用程式」，再從那裡打開。

MacControl 啟動時，以及之後最多每天一次，會到 GitHub 查詢有沒有新版本。它只讀取公開的版本清單，不會送出任何關於你這台 Mac 的資訊；有新版本時，視窗和選單會出現**下載**。

MacControl 會跟著 Mac 的語言設定：偏好語言是繁體中文時顯示中文，其他情況顯示英文。

## 更新

MacControl 不會自己替換自己。更新步驟：

1. 在視窗或選單裡按**下載**，或打開[最新版本](https://github.com/rudinyu/mac-control-mcp/releases/latest)，下載 DMG。
2. 從選單選 **Quit MacControl** 結束 MacControl。只關閉視窗不夠。
3. 打開 DMG，把 MacControl 拖到「應用程式」，選**取代**。
4. 從「應用程式」打開 MacControl。

權限、已連接的客戶端和 sandbox 都會保留，不需要再按「開始設定」。客戶端在重新啟動之前，會繼續執行它當初啟動的 mac-control 和 mac-exec，所以請結束並重開 Claude Desktop 和 Codex App，並開始新的 Claude Code 或 Codex 工作階段。在那之前，MacControl 會列出仍在使用舊版的客戶端，也不會顯示「已就緒」。

## 權限

macOS 的輔助使用和螢幕錄製權限，是給「負責 mac-control 的那個程序」，永遠不是 MacControl 本身：

- **Claude Desktop 和 Codex App**：它們以 mac-control 自己的名義啟動它，所以要開 **MacControlHelper.app**。「設定」會向 macOS 要求一次權限，MacControlHelper.app 就會出現在兩個清單裡，你只要打開開關。Permissions 區塊的**向 macOS 要求**可以再要求一次；如果 macOS 已經問過，則直接打開系統設定。區塊也會顯示每個權限是否已開啟，兩個都開啟之前，MacControl 不會顯示「已就緒」。
- **在終端機裡跑的 Claude Code 或 Codex**：你執行它的終端機 App，例如「終端機」或 iTerm2。

權限提示顯示的是「提出要求的 App」，不一定是你以為的那一個：

| 提示或清單裡的名稱 | 它是什麼 | 怎麼做 |
| --- | --- | --- |
| **MacControlHelper** | 由 Claude Desktop 或 Codex App 啟動的 mac-control | 允許。 |
| 你的終端機 App，例如 **iTerm2** | 由那個終端機裡的 Claude Code 或 Codex 啟動的 mac-control | 有在用就允許。 |
| **Claude**、**ChatGPT** 或 **Codex** 本身 | 那個 App 自己的功能，例如它內建的電腦操作，不是 mac-control | mac-control 不需要；只有你要用那個功能才允許。 |
| **mac-control-mcp** | 從原始碼建置、由桌面 App 啟動的 mac-control | 如果是你自己這樣設定的就允許。 |

macOS 不允許任何 App 代替你打開這些開關。打開後，完全結束並重開客戶端，請代理呼叫 `mac_status` 確認。在 macOS 27，「輔助使用」改名為 **Device Control and Data Access**。

## 設定

- **Run commands in a sandbox (mac-exec)**：如果只需要畫面控制，可以關掉。
- **Workspace**：sandbox 唯一能寫入的 Mac 資料夾，預設 `~/AgentWorkspace`。含有憑證或設定的資料夾，例如 `~/.ssh`、`~/Library`，一律拒絕。
- **Allow host_exec**：讓代理直接在 Mac 上、sandbox 之外執行指令。預設關閉；見 [mac-exec](EXEC.zh-TW.md#什麼時候用-host_exec)。

修改設定後，按橫幅上的 **Apply** 更新客戶端。開啟 host_exec 前會先要求確認。

## 重新開機之後

不需要再打開 MacControl。代理送出第一個 sandbox 指令時，mac-exec 會自己啟動 `maccontrol` VM（或 Apple 的 container 服務），大約半分鐘，並把這次啟動寫進稽核紀錄。

## 檔案位置

| 項目 | 位置 |
| --- | --- |
| 伺服器 | `/Applications/MacControl.app/Contents/Helpers/`：`MacControlHelper.app`（mac-control）和 `mac-exec-mcp` |
| 設定 | `~/Library/Preferences/tw.com.eaman.MacControl.plist` |
| 設定紀錄 | `~/Library/Logs/MacControl/setup.log` |
| Colima、Lima、Docker CLI（由 App 安裝時） | `~/Library/Application Support/MacControl/runtime/` |
| Colima VM | `~/.colima/maccontrol/` 和 `~/.colima/_lima/colima-maccontrol/` |
| Sandbox 工作資料夾 | `~/AgentWorkspace`，或你選的資料夾 |
| 稽核紀錄 | `~/Library/Logs/mac-exec/audit.log` |

## 移除

### 簡單的方法

1. 打開 MacControl，選**從這台 Mac 移除…**。0.3.4 起它在右下角的**更多**（…）選單裡；更早的版本是說明區塊裡的一個按鈕。
2. 把 MacControl 從「應用程式」丟到垃圾桶。

沒有先做第 1 步就把 MacControl 丟到垃圾桶，客戶端設定、sandbox 和下載的工具都會留在 Mac 上，客戶端也會繼續指向一個已經不存在的程式。

**從這台 Mac 移除…** 會移除哪些東西，依版本而不同：

| | 0.3.4 以前 | 0.3.5 以後 |
| --- | --- | --- |
| Claude Desktop、Claude Code 和 Codex 的設定 | 會 | 會 |
| MacControl 自己的 Linux VM 和下載的工具 | 會 | 會 |
| 你自己的 Docker 或 Apple container 裡的 `mac-exec-sandbox` image | 不會 | 會 |
| 系統設定裡的權限項目 | 不會 | 輔助使用會；螢幕錄製可能保留，這時 MacControl 會打開那一頁 |
| 設定 | 會 | 會 |

移除 0.3.4 以前的版本後，請再做下面的第 3 步和第 5 步。

### 手動移除

每一步在對應的部分沒有安裝時，執行也不會出問題。

1. 結束 MacControl：

   ```sh
   osascript -e 'tell application id "tw.com.eaman.MacControl" to quit'
   ```

2. 中斷客戶端：

   ```sh
   claude mcp remove --scope user mac-control; claude mcp remove --scope user mac-exec
   codex mcp remove mac_control; codex mcp remove mac_exec
   ```

   Claude Desktop 的部分，請在 `~/Library/Application Support/Claude/claude_desktop_config.json` 的 `mcpServers` 底下刪除 `mac-control` 和 `mac-exec` 兩項，再完全結束並重開 Claude。

3. 依你用的 runtime 移除 sandbox：

   ```sh
   # MacControl 自己的 Linux VM（Colima profile "maccontrol"）
   S="$HOME/Library/Application Support/MacControl"
   PATH="$S/runtime/bin:$S/runtime/lima-2.2.1/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
   DOCKER_CONFIG="$S/docker-config" "$S/runtime/bin/colima" delete --profile maccontrol --force

   # 你自己的 Docker（Docker Desktop、OrbStack 或你自己的 Colima）
   docker image rm mac-exec-sandbox:latest

   # Apple container（Apple Silicon）
   container image delete mac-exec-sandbox:latest
   ```

   Apple container 本身是 Apple 的另一個工具，其他程式也可能在用。如果沒有其他程式在用，`/usr/local/bin/uninstall-container.sh -d` 會連同資料一起移除，`-k` 則保留資料。

4. 刪除下載的工具和設定：

   ```sh
   rm -rf "$HOME/Library/Application Support/MacControl"
   defaults delete tw.com.eaman.MacControl
   ```

5. 移除權限項目。在**系統設定 → 隱私權與安全性 → 輔助使用**（macOS 27 叫 **Device Control and Data Access**）選取 **MacControlHelper.app**；如果你曾為舊版手動加入 `mac-control-mcp`，也選取它，按 **–**。**螢幕與系統音訊錄製**也照做一次。如果開過**登入時打開**，也到**系統設定 → 一般 → 登入項目**移除 MacControl。

6. 把 MacControl.app 丟到垃圾桶：

   ```sh
   mv /Applications/MacControl.app ~/.Trash/
   ```

兩種方法都會保留你的工作資料夾（`~/AgentWorkspace` 或你選的資料夾）和紀錄（`~/Library/Logs/MacControl` 和 `~/Library/Logs/mac-exec`），因為裡面可能有你自己的東西。不需要的話請自己刪除。

## 給維護者：建置發行版

在建置用的 Mac 上做一次：

1. 安裝 **Developer ID Application** 憑證和它的私鑰，用 `security find-identity -v -p codesigning` 確認。
2. 儲存公證用的金鑰：`xcrun notarytool store-credentials maccontrol --key AuthKey_<id>.p8 --key-id <id> --issuer <issuer id>`。不要把 `.p8` 放進 repo；`.gitignore` 會擋下它。

之後：

```sh
sh scripts/build-app.sh --sign                         # 通用版 App，已簽章，外加已簽章的 DMG
sh scripts/notarize.sh .build/app/MacControl-<版本>.dmg   # 公證、staple，並用 Gatekeeper 檢查
```

不加 `--sign` 的 `sh scripts/build-app.sh` 會建置 ad-hoc 簽章的 App，供本機測試。推送跟 `App/Info.plist` 版本一致的 tag（例如 `v0.3.0`），GitHub Actions 就會跑同樣的步驟並發布 DMG；需要的 secrets 列在 workflow 裡。固定的下載版本和校驗碼在 `App/Sources/RuntimePlan.swift`；更新時要一起改，並先用各專案公布的校驗碼核對每個檔案。`swift scripts/make-icon.swift` 會重新繪製圖示。

要測試這台 Mac 不會自動選的執行環境：`defaults write tw.com.eaman.MacControl runtimeOverride managedColima`（或 `appleContainer`）；用 `defaults delete tw.com.eaman.MacControl runtimeOverride` 還原。
