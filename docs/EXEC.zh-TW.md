# mac-exec：在 sandbox 裡執行指令和處理檔案

[English](EXEC.md) | 繁體中文

`mac-exec` 是這個 repo 裡的第二個 MCP 伺服器，讓代理可以執行指令、安裝套件、讀寫檔案。預設所有東西都在隔離的 Linux 容器裡執行，就算指令有誤或是惡意的，也碰不到你 Mac 的其他部分。它跟 `mac-control` 是分開的，客戶端會要你分別核准，兩個也可以只用其中一個。

## 它怎麼保護你的 Mac

| 保護措施 | 說明 |
| --- | --- |
| 每個指令一個新容器 | 每次 `sandbox_exec` 都會開一個新容器，跑完就刪掉。除了工作資料夾裡的檔案，什麼都不會留下。 |
| 只共用工作資料夾 | 工作資料夾（預設 `~/AgentWorkspace`）是容器唯一能寫入的 Mac 資料夾，在容器裡是 `/workspace`。你的家目錄、SSH key、鑰匙圈和瀏覽器資料都看不到。 |
| 拒絕敏感資料夾 | 工作資料夾和唯讀資料夾不能是、不能包含，也不能位於 `~/.ssh`、`~/.gnupg`、`~/.aws`、`~/.config`、`~/Library`、`~/.zshrc` 這類 shell 啟動檔、`~/.claude` 和 `~/.codex` 這類代理設定等位置之內，也不能跟這個專案重疊，因為專案裡的腳本會在 Mac 上執行。同樣的理由，也不能共用整個家目錄。 |
| 不是 root、沒有特權 | 指令以使用者 `agent`（uid 1000）執行，拿掉所有 Linux capability，並開啟 `no-new-privileges`，所以無法變成 root。 |
| 系統唯讀 | 容器的系統檔案是唯讀的。只有 `/workspace`、`/tmp` 和家目錄 `/home/agent` 可以寫入，後兩者在指令結束後就會清掉。 |
| 資源限制 | 每個指令最多 2 GB 記憶體、2 顆 CPU、256 個程序；逾時預設 120 秒，最多 600 秒。跑太久的指令會連同容器一起被終止；`host_exec` 則會終止指令啟動的所有程序。 |
| 稽核紀錄 | 每個指令在執行前都會寫進 `~/Library/Logs/mac-exec/audit.log`，執行完再記下結果。紀錄寫不進去，指令就不會執行。 |
| 核准提示 | 執行指令和寫入檔案的工具都標記為破壞性。客戶端會不會每次都先問你，取決於它的權限設定：請保持 Claude Code 的核准提示開啟，Codex 則保留 `default_tools_approval_mode = "prompt"`。`sandbox_write_file` 會覆蓋工作資料夾裡的檔案。 |
| 預設不能直接在 Mac 上執行 | 直接在 Mac 上執行指令的 `host_exec`，只有在你開啟後才會出現。每次呼叫都要寫理由，並拒絕 `sudo`、`su` 和 `doas`。 |

容器可以正常上網，所以能下載套件、呼叫網路 API。它也能透過 Docker 的網路連到你的 Mac 和區網，例如 `host.docker.internal` 或你的路由器。如果這對你很重要，就不要在 Mac 或區網上開著不需要密碼就能連的服務。

## 設定步驟

