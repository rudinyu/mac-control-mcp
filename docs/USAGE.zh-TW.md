# 使用說明

[English](USAGE.md) | 繁體中文

這份說明介紹代理如何透過 mac-control-mcp 操作你的 Mac，並列出每個工具和參數。請先依照[安裝指南](INSTALL.zh-TW.md)完成設定。

你通常不會自己呼叫這些工具，而是描述任務，讓代理選擇要用哪些工具。了解它們的運作方式，可以幫你寫出更好的指示，也比較看得懂錯誤訊息。

## 基本流程

1. **`mac_status`**：檢查權限，回報目前在前景的 App。
2. **`mac_screenshot`**：讓代理看到畫面。
3. **操作**：用 `mac_mouse` 點擊，用 `mac_type_text` 或 `mac_key` 輸入，或用 `mac_ui_tree` 讀取介面元素，再用 `mac_ax_action` 依 ref 操作。
4. **再次 `mac_screenshot`**：確認結果，再進行下一步。

指示範例：

> 打開 TextEdit，新增一份文件，輸入「會議紀錄」。

> 截圖，告訴我目前開了哪些 App。

> 錄 15 秒的螢幕影片，同時打開 Finder 並切到「下載項目」。

## 避免大部分錯誤的兩條規則

**滑鼠座標以最新的截圖為準。** `mac_mouse` 使用最近一次 `mac_screenshot` 影像裡的像素位置。在 Retina 螢幕上，影像的像素通常是 `mac_status` 回報的螢幕尺寸的兩倍，例如 1920 × 1080 的螢幕會得到 3840 × 2160 的影像，伺服器會自動換算。請一律以截圖回報的尺寸為準。畫面有任何移動，或解析度改變之後，都要重新截圖。

**一定要指定目標 App。** 代理在終端機或 Claude Desktop 裡執行時，焦點常常會在兩次工具呼叫之間回到那個視窗。沒有指定目標的輸入，就會送進代理自己的視窗，或剛好跑到前景的 App。請在 `mac_screenshot`、`mac_mouse`、`mac_scroll`、`mac_type_text` 和 `mac_key` 加上 `app`。伺服器會先把該 App 切到前景，送出前再確認一次；如果焦點已經被其他 App 搶走，就什麼都不送。`mac_mouse` 另外會檢查：上一張截圖不是在該 App 位於前景時拍的，或它的視窗之後移動或改變了大小，或那個位置上是其他 App（例如蓋在上面的視窗、Dock 或選單列圖示），就不點擊。`mac_scroll` 在游標位於其他 App 上時不會捲動。有些面板（例如沙盒 App 的「打開」和「儲存」）在另一個程序裡執行；要點擊這種面板時，那一次點擊不要加 `app`。可以在指示裡加一句：

> 每個 mac-control 工具都使用 `"app": "TextEdit"`。

## 工具參考

### `mac_status`

回報輔助使用和螢幕錄製權限、螢幕是否鎖定（`screen_locked` 和 `screen_locked_reason`）、前景 App、螢幕尺寸、游標位置，以及上一張截圖的尺寸。沒有參數，也不會改變任何東西。每個工作階段都先呼叫它。

### `mac_screenshot`

把主螢幕擷取成 JPEG。影像尺寸就是下一次截圖之前 `mac_mouse` 使用的座標系。需要螢幕錄製權限。

| 參數 | 型別 | 說明 |
| --- | --- | --- |
| `app` | 字串 | 截圖前要切到前景的 App，用法同 `mac_type_text`。也會把它的視窗從「幕前調度」側邊帶回來；沒有開啟視窗的 App 可能會開一個新視窗。需要輔助使用權限。 |

### `mac_request_screen_recording`

跳出 macOS 的螢幕錄製權限提示。如果 `mac_status` 回報 `"screen_recording": false`，呼叫一次，授權後重開宿主 App。

### `mac_mouse`

