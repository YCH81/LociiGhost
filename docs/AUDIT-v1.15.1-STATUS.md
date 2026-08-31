# 全檢修正進度 — 分支 `audit-fixes`

基準 `cbbbc8d` (v1.15.1) + 兩個未提交的 v1.15.2 Phase 1 檔案。
原始清單見 `AUDIT-v1.15.1.md`；本檔記錄每一項的實際處置。

## 驗證狀態

| 檢查 | 指令 | 最後結果 |
|---|---|---|
| Swift 編譯 | `cd App && xcrun swift build --product LociiGhost` | ✅ exit 0（全部階段） |
| Swift 測試 | `cd App && xcrun swift test` | ✅ 52 + 2 passed |
| Daemon 煙霧測試 | 真的啟動 lociighostd 再打它的 RPC 與 HTTP 介面 | ✅ 21/21 |
| Daemon 測試 | `cd Daemon && .venv/bin/python -m pytest tests -q` | ✅ 107 passed |

**全部階段都已在 Frankie 的 Mac 上以 Xcode 工具鏈編譯並測試通過。**
唯一剩下的 warning 全是既有的（`MapContainerView` 的 `MKAnnotationView`
conditional downcast、`StartRouteSheet` 的 deprecated `onChange`），沒有一個
來自這批修正。

煙霧測試那一項特別值得留意：測試套件用的是 FastAPI TestClient 與 mock，
所以在那之前 **daemon 從來沒有真的被啟動過**。實跑之後確認 X4 的配對視窗與
每 IP 鎖定、X5 的 Host/Origin 阻擋、X6 的換 PIN、X10 的邊界（含 JSON
`Infinity` 回 422 而非 500）在真的 uvicorn 與真的 unix socket 上都成立。

### 沒有編譯器時做過的替代驗證

Swift 工具鏈在 Mac 鎖屏期間無法使用（雲端容器也裝不了，`download.swift.org`
被 egress 擋掉）。以下三項改用「把邏輯搬出來實際跑」的方式驗證，各自抓到
真正的缺陷：

| 對象 | 方法 | 結果 |
|---|---|---|
| `S2Grid` L15/L16 | 把投影數學原樣移植成 Python 再比對新舊行為 | level 12 的 40 個面邊界格，**舊版有 19 個把自己當鄰居**，新版 0 個；全部 40 個都能到達另一個 cube face；既有 5 項測試與新增 2 項在移植版上全過 |
| 特權 bootstrap 腳本 | 從 Swift 字串literal 抽出、代入插值、`bash -n` + 逐分支實跑 | 抓到 3 個缺陷（見 commit `1e1d681`）；修好後 stat 讀不到→96、group-writable→92、symlink→91、缺檔→90，X3 的 symlink 攻擊目標檔案原封不動 |
| `phone.html` X15 | `node --check` + 以會跳脫的 DOM stub 比對新舊 render | 舊版 `innerHTML` 注入出可執行的 `<img onerror=…>`，新版輸出 `&lt;img …&gt;` 純文字，且 mode pill 仍正常 |

這幾輪加上重讀與實跑，總共在**我自己寫的修正裡**找到 9 個缺陷：

| # | 在哪 | 怎麼找到的 |
|---|---|---|
| 1 | L8 `applyRunnerState` 的 `AnyCodable` cast 永遠取不到值 | 重讀 |
| 2 | P2 後備變數撞上 `@Observable` 巨集的儲存名稱 | 重讀 |
| 3 | X1 特權腳本沒有固定 `PATH` | 抽出腳本實跑 |
| 4 | X1 `stat` 失敗時訊息說謊、空值讓算式語法錯誤 | 抽出腳本實跑 |
| 5 | X1 一處路徑放在雙引號 shell 字串裡會被展開 | 抽出腳本實跑 |
| 6 | X15 的 DOM stub 沒模擬跳脫（測試本身無效） | 實跑 |
| 7 | P3 黏著的 bool 在 callback 沒觸發時會吞掉下一次真實 pan | diff 自審 |
| 8 | P9 遮蔽偵測的條件正好排除它要處理的情境 | diff 自審 |
| 9 | W6 的 task 沒保留強參考，可能被 GC 掉 | diff 自審 |

九個裡有五個是編譯器與測試都看不見的。

---

## 逐項處置

### Phase 1 — 一行改動
- ✅ **X6** `rotate()` → `rotate_pin()` + `clear_all()`；Swift 端檢查 statusCode
- ✅ **W1** `_RECOVERABLE` 加入 `PyMobileDevice3Exception`
- ✅ **P1** `dwellLog` 改 `#if DEBUG` + `@autoclosure`
- ✅ **P13** 兩個 `@ObservationIgnored`
- ✅ **L2** 五處 `_emit` 補 `state`（用 `stopped` 而非 `idle`）

