# 全檢修正進度 — 分支 `audit-fixes`

基準 `cbbbc8d` (v1.15.1) + 兩個未提交的 v1.15.2 Phase 1 檔案。
原始清單見 `AUDIT-v1.15.1.md`；本檔記錄每一項的實際處置。

## 驗證狀態

| 檢查 | 指令 | 最後結果 |
|---|---|---|
| Swift 編譯 | `cd App && xcrun swift build --product LociiGhost` | ✅ exit 0（截至 Phase 5a） |
| Swift 測試 | `cd App && xcrun swift test` | ✅ 50 passed（截至 Phase 5a） |
| Daemon 測試 | `cd Daemon && .venv/bin/python -m pytest tests -q` | ✅ 106 passed |

**Phase 5 後半與 Phase 6 的 Swift 改動尚未編譯驗證**（改動當下 Mac 鎖屏）。
專案根目錄的 `ZZ-test-a.command` 雙擊即可跑完三項並把結果寫進 `build-check.log`；
確認無誤後可連同 `build-check.log` 一起刪掉。

### 沒有編譯器時做過的替代驗證

Swift 工具鏈在 Mac 鎖屏期間無法使用（雲端容器也裝不了，`download.swift.org`
被 egress 擋掉）。以下三項改用「把邏輯搬出來實際跑」的方式驗證，各自抓到
真正的缺陷：

| 對象 | 方法 | 結果 |
|---|---|---|
| `S2Grid` L15/L16 | 把投影數學原樣移植成 Python 再比對新舊行為 | level 12 的 40 個面邊界格，**舊版有 19 個把自己當鄰居**，新版 0 個；全部 40 個都能到達另一個 cube face；既有 5 項測試與新增 2 項在移植版上全過 |
| 特權 bootstrap 腳本 | 從 Swift 字串literal 抽出、代入插值、`bash -n` + 逐分支實跑 | 抓到 3 個缺陷（見 commit `1e1d681`）；修好後 stat 讀不到→96、group-writable→92、symlink→91、缺檔→90，X3 的 symlink 攻擊目標檔案原封不動 |
| `phone.html` X15 | `node --check` + 以會跳脫的 DOM stub 比對新舊 render | 舊版 `innerHTML` 注入出可執行的 `<img onerror=…>`，新版輸出 `&lt;img …&gt;` 純文字，且 mode pill 仍正常 |

這三輪加上單純重讀，總共在**我自己寫的修正裡**找到 6 個缺陷。這也是為什麼
Phase 7 的兩個大重構要等編譯器 —— 沒有它的時候，錯誤就是以這個速率產生的。

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
- ⬜ **P12** 兩個地圖實作抽共用元件 — 待辦（見下）
- ⬜ **AppState 拆四刀** — 待辦（見下）

---

## 刻意未做（需要你決定）

**1. SMAppService + LaunchDaemon 遷移（X1–X3 的根本解）**
現況已用「exec 前驗證 owner / 權限 / 簽章」堵住漏洞。要做根本解需要：
在 `.app/Contents/Library/LaunchDaemons/` 放 plist、daemon 執行檔搬進
`Contents/MacOS/`、改用 `SMAppService.daemon(plistName:).register()`、
移除 osascript 提權路徑。這會整段換掉特權啟動流程，而且沒有真的做一次 root
安裝就無法驗證——弄錯的話 App 會完全起不了 daemon。建議你在能實機測的時候
單獨開一個分支做。

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

**Phase 7 的兩個重構刻意留到編譯驗證之後**

`P12`（`MapContextMenuBuilder` / `MapGeometryPolicy` / `CameraPersistencePolicy`）
與 AppState 拆四刀（`RouteLibraryStore` / `BookmarkStore` / `BackupService` /
`DeviceConnectionCoordinator`）都是零行為改變的純整理，但也是最需要編譯器
一路盯著的部分。目前已經累積了一批還沒編譯過的 Swift 改動，再把 5000 行的
檔案拆開會讓錯誤無從二分。順序應該是：先跑一次 `ZZ-test-a.command` 讓
build + test 全綠，再開始拆。

拆分邊界（依現有 MARK 區塊，都不在 1 Hz 事件路徑上）：

| 新檔案 | 搬過去的東西 |
|---|---|
| `RouteLibraryStore` | Routes CRUD、GPX 匯入匯出、routes JSON I/O |
| `BookmarkStore` | Bookmarks CRUD、bookmarks JSON I/O |
| `BackupService` | `exportAllBackup` / `importAllBackup`（順帶就是 P11 改過的地方）|
| `DeviceConnectionCoordinator` | connect / disconnect / wifi pair / refreshDevices |

留在 `AppState` 的是真正需要集中的：連線狀態、移動模式、事件迴圈。

**清理**
- 刪除暫時檔：`ZZ-test-a.command`、`build-check.log`（都在專案根目錄）。