| 參數 | 型別 | 說明 |
| --- | --- | --- |
| `action` | 字串，必填 | `move`、`click`、`double_click`、`right_click` 或 `drag` |
| `x`、`y` | 數字，必填 | 最新截圖裡的像素位置 |
| `to_x`、`to_y` | 數字 | 終點位置，`drag` 時必填 |
| `app` | 字串 | 要點擊的 App。請先用同一個 `app` 截圖。 |

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
| `app` | 字串 | 先切到前景的 App，用法同 `mac_type_text` |

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
| `root` | 字串 | 改從這個 ref 往下讀，而不是焦點視窗 |
| `app` | 字串 | 要讀取的 App；預設是前景 App |

以 JSON 回傳該 App 焦點視窗的輔助使用樹，包括每個元素的角色、標題、描述和值，以及目前取得鍵盤焦點的元素。可以用名稱找按鈕和欄位，不必靠像素位置。最多讀 200 個元素、最多 5 秒，每個值截到 200 個字元。密碼欄位的內容一律不會回傳。指定 `app` 時只讀取，不會把該 App 切到前景。

可以操作的元素另外會有 `ref`（例如 `"ref": "k3f9q2.12"`）和 `actions`，也就是它支援的 `mac_ax_action` 動作。子元素沒有全部列出的元素，會顯示 `more_children`（沒有列出的數量），也會有 `ref`；把這個 ref 當作 `root` 傳入，就能往下讀。原因有兩種：你指定的 `max_depth`，以及讀取提早停止。ref 由快照 ID、一個點和元素在該快照中的編號組成；結果的 `snapshot` 欄位就是快照 ID。同一個 App 重新讀取整棵樹時會開始新的快照，該 App 先前的 ref 全部失效；用 `root` 往下讀、`mac_find`、`mac_wait` 和 `mac_window list` 則把 ref 加進目前的快照，原有的 ref 仍然有效。快照 ID 是隨機產生的，所以 mac-control 重新啟動前留下的 ref 會被拒絕，不會誤指到別的元素。視窗很大時，先用較小的 `max_depth` 讀概況，再往下展開。

結果會說明讀取是否提早停止：

| 欄位 | 意義 |
| --- | --- |
| `complete` | 讀完 `max_depth` 以內的所有元素時為 `true`。只因 `max_depth` 而沒有列出的元素不會讓它變成 `false`。 |
| `truncated` | 讀取提早停止時為 `true` |
| `stopped_by` | 停止的原因：`element_limit`（200 個元素）、`time_limit`（5 秒）或 `app_not_answering`；沒有提早停止時為 `null` |
| `elements_read` | 讀了多少個元素 |
| `unanswered` | App 在 2 秒內沒有回應的元素數，每個都標示 `"unanswered": true` |

App 停止回應時（例如忙碌或當掉），讀取會在那裡停止，不會對剩下的每個元素都等待逾時。已經讀到的元素會保留。從那之後，元素不再列出 `actions`，但子元素沒有全部列出的元素仍然有 `ref`，等 App 恢復回應後可以往下讀。

```json
{"app": "TextEdit", "max_depth": 6}
{"app": "Slack", "max_depth": 2}
{"app": "Slack", "root": "p8w2kd.7", "max_depth": 6}
```

### `mac_find`

| 參數 | 型別 | 說明 |
| --- | --- | --- |
| `role` | 字串 | 例如 `button` 或 `AXTextField`；`AX` 前綴和大小寫都不影響 |
| `text` | 字串 | 比對標題、描述或值，不分大小寫和重音符號 |
| `exact` | 布林值 | 比對完整文字，而不是部分文字 |
| `limit` | 整數，1 到 50 | 最多回傳幾個結果；預設 20 |
| `root` | 字串 | 改在這個 ref 底下搜尋，而不是 App 的所有視窗 |
| `app` | 字串 | 要搜尋的 App；預設是前景 App |

至少要給 `role` 或 `text`。依螢幕閱讀器的順序搜尋 App 的每個視窗（焦點視窗優先），最多 5000 個元素、40 層、5 秒，比 `mac_ui_tree` 讀得深很多。結果附有 `ref` 和 `actions`，可以直接用於 `mac_ax_action`，而且 App 原有的 ref 仍然有效。結果的 `snapshot` 是這些 ref 所屬的快照。`"complete": false` 表示搜尋被截斷，請用 `root` 縮小範圍。不會搜尋選單列裡的選單。密碼欄位的內容一律不會比對或回傳。