### Phase 2 — 連線穩定度
- ✅ **W2** `_reconnect()` 透過 `on_provider_replaced` 回寫 `sess.dvt_provider`
- ✅ **W3** keepalive 遇到 `_call_lock.locked()` 直接跳過該拍
- ✅ **W4** `set(retries=)`；keepalive 傳 0；`_stop_movers` 有 2 秒上限
- ✅ **W5** 存活判斷改用 keepalive 連續失敗數（degraded 9s / dropped 30s）
- ✅ **W6** 掉線後 3 次退避重連（**不**自動續跑路線，見下方「刻意未做」）
- ✅ **W7** Bonjour 候選依位址型態排序，link-local 墊底
- ✅ **W8** navigator / joystick 改用實際經過時間推進
- ✅ **W9** `_run` 加 except，回報 `state="failed"` 與原因
- ✅ **L12** `normalize_latlng`（極區折返 + 換日線 wrap）
- ✅ **M1** DaemonClient 20 秒 RPC 逾時 + reader EOF 回呼

### Phase 3 — runner 生命週期
- ✅ **L1 / L3 / L4** 統一到 `DeviceManager.attach_runner()` / `stop_all_movement()`
- ✅ **L5**（daemon 側）`_stop_all_movement` 廣播 `stopped` 而非 `idle`
- ✅ **L7** `location_for` 建構包在 per-session 鎖內
- ✅ **L20** 移除 `_stop_navigation_if_any`

### Phase 4 — 多點路線
- ✅ **L5**（Mac 側）spawn 前 `navigation = nil`
- ✅ **L6** `MultiStopLapContext` 改存完整 `routePoints`，改用 `teleportPositionOnly`
- ✅ 新增 `LociiGhostCore/LapPlanner.swift` + 11 個測試

### Phase 5 — 效能
- ✅ **P2** `Route.points` 解碼結果快取
- ✅ **P3** `NativeMapView` programmatic-fly 守衛 + debounce 1.5s
- ✅ **P4** `StopOrdering` best-improvement + 200 輪上限 + 門檻 8 + 移到背景執行緒
- ✅ **P5** `simulatedLocationsByDevice` 標 `@ObservationIgnored`，新增 `currentSimulatedLocation` 鏡像
- ✅ **P6** `NativeMapView` polyline / pin 快取
- ✅ **P7** 書籤搜尋 200ms debounce + `localizedCaseInsensitiveContains`
- ✅ **P8** 地圖搜尋 250ms debounce；`ForEach` 改用內容衍生 id
- ✅ **P9** 視窗被遮蔽時停止跟隨與時鐘更新（daemon 照跑）
- ✅ **P10** `refreshDevices` 改泛型 `call` + Equatable 短路
- ✅ **P11** 八個 `runModal()` 改 `beginSheetModal`
- ✅ **P14** `refreshDevices` 收斂 per-device 字典
- ✅ **P15** `stagedStops` 快取
- ✅ **P16** banner Task 納入 `bannerTask` 並在 `onDisappear` 取消
- ✅ **L10** `runRoute` 延後認領 `currentlyPlayingRoute`
- ✅ **L11** GPX 座標範圍檢查 + `Route.points` setter 編碼失敗時 pointCount 歸零
- ✅ **L14** OSRM cache 改 `asyncio.to_thread`；cache key 納入 `base_url`

### Phase 6 — 安全
- ✅ **X1 / X14** exec 前檢查 symlink、group/other 可寫、owner，並驗證簽章 Team ID 與 App 相同
- ✅ **X2** bootstrap 腳本改 0700 目錄內 0600
- ✅ **X3** log 拒絕 symlink 並檢查 owner
- ✅ **X4** PIN 8 位 + 每 IP 鎖定退避 + 全域失敗自動輪替 + 配對視窗（10 分鐘，由 Mac 讀 `/api/phone/info` 開啟）
- ✅ **X5** Host 必須是 IP literal + `/api/*` Origin 檢查
- ✅ **X7** 錯誤訊息遮蔽 `key=`
- ✅ **X8** Google key 改存 Keychain（含一次性遷移，清掉明文）
- ✅ **X9** bind 前 `umask(077)` + `getpeereid` 對端 uid 檢查（僅在明確不符時拒絕）
- ✅ **X10** pydantic 範圍限制 + `allow_inf_nan=False` + 乾淨的 422 handler
- ✅ **X11** device-cache 改 0600 + chown 給 SUDO_UID
- ✅ **X12** `manifest.url` 必須是 https
- ✅ **X13** `pkill` 限定 uid 0 與使用者
- ✅ **X15** `phone.html` 改用 `textContent` / `createElement`
- ✅ **X16** geocode 回應型別防禦
- ✅ **X17** stops / polyline 的 KeyError 改成可讀訊息
- ✅ **X18** in-memory container 失敗時顯示可操作的訊息而非 `try!` 崩潰
- ✅ **X19** 說明 bind race 並改善日誌

