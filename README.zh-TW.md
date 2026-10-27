# mac-control-mcp

[English](README.md) | 繁體中文

**指南：**[安裝](docs/INSTALL.zh-TW.md) · [使用說明與工具參考](docs/USAGE.zh-TW.md) · [mac-exec：在 sandbox 裡執行指令和處理檔案](docs/EXEC.zh-TW.md)

這是一個在你自己的 Mac 上執行的 MCP 伺服器，讓本機 Claude Code 或 Codex 使用 macOS 的截圖、輔助使用、鍵盤、滑鼠與螢幕錄影功能。它只透過標準輸入／輸出與 MCP 主程式通信，mac-control 沒有網路監聽埠，也不提供任意 shell 指令。

這個 repo 另外還有 **mac-exec**，是一個獨立的 MCP 伺服器，預設在隔離的 Docker 容器裡執行指令和處理檔案。見 [docs/EXEC.zh-TW.md](docs/EXEC.zh-TW.md)。

## 功能

| 工具 | 功能 |
| --- | --- |
| `mac_status` | 查看顯示器、前景 App 和權限狀態 |
| `mac_request_screen_recording` | 觸發 macOS 螢幕錄製權限提示 |
| `mac_screenshot` | 擷取主螢幕，回傳 JPEG 給模型 |
| `mac_ui_tree` | 讀取前景 App（或用 `app` 指定的 App）的輔助使用元素，遮蔽密碼欄位內容 |
| `mac_mouse` | 移動、點擊、雙擊、右鍵點擊、拖曳 |
| `mac_scroll` | 垂直或水平捲動 |
| `mac_type_text` | 暫時放入文字並模擬 Command-V，輸入 Unicode 文字後還原剪貼簿 |
| `mac_key` | 按 Enter、方向鍵、字母鍵及 Command 等組合鍵 |
| `mac_record_start` / `mac_record_status` / `mac_record_stop` | 錄製主螢幕影片到本機 MOV 檔，單次最長 120 秒 |

滑鼠座標使用**最近一次 `mac_screenshot` 影像的像素座標**。螢幕解析度變動後，請先重新截圖。錄影檔存於 `.build/recordings/`，此目錄不會進入 Git；錄影工具回傳的檔案路徑可供本機查看或後續處理。影片沒有額外錄製麥克風或系統音訊。

`mac_type_text`、`mac_key` 和 `mac_ui_tree` 可以加上 `app` 參數，填執行中、有 Dock 圖示的 App 名稱或 bundle ID（例如 `TextEdit` 或 `com.apple.TextEdit`）。名稱同時符合多個 App 時，會選目前在前景的那個；都不在前景就回報錯誤並列出候選，請改用 bundle ID。輸入工具會先把該 App 切到前景，送出前再確認一次；如果焦點已經被其他 App 搶走，就不會送出任何輸入，並回報錯誤。`mac_ui_tree` 指定 `app` 時只讀取，不會切換前景 App。代理在終端機裡執行時，焦點常在兩次工具呼叫之間回到終端機，所以建議輸入時一律指定 `app`。iTerm2 等終端機在輔助使用文字裡用 NUL 代表寬字元的補位和空白格：寬字元後的補位會移除，其他 NUL 轉成空格，每行結尾的空白會去掉。

`mac_type_text` 會短暫使用系統剪貼簿，再還原原有內容；如果在貼上期間其他程式更新了剪貼簿，它不會覆寫該更新。超過 40 MB 或無法完整保存的剪貼簿內容會讓輸入取消。這比直接送 Unicode 鍵盤事件更能配合目前的注音輸入法與各 App 文字欄位。

## 建置與測試

需要已安裝 Xcode Command Line Tools 的 macOS、Swift，以及 Python 3。

```sh
sh scripts/ci.sh
```

這會編譯 `.build/mac-control-mcp` 和 `.build/terminal-text-tests`，執行終端機文字清理的單元測試，以及不操作桌面的 MCP 協定測試。GitHub Actions 使用同一份腳本。

若要在每次 commit 前自動跑同樣的檢查，clone 之後執行一次以下命令，啟用專案的 Git hook：

```sh
git config core.hooksPath .githooks
```

這個 hook 只需要上面列的工具。如果有安裝 `codex-precommit-check` 和 `claude` CLI，它會另外執行 Claude code review；沒有安裝就略過。要在某次 commit 略過 review，可設定 `CODEX_SKIP_REVIEW=1`。

## 連接 Claude Code 與 Codex