```json
{"app": "TextEdit", "role": "button", "text": "Save"}
```

### `mac_wait`

| 參數 | 型別 | 說明 |
| --- | --- | --- |
| `role`、`text`、`exact`、`root`、`app` | | 與 `mac_find` 相同 |
| `state` | `present` 或 `absent` | 等到符合的元素出現（預設），或等到全部消失 |
| `timeout_seconds` | 數字，0.5 到 30 | 最多等多久；預設 10 |

大約每秒檢查四次，每次都重新查詢 App 的視窗，所以在新視窗開啟的對話框也找得到。`present` 會在元素一出現時就回傳結果和 ref。`absent` 要等到完整搜尋都找不到才回傳。時間到了就以 `TIMEOUT` 失敗。動作之後用它來等，例如等表單出現或進度指示消失，不必一直重讀 `mac_ui_tree`。

```json
{"app": "TextEdit", "role": "sheet", "timeout_seconds": 5}
{"app": "Safari", "role": "progressindicator", "state": "absent", "timeout_seconds": 20}
```

### `mac_window`

| 參數 | 型別 | 說明 |
| --- | --- | --- |
| `action` | 字串，必填 | `list`、`focus`、`move`、`resize`、`minimize` 或 `restore` |
| `window` | 字串 | 來自 `list`、`mac_find` 或 `mac_ui_tree` 的視窗 ref |
| `x`、`y` | 數字 | `move` 用：新的左上角位置 |
| `width`、`height` | 數字 | `resize` 用 |
| `app` | 字串 | `list` 時是要列出的 App；其他動作沒有給 `window` 時，操作這個 App 的焦點視窗 |

`list` 回傳每個視窗的 App、標題、`frame`、`minimized`、`main`、`focused` 和 `ref`。沒有給 `app` 時，列出所有有 Dock 圖示的 App 的視窗，最多 100 個。座標單位是螢幕的點，也就是 `mac_status` 裡 `main_display` 的單位，不是 `mac_screenshot` 的像素。

`focus` 會還原最小化的視窗、把它移到最上層，並把它的 App 切到前景。`move` 和 `resize` 會回傳視窗和 `as_requested`；App 把視窗放到或調成不同的位置或大小時（例如為了留在螢幕內），它是 `false`。大小固定的視窗會以 `ACTION_UNSUPPORTED` 拒絕。視窗已經是要求的狀態時，`minimize` 和 `restore` 不會送出任何東西。開啟「幕前調度」（Stage Manager）時，macOS 可能會忽略這兩個動作，工具會回報 `OUTCOME_UNKNOWN`。

```json
{"action": "list", "app": "TextEdit"}
{"action": "move", "window": "m4c7tj.2", "x": 0, "y": 25}
{"action": "resize", "app": "TextEdit", "width": 900, "height": 700}
```

### `mac_ax_action`

| 參數 | 型別 | 說明 |
| --- | --- | --- |
| `ref` | 字串，必填 | 來自 `mac_ui_tree`、`mac_find` 或 `mac_wait`，而且對該 App 仍然有效的 ref |
| `action` | 字串，必填 | `press`、`show_menu`、`increment`、`decrement`、`confirm`、`cancel`、`raise`、`scroll_to_visible`、`set_value`、`focus`、`select`、`deselect`、`expand`、`collapse`、`check` 或 `uncheck` |
| `value` | 字串，最多 2000 個字元 | `set_value` 要設定的文字；其他動作不能使用 |
| `app` | 字串 | 如果指定，必須是 ref 所屬的 App |

