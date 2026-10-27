# 使用說明

[English](USAGE.md) | 繁體中文

這份說明介紹代理如何透過 mac-control-mcp 操作你的 Mac，並列出每個工具和參數。請先依照[安裝指南](INSTALL.zh-TW.md)完成設定。

你通常不會自己呼叫這些工具，而是描述任務，讓代理選擇要用哪些工具。了解它們的運作方式，可以幫你寫出更好的指示，也比較看得懂錯誤訊息。

## 基本流程

1. **`mac_status`**：檢查權限，回報目前在前景的 App。
2. **`mac_screenshot`**：讓代理看到畫面。
3. **操作**：用 `mac_mouse` 點擊，用 `mac_type_text` 或 `mac_key` 輸入，或用 `mac_ui_tree` 讀取介面元素。
4. **再次 `mac_screenshot`**：確認結果，再進行下一步。

指示範例：

> 打開 TextEdit，新增一份文件，輸入「會議紀錄」。

> 截圖，告訴我目前開了哪些 App。

> 錄 15 秒的螢幕影片，同時打開 Finder 並切到「下載項目」。

## 避免大部分錯誤的兩條規則

**滑鼠座標以最新的截圖為準。** `mac_mouse` 使用最近一次 `mac_screenshot` 影像裡的像素位置。在 Retina 螢幕上，影像的像素通常是 `mac_status` 回報的螢幕尺寸的兩倍，例如 1920 × 1080 的螢幕會得到 3840 × 2160 的影像，伺服器會自動換算。請一律以截圖回報的尺寸為準。畫面有任何移動，或解析度改變之後，都要重新截圖。

**輸入時一定要指定目標 App。** 代理在終端機或 Claude Desktop 裡執行時，焦點常常會在兩次工具呼叫之間回到那個視窗。沒有指定目標的文字，就會打進代理自己的視窗。請在 `mac_type_text` 和 `mac_key` 加上 `app`。伺服器會先把該 App 切到前景，送出前再確認一次；如果焦點已經被其他 App 搶走，就什麼都不送。可以在指示裡加一句：

> 輸入時使用 `"app": "TextEdit"`。

## 工具參考

### `mac_status`

回報輔助使用和螢幕錄製權限、前景 App、螢幕尺寸、游標位置，以及上一張截圖的尺寸。沒有參數，也不會改變任何東西。每個工作階段都先呼叫它。

### `mac_screenshot`

把主螢幕擷取成 JPEG。影像尺寸就是下一次截圖之前 `mac_mouse` 使用的座標系。沒有參數，需要螢幕錄製權限。

### `mac_request_screen_recording`

跳出 macOS 的螢幕錄製權限提示。如果 `mac_status` 回報 `"screen_recording": false`，呼叫一次，授權後重開宿主 App。

### `mac_mouse`

| 參數 | 型別 | 說明 |
| --- | --- | --- |
| `action` | 字串，必填 | `move`、`click`、`double_click`、`right_click` 或 `drag` |
| `x`、`y` | 數字，必填 | 最新截圖裡的像素位置 |
| `to_x`、`to_y` | 數字 | 終點位置，`drag` 時必填 |

```json
{"action": "click", "x": 1039, "y": 2097}
{"action": "drag", "x": 400, "y": 300, "to_x": 900, "to_y": 300}
```

超出上一張截圖範圍的座標會被拒絕。還沒截過圖就呼叫 `mac_mouse` 會回報錯誤。

### `mac_scroll`

| 參數 | 型別 | 說明 |
| --- | --- | --- |
| `vertical` | 整數，-20 到 20 | 捲動行數；正數往上 |
| `horizontal` | 整數，-20 到 20 | 捲動行數；正數往左 |

它會在游標目前的位置捲動，所以要先用 `mac_mouse` 把游標移到目標上。至少要有一個值不是 0。

```json
{"vertical": -5}
```

### `mac_type_text`

| 參數 | 型別 | 說明 |
| --- | --- | --- |
| `text` | 字串，必填 | 1 到 2000 個字元；任何 Unicode 都可以，包括中文和 emoji |
| `app` | 字串 | 要輸入的執行中 App 名稱或 bundle ID，例如 `TextEdit` 或 `com.apple.TextEdit` |

```json
{"text": "測試中文 abc", "app": "TextEdit"}
```

文字是用貼上的方式輸入：伺服器把文字放到剪貼簿、按下 Command-V，再還原你原本的剪貼簿內容。所以用注音等輸入法時也能正常輸入，模擬按鍵就做不到。如果貼上期間有其他 App 改了剪貼簿，伺服器不會覆蓋那個變更。剪貼簿內容超過 40 MB，或無法完整保存時，會取消輸入，避免你的資料遺失。