代理設定含有這份 clone 的絕對路徑，所以不放進 repo（見 `.gitignore`）。clone 之後執行以下命令產生：

```sh
sh scripts/init-agents.sh
```

它會依照 [`examples/`](examples/) 裡的範本，在專案根目錄產生下列檔案，並自動填入你的 clone 路徑。已存在的檔案會保留，加上 `--force` 才會覆蓋。

| 檔案 | 給誰用 | 範本 |
| --- | --- | --- |
| `.mcp.json` | Claude Code：為這個專案啟動 MCP 伺服器 | [`examples/mcp.json`](examples/mcp.json) |
| `CLAUDE.md` | Claude Code：告訴它使用 mac-control 及使用方式 | [`examples/CLAUDE.md`](examples/CLAUDE.md) |
| `.codex/config.toml` | Codex：為這個專案啟動 MCP 伺服器 | [`examples/codex/config.toml`](examples/codex/config.toml) |
| `AGENTS.md` | Codex：告訴它使用 mac-control 及使用方式 | [`examples/AGENTS.md`](examples/AGENTS.md) |

只有兩個 MCP 設定檔是必要的；`CLAUDE.md` 和 `AGENTS.md` 是選用的說明。兩個 MCP 設定檔都會啟動 `scripts/run-server.sh`，這個腳本會在程式缺少或源碼更新時重新編譯。`init-agents.sh` 也會印出 Claude Desktop 要用的設定（範本：[`examples/claude_desktop_config.json`](examples/claude_desktop_config.json)）。那個設定檔裡還有你其他的 server，所以請自行把它加進 `~/Library/Application Support/Claude/claude_desktop_config.json` 的 `mcpServers`，然後完全結束 Claude 再重開。

1. 在本專案目錄開始一個**新的本機** Claude Code 或 Codex 工作階段。
2. Claude Code 首次載入專案 MCP 時，請在它自己的介面中檢查並核准。Codex 需要信任此專案，才會載入 `.codex/config.toml`。
3. 在代理的 MCP 清單中確認 `mac-control` / `mac_control` 已連線，先呼叫 `mac_status`。
4. 對代理說明任務，例如：「用 mac-control 讀取目前畫面，點開 Finder，然後錄製 10 秒操作影片。」

這份設定只作用於此專案。若要在所有專案使用，可以把相同的本機 stdio 啟動命令加入使用者層級的 MCP 設定；不要同時保留相同名稱的重複設定。

若你想在其他專案也使用，在那些專案中自行執行以下命令即可（路徑換成你的 clone 位置）。這會變更各工具的使用者層級設定，本專案的設定檔不會自動幫你變更：

```sh
codex mcp add mac_control -- /bin/sh /path/to/mac-control-mcp/scripts/run-server.sh
claude mcp add --scope user --transport stdio mac-control -- /bin/sh /path/to/mac-control-mcp/scripts/run-server.sh
```

本專案的建置程序不會執行 Claude CLI；上方第二行只供你自行選用。

## macOS 權限

`mac_status` 會顯示 `screen_recording` 和 `accessibility`。若螢幕錄製未授權，請呼叫 `mac_request_screen_recording`，並在 macOS 的提示或「系統設定 → 隱私權與安全性 → 螢幕與系統音訊錄製」中授權。鍵盤、滑鼠和輔助使用元素需要「系統設定 → 隱私權與安全性 → 輔助使用」權限。macOS 可能要求重啟 Claude Code、Codex 或其宿主程式後權限才生效。

伺服器需要在**已登入的 Mac 桌面工作階段**執行。CI 和某些沙盒環境沒有圖形顯示器，因此測試只驗證 MCP 協定和輸入檢查，不會實際點擊或錄影。螢幕截圖及錄影會把畫面內容交給代理；請先關閉你不想分享的私人視窗。

## 操作方式

先呼叫 `mac_status`，然後 `mac_screenshot`。需要點擊時，使用截圖顯示的像素位置呼叫 `mac_mouse`。輸入文字使用 `mac_type_text`，快捷鍵使用 `mac_key`，例如 `{"key":"c","modifiers":["cmd"]}`。

錄影範例：呼叫 `mac_record_start` 並傳入 `{"duration_seconds":10}`，保存回傳的 `recording_id`；之後用 `mac_record_status` 查詢。狀態為 `ready` 時會回傳 MOV 檔絕對路徑。要提前結束可呼叫 `mac_record_stop`。若 macOS 尚未授權，錄影工具會回報缺少權限。