透過輔助使用直接操作元素，所以不需要座標，不會移動游標，不會把 App 切到前景，也不會使用剪貼簿。送出前會確認 App 沒有結束或重新開啟、元素仍然存在且角色相同，而且仍支援該動作。密碼欄位不能設定。`select` 和 `deselect` 設定列或項目是否被選取；`expand` 和 `collapse` 展開或收合大綱列或展開三角形；`check` 和 `uncheck` 只在核取方塊不是要求的狀態時才按下它。這四組動作在元素已經是要求的狀態時不會送出任何東西。`scroll_to_visible` 會把元素捲動到可見範圍，主要由網頁內容提供。對存放數字的元素（例如滑桿或步進器），`set_value` 會送出數字，有限十進位數字以外的值會被拒絕。

送出後，只要元素上有東西可讀，就會讀回來確認：

| 動作 | 讀回什麼 | 不符合時 |
| --- | --- | --- |
| `select`、`deselect`、`expand`、`collapse`、`check`、`uncheck` | 狀態屬性，例如 `AXSelected` | `OUTCOME_UNKNOWN` |
| `focus` | `AXFocused` | 讀到 false 時為 `OUTCOME_UNKNOWN`；元素不回報焦點時（部分網頁元素如此）不算已確認 |
| 文字的 `set_value` | `AXValue` 顯示新文字 | `OUTCOME_UNKNOWN`；許多網頁欄位需要改用 `mac_type_text` |
| 數字的 `set_value` | `AXValue` 等於該數字 | 不算已確認，因為滑桿可能四捨五入到刻度 |
| `increment`、`decrement` | `AXValue` 變大或變小 | 不算已確認，因為元素可能已經到上限或下限 |
| `press`、`show_menu`、`confirm`、`cancel`、`raise`、`scroll_to_visible` | 無；這些動作不會在元素上留下狀態 | 一律不算已確認 |

成功的結果和錯誤一樣有兩段文字：一段訊息，以及說明確認了什麼的 JSON。讀回的值不會出現在結果裡，因為它可能是私人內容：

```json
{"result": {"delivered": true, "verified": true, "checked": "AXSelected"}}
```

元素已經是要求的狀態而沒有送出任何東西時，`delivered` 是 false。只有讀回 `checked` 所列的屬性而且符合時，`verified` 才是 true；是 false 時，請讀 `mac_ui_tree` 查看結果。

```json
{"ref": "k3f9q2.12", "action": "press", "app": "Calculator"}
{"ref": "h5r1zb.4", "action": "set_value", "value": "Meeting notes", "app": "TextEdit"}
```

### `mac_record_start`、`mac_record_status`、`mac_record_stop`

| 工具 | 參數 | 說明 |
| --- | --- | --- |
| `mac_record_start` | `duration_seconds`，整數，1 到 120，必填 | 開始錄製主螢幕，回傳 `recording_id` |
| `mac_record_status` | `recording_id`，必填 | 回報 `recording`、`ready` 或 `failed`；`ready` 時附上檔案路徑 |
| `mac_record_stop` | `recording_id`，必填 | 提前停止 |

一次只能有一個錄影。檔案是 QuickTime MOV，使用 MacControl.app 時存在 `~/Movies/MacControl/`，從原始碼建置時存在 clone 裡的 `.build/recordings/`。只有你的帳號能開啟這個資料夾。錄影不含聲音。呼叫 `mac_record_stop` 之後，檔案可能要稍等一下，`mac_record_status` 才會回報 `ready`。

## 錯誤結果

工具失敗時，結果有兩段文字：一段是給人看的訊息，另一段是給代理讀的 JSON：

```json
{"error": {"code": "STALE_REF", "delivered": false, "retry": "refresh"}}
```

`delivered` 為 `false` 表示沒有任何東西送到 App；為 `"unknown"` 表示動作已送出但沒有得到確認。`retry` 說明下一步：