1. 安裝並啟動 [Docker Desktop](https://www.docker.com/products/docker-desktop/)，或其他提供 `docker` 命令的相容工具，例如 Colima 或 OrbStack。
2. 建置一次 sandbox 映像檔：

   ```sh
   sh scripts/build-sandbox.sh
   ```

   `sandbox/Dockerfile` 有修改時要再跑一次。映像檔以 Debian 為基礎，內含 bash、Python 3、Node.js、git、curl 和 jq。安裝 Python 套件請用 `pip install --user`，或在 `/workspace` 底下建立虛擬環境；裝在哪裡，就只保留到那個位置被清掉為止。
3. 執行 `sh scripts/init-agents.sh`。產生的 `.mcp.json`、`.codex/config.toml` 和 Claude Desktop 設定，都會在 `mac-control` 旁邊加上 `mac-exec`。如果之前已經產生過這些檔案，請從 [`examples/`](../examples/) 手動合併 `mac-exec` 的設定，或加上 `--force` 重新產生。
4. 重開客戶端，請它呼叫 `exec_status`，應該會看到 `"docker_running": true` 和 `"image_present": true`。

## 設定值

寫在客戶端設定裡這個伺服器的 `env` 區塊。

| 變數 | 預設值 | 說明 |
| --- | --- | --- |
| `MAC_EXEC_WORKSPACE` | `~/AgentWorkspace` | 以可讀寫方式共用、在容器裡是 `/workspace` 的資料夾。不存在會自動建立。 |
| `MAC_EXEC_READONLY_DIRS` | 無 | 額外以唯讀方式共用的資料夾，用 `:` 分隔。每個會出現在 `/mnt/readonly/<資料夾名稱>`。 |
| `MAC_EXEC_ALLOW_HOST` | 關閉 | 設成 `1` 才會出現 `host_exec`。 |
| `MAC_EXEC_IMAGE` | `mac-exec-sandbox:latest` | 要執行的 Docker 映像檔。 |
| `MAC_EXEC_DOCKER` | 自動尋找 | `docker` 程式的路徑，如果它不在常見的位置。 |
| `MAC_EXEC_AUDIT_LOG` | `~/Library/Logs/mac-exec/audit.log` | 指令紀錄的位置。 |

`.mcp.json` 範例：唯讀共用一個專案資料夾，並開啟 `host_exec`：

```json
"mac-exec": {
  "type": "stdio",
  "command": "/bin/sh",
  "args": ["/path/to/mac-control-mcp/scripts/run-exec-server.sh"],
  "env": {
    "MAC_EXEC_WORKSPACE": "~/AgentWorkspace",
    "MAC_EXEC_READONLY_DIRS": "~/Documents/reports",
    "MAC_EXEC_ALLOW_HOST": "1"
  }
}
```

## 工具

| 工具 | 參數 | 功能 |
| --- | --- | --- |
| `exec_status` | 無 | 回報 Docker、映像檔、工作資料夾、唯讀資料夾、`host_exec` 是否開啟，以及設定上的問題。 |
| `sandbox_exec` | `command`（必填）、`cwd`、`timeout_seconds`（1–600，預設 120） | 在新容器裡執行 `bash -c command`。`cwd` 是相對於工作資料夾的路徑。回傳 `exit_code`、`stdout`、`stderr`（各截到 100 KB）、`timed_out` 和 `duration_ms`。 |
| `sandbox_read_file` | `path`（必填）、`max_bytes`（最多 1 MB，預設 200 KB） | 讀取工作資料夾裡的 UTF-8 文字檔。 |
| `sandbox_write_file` | `path`、`content`（必填）、`append` | 在工作資料夾建立或取代文字檔，最多 1 MB，需要時會自動建立資料夾。 |
| `sandbox_list` | `path` | 列出工作資料夾裡的資料夾內容，最多 500 項。 |
| `host_exec` | `command`、`reason`（必填）、`cwd`、`timeout_seconds` | 只在 `MAC_EXEC_ALLOW_HOST=1` 時出現。用你的權限在 Mac 上執行 `zsh -lc command`。 |

檔案工具的路徑可以是相對路徑，例如 `notes/a.txt`，也可以用 `/workspace/` 開頭。任何解析後落在工作資料夾外的路徑，包括經由符號連結的，一律拒絕。

指示範例：

> 用 mac-exec 把這個網址的 CSV 下載到工作資料夾，用 Python 整理出摘要。

> 在 sandbox 裡把這個 repo clone 到 /workspace，跑它的測試。

## 什麼時候用 host_exec

sandbox 是 Linux，不能執行 `open`、`osascript`、`defaults` 或 Xcode 工具這類 macOS 程式，也看不到工作資料夾以外的檔案。遇到這些情況，可以用唯讀方式共用資料夾，或開啟 `host_exec`。

`host_exec` 擁有你全部的權限。`sudo` 檢查只是方便，不是安全防線：真正保護你的，是在核准提示裡看清楚每個指令再允許。不需要時請保持 `MAC_EXEC_ALLOW_HOST` 關閉，也不要核准你沒預期到的 `host_exec`，尤其是在代理讀過網頁或別人給的文件之後。

## 疑難排解

| 訊息 | 處理方式 |
| --- | --- |
| `Docker was not found` | 安裝 Docker Desktop，或設定 `MAC_EXEC_DOCKER`。 |
| `exec_status` 顯示 `docker_running: false` | 啟動 Docker Desktop，等它準備好。 |
| `The sandbox image … is missing` | 執行 `sh scripts/build-sandbox.sh`。 |
| `MAC_EXEC_WORKSPACE cannot be used` | 工作資料夾是、包含或位於敏感資料夾之內。請換一個資料夾。 |
| `… must stay inside the workspace` | 路徑指到工作資料夾外面。請用相對路徑，或以 `/workspace/` 開頭的路徑。 |
| `Could not write the audit log` | 確認 `~/Library/Logs/mac-exec` 可以寫入，或設定 `MAC_EXEC_AUDIT_LOG`。 |
| Codex 跑長指令到 30 秒就被停掉 | 把 `mac_exec` 的 `tool_timeout_sec` 調高；範例用的是 620。 |