結果會寫出收到文字的 App，例如 `Inserted 8 characters into TextEdit via Command-V.`

### `mac_key`

| 參數 | 型別 | 說明 |
| --- | --- | --- |
| `key` | 字串，必填 | `a`–`z`、`0`–`9`、`enter`/`return`、`tab`、`space`、`backspace`、`delete`、`escape`、`home`、`end`、`pageup`、`pagedown`、`left`、`right`、`up`、`down` |
| `modifiers` | 陣列 | `cmd`、`shift`、`alt`、`ctrl` 任意組合 |
| `app` | 字串 | 同 `mac_type_text` |

```json
{"key": "n", "modifiers": ["cmd"], "app": "TextEdit"}
{"key": "enter"}
```

不支援功能鍵、標點符號鍵和多媒體鍵。要輸入標點符號，請用 `mac_type_text`。

### `mac_ui_tree`

| 參數 | 型別 | 說明 |
| --- | --- | --- |
| `max_depth` | 整數，0 到 8 | 讀取深度；預設 5 |
| `app` | 字串 | 要讀取的 App；預設是前景 App |

以 JSON 回傳該 App 焦點視窗的輔助使用樹，包括每個元素的角色、標題、描述和值，以及目前取得鍵盤焦點的元素。可以用名稱找按鈕和欄位，不必靠像素位置。最多讀 200 個元素，每個值截到 200 個字元，碰到上限時會回報 `"truncated": true`。密碼欄位的內容一律不會回傳。指定 `app` 時只讀取，不會把該 App 切到前景。

```json
{"app": "TextEdit", "max_depth": 6}
```

### `mac_record_start`、`mac_record_status`、`mac_record_stop`

| 工具 | 參數 | 說明 |
| --- | --- | --- |
| `mac_record_start` | `duration_seconds`，整數，1 到 120，必填 | 開始錄製主螢幕，回傳 `recording_id` |
| `mac_record_status` | `recording_id`，必填 | 回報 `recording`、`ready` 或 `failed`；`ready` 時附上檔案路徑 |
| `mac_record_stop` | `recording_id`，必填 | 提前停止 |

一次只能有一個錄影。檔案是 QuickTime MOV，存在 clone 裡的 `.build/recordings/`，不含聲音。呼叫 `mac_record_stop` 之後，檔案可能要稍等一下，`mac_record_status` 才會回報 `ready`。

## 疑難排解

| 訊息或現象 | 處理方式 |
| --- | --- |
| `Accessibility permission is missing` 或 `Screen Recording permission is missing` | 把權限給啟動伺服器的那個 App，然後完全結束再重開它。見[安裝指南第 5 節](INSTALL.zh-TW.md#5-授予-macos-權限)。 |
| `No running app with a Dock icon matches "…"` | 先打開那個 App。只有有 Dock 圖示的 App 可以指定，名稱要完全相同（不分大小寫）。 |
| `"…" matches N running apps` | 有好幾個 App 同名。改用訊息裡列出的 bundle ID。 |
| `… has focus instead of …; no input was sent` | 送出前焦點被其他 App 搶走了，沒有輸入任何東西。請代理再試一次。 |
| `Could not determine which app has focus` | 輔助使用無法回報焦點所在的 App。請檢查輔助使用權限。 |
| `Call mac_screenshot before mac_mouse` 或座標被拒絕 | 先截圖，並使用那張截圖的座標。 |
| 點擊位置不對 | 截圖之後畫面變了。重新截圖。 |
| 文字出現在代理自己的視窗 | 沒有指定 `app`。輸入時一定要指定。 |
| 客戶端裡看不到這些工具 | 重開客戶端，再檢查設定裡的伺服器路徑。在 Claude Code 可以執行 `/mcp`。 |

## 隱私與安全

- 截圖、錄影和 UI 樹的內容，會把你畫面上的東西傳給代理使用的模型。請先關閉私人視窗。
- `mac_type_text` 會把文字短暫放到系統剪貼簿，剪貼簿紀錄工具，以及你其他裝置上的「通用剪貼板」都可能取得這些內容。不要讓代理輸入密碼或其他機密資料。
- 錄影檔會留在 clone 裡的 `.build/recordings/`，直到你刪除為止。不需要的錄影請刪掉。
- 伺服器只會讀取和操作你的桌面。它不開網路埠、不執行任意 shell 指令，只跟啟動它的客戶端溝通。
- 代理能點擊和輸入任何你能操作的東西。請保持客戶端的核准提示開啟，購買、刪除或送出訊息前，不要讓它在你沒確認的情況下執行。
