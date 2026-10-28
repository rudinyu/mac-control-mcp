# 安裝

[English](INSTALL.md) | 繁體中文

大多數人建議直接使用 [MacControl.app](APP.zh-TW.md)，不需要編譯。這份指南說明如何從原始碼在你的 Mac 上安裝 mac-control-mcp，並連接 Claude Code、Claude Desktop 或 Codex。裝好之後請看[使用說明](USAGE.zh-TW.md)。

## 1. 需求

- macOS，並且已登入桌面工作階段。透過 SSH 或沒有畫面的工作階段執行時，伺服器看不到顯示器。
- Xcode Command Line Tools，裡面包含 Swift：`xcode-select --install`
- Python 3，用來跑測試。macOS 內建的 `/usr/bin/python3` 就夠了。
- 至少一個 MCP 客戶端：[Claude Code](https://claude.com/claude-code)、Claude Desktop 或 Codex。

## 2. 取得程式碼並建置

```sh
git clone https://github.com/rudinyu/mac-control-mcp.git
cd mac-control-mcp
sh scripts/ci.sh
```

`scripts/ci.sh` 會把伺服器編譯到 `.build/mac-control-mcp`，並跑完所有測試。測試不會點擊、輸入或錄影，隨時都可以安全執行。最後出現 `OK` 就代表建置成功。

之後不需要手動重新編譯。客戶端都是透過 `scripts/run-server.sh` 啟動伺服器，程式不存在或原始碼有更新時，它會自動重新編譯。

## 3. 產生客戶端設定

```sh
sh scripts/init-agents.sh
```

這會在專案根目錄產生下列檔案，並填入你 clone 的絕對路徑。已存在的檔案會保留，加上 `--force` 才會覆蓋。

| 檔案 | 客戶端 | 用途 |
| --- | --- | --- |
| `.mcp.json` | Claude Code | 為這個專案啟動伺服器（必要） |
| `CLAUDE.md` | Claude Code | 告訴 Claude 使用 mac-control 及使用方式（選用） |
| `.codex/config.toml` | Codex | 為這個專案啟動伺服器（必要） |
| `AGENTS.md` | Codex | 告訴 Codex 使用 mac-control 及使用方式（選用） |

這些檔案含有本機專屬的路徑，所以列在 `.gitignore`，不會被 commit。它們的範本在 [`examples/`](../examples/)，也可以手動複製。

腳本也會印出 Claude Desktop 的設定。Claude Desktop 的設定檔裡還有你其他的伺服器，所以腳本不會去改它。第 4 節說明怎麼加進去。

如果也想在 sandbox 裡執行指令和處理檔案，請依照 [mac-exec：在 sandbox 裡執行指令和處理檔案](EXEC.zh-TW.md#設定步驟) 設定 mac-exec。它需要 Docker。

## 4. 連接客戶端

### Claude Code

1. 在專案目錄開一個新的 Claude Code 工作階段：`claude`
2. 第一次載入時，Claude Code 會問你是否信任這個專案的 MCP 伺服器，請核准 `mac-control`。
3. 執行 `/mcp`，確認 `mac-control` 顯示為已連線。

如果想在所有專案都能用，而不只是這個專案，改成註冊到使用者層級。命令用到 `$PWD`，請在 clone 的根目錄執行：

```sh
claude mcp add --scope user --transport stdio mac-control -- /bin/sh "$PWD/scripts/run-server.sh"
```

不要同時保留專案層級和使用者層級的同名設定。

### Claude Desktop

1. 打開 `~/Library/Application Support/Claude/claude_desktop_config.json`。檔案不存在的話，先建立並寫入 `{"mcpServers": {}}`。
2. 把 `init-agents.sh` 印出的 `mac-control` 設定加進 `mcpServers` 裡，跟原本的伺服器放在一起：

   ```json
   "mac-control": {
     "command": "/bin/sh",
     "args": ["/absolute/path/to/mac-control-mcp/scripts/run-server.sh"]
   }
   ```

3. 用 ⌘Q 完全結束 Claude Desktop，再重新打開。

Claude Desktop 不會讀 `CLAUDE.md`。想給它同樣的規則，可以把 [`examples/CLAUDE.md`](../examples/CLAUDE.md) 的內容貼到專案的 instructions 裡。

### Codex

1. 在專案目錄啟動 Codex，被詢問時選擇信任這個專案。Codex 只會為已信任的專案讀取 `.codex/config.toml`。
2. 確認 `mac_control` 出現在 Codex 的 MCP 伺服器清單中。

如果想在所有專案都能用，請在 clone 的根目錄執行：

```sh
codex mcp add mac_control -- /bin/sh "$PWD/scripts/run-server.sh"
```

Codex 的伺服器名稱是底線 `mac_control`，Claude 客戶端用的是連字號 `mac-control`。

## 5. 授予 macOS 權限

macOS 的權限是給「負責伺服器的那個程序」。在終端機裡跑的程式由終端機 App 負責；Claude 等桌面 App 則以伺服器自己的名義啟動它，所以要給伺服器程式本身：

| 你使用的是 | 要授權的 App |
| --- | --- |
| 在終端機裡跑 Claude Code 或 Codex | 那個終端機 App，例如「終端機」或 iTerm2 |
| Claude Desktop 或 Codex 桌面 App | 伺服器本身：你 build 出來的 `mac-control-mcp`，或由 MacControl.app 設定時的 **MacControlHelper.app** |

到 **系統設定 → 隱私權與安全性**，在下面兩個項目都把該 App 打開：

- **輔助使用**（macOS 27 叫 **Device Control and Data Access**）：滑鼠、鍵盤、文字輸入和 UI 樹工具需要。
- **螢幕與系統音訊錄製**：截圖和螢幕錄影需要。

接著完全結束並重新打開那個 App。macOS 只會把權限套用到新啟動的程序。

## 6. 確認可以使用

對代理說：

> 呼叫 mac_status。

結果裡應該有 `"accessibility": true` 和 `"screen_recording": true`。有任何一個是 `false`，請再檢查第 5 節，並確認你重開的是剛剛授權的那個 App。也可以請代理呼叫 `mac_request_screen_recording`，它會跳出 macOS 的螢幕錄製權限提示。

再試一次截圖：

> 用 mac-control 截圖，告訴我畫面上有什麼。

## 7. 選用：每次 commit 前自動檢查

如果你打算修改程式碼，執行一次以下命令，啟用專案的 Git hook：

```sh
git config core.hooksPath .githooks
```

hook 會在每次 commit 前執行 `scripts/ci.sh`。如果有安裝 `codex-precommit-check` 和 `claude` CLI，也會執行 Claude code review；沒有安裝就略過。要在某次 commit 略過 review，可設定 `CODEX_SKIP_REVIEW=1`。

## 更新

```sh
git pull
```

下次客戶端啟動伺服器時，`run-server.sh` 會自動重新編譯。請重開客戶端，或在 Claude Code 用 `/mcp` 重新連線，才會載入新版。如果範本有更新，再執行 `sh scripts/init-agents.sh --force`。這會覆蓋產生的全部四個檔案，包括你對 `CLAUDE.md` 和 `AGENTS.md` 做的修改，請先跟 `examples/` 比對並備份你的修改。

## 移除

1. 移除客戶端的設定：
   - **Claude Code**：刪除 `.mcp.json`；如果是註冊在使用者層級，執行 `claude mcp remove --scope user mac-control`。
   - **Claude Desktop**：從 `claude_desktop_config.json` 刪除 `mac-control` 這一項，然後重開 Claude。
   - **Codex**：刪除 `.codex/config.toml`，或執行 `codex mcp remove mac_control`。
2. 視需要關掉第 5 節授予的權限。
3. 刪除 clone 的資料夾。錄影檔存在裡面的 `.build/recordings/`，會一起被刪除。

要移除 MacControl.app 和它的 sandbox，請見 [App 說明的「移除」](APP.zh-TW.md#移除)。