### Phase 7 — 可維護性
- ✅ **L19** 刪除死碼 `interpolate()`，測試改打 `Navigator`
- ✅ 新增 `test_navigator.py`(14) / `test_geo.py`(16) / `test_phone_api.py`(8) /
  `test_phone_security.py`(16) / `test_movement_lifecycle.py`(6) / `_fakes.py`
- ✅ **L8** daemon 回傳 `applied`；Mac 端只在真的生效時才更新 UI
- ✅ **L9** `DwellMonitor` 加 `generation`
- ✅ **L13** polyline 分支補上閉合
- ✅ **L15** `keyToNeighbors` 移除 clamp，跨面真的會回鄰面
- ✅ **L16** `keyToIJ` 驗證 face 與 position 字元
- ✅ **L17** `didFailWithError` 喚醒等待者
- ✅ **L18** GPX 匯出失敗會 throw
- ✅ **P12** 抽出 `MapShared.swift`（選單政策、`menuString`、S2 常數、相機存檔政策）
- ✅ **AppState 拆分** 5449 → 4198 行，搬出五個 `AppState+*.swift`

---

## 刻意未做（需要你決定）

**1. SMAppService + LaunchDaemon 遷移（X1–X3 的根本解）——決定不做**

2026-08-31 決定：**不遷移**，維持現在這條經過強化的 osascript 路徑。

漏洞本身已經堵住（見下方 X1/X2/X3/X14），剩下的是架構債而不是 open hole。
遷移的代價太集中在使用者身上、也太集中在一次不可逆的切換上：

- 拿掉 osascript 之後 `register()` 失敗就沒有退路，App 完全起不了 daemon。
- 首次啟動從「輸一次管理者密碼」變成「自己去系統設定 → 登入項目與延伸功能
  開啟」，沒開就什麼都不會動，而且 App 這端無法自救。
- SMAppService 對簽章與 bundle 位置很挑，ad-hoc build 與從 dist/ 直接跑的
  版本會被拒——本機開發每一輪都要 Developer ID 簽章。
- 註冊過的 LaunchDaemon 由 launchd 開機以 root 啟動，跟 App 是否開啟無關，
  與 README 承諾的「閒置 0% CPU、無背景開銷」衝突。
- 拖進垃圾桶不會移除它。沒有 `unregister()` 就會留下孤兒 root daemon。
- daemon 是 PyInstaller onedir（`_internal/`），搬進 bundle 要同時滿足巢狀
  簽章規則。

若日後要重啟這件事，三個前提：單獨分支、osascript 路徑至少保留一個版本當
fallback 而不是直接移除、反安裝流程先寫好再寫註冊流程。

**2. W6 自動重連後不自動續跑路線**
Session 會自動接回來，但不會自己重新開始移動——路線狀態在 Mac 端，
在使用者看不到的情況下靜靜重啟模擬比讓他按一下「繼續」更糟。
UI 會跳「已重新連線，按繼續」。若你想要自動續跑，要在 Mac 端記住
最後的 index 並在收到 `auto_reconnected` 時重發 navigate。

**3. Phase 7 的兩個大重構**
`AppState` 拆分與地圖去重都是純可維護性收益、零行為改變，但也是最容易
在沒有編譯器的情況下改壞的部分。等上面所有東西編譯＋跑過一輪之後再做。

---

## 待辦

**SMAppService + LaunchDaemon 遷移：2026-08-31 決定不做**

漏洞本身已經堵住：root 執行前會拒絕 symlink、拒絕 group/other 可寫、檢查
owner、驗證簽章 Team ID 與 App 一致，並且固定 `PATH`。根本解（LaunchDaemon）
的取捨與不做的理由記在上方「刻意未做」章節。

順帶一提，v1.16.0 修掉的 X2 exec 位元問題正是這條路徑脆弱的證據：稽核把
bootstrap 腳本從 0755 收緊到 0600，卻沒同時改掉「直接 exec 路徑」的呼叫方式，
而沒有 x bit 的檔案連 root 都不能執行。修法是改成交給 `/bin/sh`，兩處現在
互相註記。這說明維持這條路徑需要持續小心——但那是已知成本，比一次不可逆的
切換可控。

**一個設計決定**

W6 的自動重連會把 session 接回來，但不會自動重新開始移動。路線狀態在 Mac 端，
在使用者看不到畫面的情況下靜靜重啟模擬比讓他按一下「繼續」更糟；UI 會跳
「已重新連線，按繼續」。若要自動續跑，需在 Mac 端記住最後的 index 並在收到
`auto_reconnected` 事件時重發 navigate。

**清理**

- 刪除臨時檔：`ZZ-test-a.command`、`build-check.log`（都在專案根目錄）。