| `retry` | 意思 | 錯誤碼 |
| --- | --- | --- |
| `fix` | 修改參數或參數指的對象，例如先打開 App | `INVALID_ARGS`、`APP_NOT_FOUND`、`APP_AMBIGUOUS`、`ACTION_UNSUPPORTED` |
| `refresh` | 重新執行 `mac_screenshot` 或 `mac_ui_tree`，改用新的座標或 ref | `STALE_SCREENSHOT`、`STALE_REF` |
| `safe` | 可以原樣再呼叫一次 | `FOCUS_LOST`、`APP_UNRESPONSIVE`、`BUSY`、`INTERNAL`、`TIMEOUT` |
| `user` | 需要使用者處理：授予權限、解鎖 Mac 或修正設定 | `PERMISSION_DENIED`、`SCREEN_LOCKED`、`SETUP_PROBLEM`、`CLIPBOARD_UNSAFE` |
| `check` | 動作可能已經發生；先確認再決定要不要重做 | `OUTCOME_UNKNOWN` |

## 疑難排解

| 訊息或現象 | 處理方式 |
| --- | --- |
| `Accessibility permission is missing` 或 `Screen Recording permission is missing` | 把權限給終端機 App；Claude Desktop 和 Codex App 則給 MacControlHelper.app。然後完全結束再重開那個 App。見[安裝指南第 5 節](INSTALL.zh-TW.md#5-授予-macos-權限)。 |
| `No running app with a Dock icon matches "…"` | 先打開那個 App。只有有 Dock 圖示的 App 可以指定，名稱要完全相同（不分大小寫）。 |
| `"…" matches N running apps` | 有好幾個 App 同名。改用訊息裡列出的 bundle ID。 |
| `… has focus instead of …; no input was sent` | 送出前焦點被其他 App 搶走了，沒有輸入任何東西。請代理再試一次。 |
| `The screen is locked` | Mac 鎖定，或其他使用者正在使用螢幕時，輸入會送到登入視窗，所以工具會拒絕送出。請先解鎖，再請代理繼續。截圖仍可使用，但只會拍到鎖定畫面。 |
| `Could not determine which app has focus` | 輔助使用無法回報焦點所在的 App。請檢查輔助使用權限。 |
| `Call mac_screenshot before mac_mouse` 或座標被拒絕 | 先截圖，並使用那張截圖的座標。 |
| `… was not steadily in front for the last mac_screenshot`、`… window moved, resized, or changed` 或 `… is not over …` | 沒有點擊任何東西。用同一個 `app` 重新截圖，再用新截圖的座標點擊。 |
| `Unknown or expired ref`、`Expired ref … was replaced by snapshot …`、`… no longer exists or has changed` 或 `… has quit or relaunched since mac_ui_tree` | 沒有送出任何動作。重新讀取 `mac_ui_tree`，改用新的 ref。 |
| `… is not a ref` | 這個值不是 ref 的格式（例如 `k3f9q2.12`）；舊版 mac-control 的 ref 長得像 `3.12`，已經不能用。重新讀取 `mac_ui_tree`，改用其中的 ref。 |
| `… may or may not have happened` | App 沒有確認動作是否完成。先讀取 `mac_ui_tree` 確認，再決定要不要重試。 |
| 點擊位置不對 | 截圖之後畫面變了。重新截圖，並指定 `app`，讓伺服器可以檢查。 |
| 文字或點擊跑到代理自己的視窗或其他 App | 沒有指定 `app`。一定要指定。 |
| 客戶端裡看不到這些工具 | 重開客戶端，再檢查設定裡的伺服器路徑。在 Claude Code 可以執行 `/mcp`。 |

## 隱私與安全

- 截圖、錄影和 UI 樹的內容，會把你畫面上的東西傳給代理使用的模型。請先關閉私人視窗。
- `mac_type_text` 會把文字短暫放到系統剪貼簿，剪貼簿紀錄工具，以及你其他裝置上的「通用剪貼板」都可能取得這些內容。不要讓代理輸入密碼或其他機密資料。
- 錄影檔會留在 `~/Movies/MacControl/` 或 `.build/recordings/`，直到你刪除為止。不需要的錄影請刪掉。
- 伺服器只會讀取和操作你的桌面。它不開網路埠、不執行任意 shell 指令，只跟啟動它的客戶端溝通。
- 代理能點擊和輸入任何你能操作的東西。請保持客戶端的核准提示開啟，購買、刪除或送出訊息前，不要讓它在你沒確認的情況下執行。
