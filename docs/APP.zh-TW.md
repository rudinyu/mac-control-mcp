# MacControl.app

[English](APP.md) | 繁體中文

MacControl.app 是使用 mac-control 和 mac-exec 最簡單的方式。它內含兩個 MCP 伺服器；打開後會自動安裝缺少的元件，並幫你連接 Claude Desktop、Claude Code 和 Codex。不需要自己編譯，也不需要 Xcode。

## 安裝

1. 從 [Releases 頁面](https://github.com/rudinyu/mac-control-mcp/releases) 下載 `MacControl-<版本>.dmg`。
2. 打開它，把 **MacControl** 拖進「**應用程式**」。如果從其他位置打開，App 會提議把自己移過去。
3. 從「應用程式」打開 MacControl，按 **Set Up**。

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

> Apple container 的支援還沒有在 Apple Silicon 硬體上實際驗證過。如果在那裡出問題，請開 issue 回報。

## 日常使用

Set Up 完成後，視窗會關閉，MacControl 會常駐在**選單列**。選單會顯示目前狀態，並有 **Open MacControl…**、**Check Now**、**Open at Login** 和 **Quit**。只有視窗開著時才會出現 Dock 圖示；關閉視窗不會結束 MacControl。如果選單列太滿，macOS 可能會把圖示藏起來；這時從「應用程式」或 Spotlight 再打開 MacControl，就會出現視窗。

視窗頂端會用一行字說明整體狀態，例如「Ready: 3 clients connected, sandbox running.」。每個客戶端都有一個開關：打開就會連接；關閉時會先詢問，再從該客戶端移除 `mac-control` 和 `mac-exec`。修改設定後，橫幅會列出還在用舊設定的客戶端，按 **Apply** 就會更新。MacControl 必須放在「應用程式」裡才能連接客戶端，以免客戶端指到「下載項目」裡的副本。

**說明**區塊會顯示版本，並可以打開版本說明、這份使用說明、工作資料夾、指令紀錄（每一個 sandbox 和 `host_exec` 指令），以及 MacControl 自己的設定紀錄。當 MacControl 使用自己管理的 Linux VM 時，Sandbox 那一列會顯示它的 CPU 和記憶體，並有**停止 VM** 可以釋放記憶體；代理需要時 VM 會自己再啟動。某個步驟失敗時，**拷貝錯誤訊息**和**顯示紀錄**可以看到完整的錯誤。**從這台 Mac 移除…** 會中斷所有客戶端、刪除 VM 和下載的工具，並重設設定，你的工作資料夾和紀錄會保留。

MacControl 使用自己管理的 Linux VM 時，macOS 可能會通知「colima」可以在背景執行，那就是這台 VM，屬於正常現象。

如果 MacControl 顯示 macOS 正在執行受保護的副本，表示它是直接從 DMG 或「下載項目」打開的。請結束它，在 Finder 裡把它拖進「應用程式」，再從那裡打開。

MacControl 啟動時，以及之後最多每天一次，會到 GitHub 查詢有沒有新版本。它只讀取公開的版本清單，不會送出任何關於你這台 Mac 的資訊；有新版本時，視窗和選單會出現**下載**。

MacControl 會跟著 Mac 的語言設定：偏好語言是繁體中文時顯示中文，其他情況顯示英文。

## 權限

macOS 的輔助使用和螢幕錄製權限，是給「啟動伺服器的 App」，不是給 MacControl。Permissions 區塊會列出每個客戶端要開哪個 App，並幫你打開正確的系統設定頁：

- **Claude Desktop**：Claude
- **Claude Code**：你執行它的終端機 App，例如「終端機」或 iTerm2
- **Codex**：Codex App，或你執行 `codex` 的終端機 App

接著完全結束並重開那個 App，請代理呼叫 `mac_status` 確認。

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
| 伺服器 | `/Applications/MacControl.app/Contents/Helpers/` |
| Colima、Lima、Docker CLI（由 App 安裝時） | `~/Library/Application Support/MacControl/runtime/` |
| Colima VM | `~/.colima/maccontrol/` 和 `~/.colima/_lima/colima-maccontrol/` |
| Sandbox 工作資料夾 | `~/AgentWorkspace`，或你選的資料夾 |
| 稽核紀錄 | `~/Library/Logs/mac-exec/audit.log` |

## 移除

1. 移除客戶端的設定：`claude mcp remove --scope user mac-control` 和 `mac-exec`；`codex mcp remove mac_control` 和 `mac_exec`；並從 Claude Desktop 的設定檔刪除那兩項。
2. 如果 Colima 是 App 安裝的：執行 `~/Library/Application\ Support/MacControl/runtime/bin/colima delete --profile maccontrol`，再刪除 `~/Library/Application Support/MacControl`。
3. 如果 Apple container 是 App 安裝的，請參考 Apple 對 `container` 的移除說明。
4. 把 MacControl.app 丟到垃圾桶。

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
