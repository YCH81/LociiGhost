# LociiGhost 全檢清單 — v1.15.1 (cbbbc8d + v1.15.2 Phase 1 未提交)

審查日期 2026-08-30。四個方向：Wi-Fi 連線穩定度 (W)、系統邏輯 (L)、效能 (P)、安全與穩定性 (X)。
完整說明與程式碼證據見同名 HTML 報告；本檔是可勾選的施工清單。

嚴重 22 · 中等 26 · 輕微 17

---

## Phase 1 — 一行改動（約 1 小時，零架構風險）

- [ ] **X6** `http_server.py:429` `auth.rotate()` → `auth.rotate_pin()`（方法不存在，換 PIN 必定 500）；`AppState.swift:3050` 檢查 statusCode
- [ ] **W1** `location_service.py:43` `_RECOVERABLE` 加入 `PyMobileDevice3Exception`（InvalidServiceError 不是 OSError 子類，keepalive 要修的錯誤自己不在重試清單內）
- [ ] **P1** `AppState.swift:10-22` `dwellLog` 包 `#if DEBUG`（每 tick 4 次 syscall + /tmp 明文座標無上限成長）
- [ ] **P13** `AppState.swift:60, :597` 補 `@ObservationIgnored`（防 EXC_BAD_ACCESS，見 :1119-1128 註解）
- [ ] **L2** `http_server.py:556/575/594/614/630` `_emit` 補 `"state"` 欄位（Swift 讀 `state`，daemon 送 `mode`，桌面 UI 永遠停在移動中）

## Phase 2 — 連線穩定度（約 1 天）

- [ ] **W2** `location_service.py:190-198` `_reconnect()` 的新 DvtProvider 回寫 `sess.dvt_provider`（否則每次重連漏一條 tunnel，iPhone 30-90s 拒絕新 tunnel）
- [ ] **W3** `location_service.py:126-145` keepalive 在鎖外讀座標 → 會把裝置拉回舊位置。改 `if self._call_lock.locked(): continue`
- [ ] **W4** `set()` 加 `retries` 參數，keepalive 傳 0（心跳失敗會佔住 `_call_lock` 近 4 秒）；`navigator.py:123` `stop()` 改 `wait_for(timeout=2.0)`；`DaemonClient.swift:262` 加 RPC timeout + EOF 回呼 disconnect
- [ ] **W5** `device_manager.py:792, :816` 補 `peer_ip/peer_port`（健康檢查對 Bonjour/USB tunnel session 完全跳過）；存活判斷改成 keepalive 失敗計數 + degraded 事件
- [ ] **W9** `navigator.py:198` `_run` 只有 try/finally，加 except 把錯誤送到 UI
- [ ] **W8** `navigator.py:216-243` tick deadline 移到迴圈頂端（步長固定 → set 變慢時地面速度變慢、ETA 全錯）；joystick.py:142、random_walker.py:297 同

## Phase 3 — 手機控制端對齊桌面（約半天）

- [ ] **L1/L3/L4** 把 `handlers._stop_all_movement` 提升成 `DeviceManager.swap_runner()`，phone 與 RPC 共用
  - L1 `http_server.py:649, :745` navigate/multistop 沒停 walker/joystick → 兩個 mover 同時推位置
  - L3 `http_server.py:568` restore 沒停 runner → 還原無效
  - L4 `device_manager.py:1595-1616` 賦值在鎖外 + `handlers.py:428-442` 停舊/掛新無原子性 → 孤兒 task
- [ ] **L7** `device_manager.py:1618-1630` `location_for` 惰性建構在鎖外 → 並發首呼開兩條 tunnel。用 per-session 鎖或 Future single-flight
- [ ] 新增 `Daemon/tests/test_phone_api.py`（FastAPI TestClient）把上面變成回歸測試

## Phase 4 — 多點路線（約半天）

- [ ] **L5** `AppState.swift:4563` spawn Task 前補 `navigation = nil`（圈數會被重複扣，設 3 圈只跑 2 圈）
- [ ] **L6** `AppState.swift:4570` `MultiStopLapContext` 改存 `[origin] + stops`，改用 `teleportPositionOnly`（第 2 圈起點錯誤 + 零長度線段 + 地圖 pin 消失）
- [ ] 把 `applyStateEvent` 的圈數決策抽成純函式以便單元測（443c4a8 已證明這塊會回歸）

## Phase 5 — 效能（約 1 天）

- [ ] **P3** `NativeMapView.swift` 補 programmatic-fly 守衛（照抄 `MapContainerView.swift:1163-1169`），debounce 500ms → 1500ms。每秒同步 SwiftData 寫盤
- [ ] **P2** `Route.swift:91` / `AppState.swift:2280` 快取 `points` 解碼結果（每 tick 解 4000 個 Coordinate）
- [ ] **P4** `StopOrdering.swift:88-101` `smartSorted` 搬 `Task.detached` + 迭代上限 + best-improvement；暴力法門檻 10 → 8
- [ ] **P7** `BookmarkManagerSheet.swift:130` 搜尋加 200ms debounce + 存 @State（一次 body 重算跑 6 次過濾）
- [ ] **P8** `MapSearchModel.swift:23` 搜尋加 250ms debounce；`MapSearchBar.swift:337` ForEach id 不要用索引

## Phase 6 — 安全（2-3 天，發版前）

- [ ] **X4** 手機控制預設綁 `127.0.0.1`（現為 0.0.0.0）；PIN 6 位 → 8-10 位或 QR token；每 IP 失敗 5 次鎖定 + 退避；PIN 加 TTL
- [ ] **X5** 加 `TrustedHostMiddleware` + Host 必須是 IP literal + Origin/Sec-Fetch-Site 檢查（DNS rebinding 可從瀏覽器偷 PIN）；`/api/phone/info` 改走 Unix socket
- [ ] **X1/X2/X3/X14** 改用 `SMAppService.daemon` + LaunchDaemon，一次解決四項 root 執行路徑問題
  - X1 root 執行 `~/Library/Application Support/` 下的 python（使用者可寫 → 提權）
  - X2 `PrivilegedDaemonInstaller.swift:217` osascript 腳本 TOCTOU + 不必要的 0755
  - X3 root 以 append 開啟使用者可寫 log（symlink 攻擊）
  - X14 `/Applications` 內 daemon 未驗證簽章（admin 群組免認證可寫）
- [ ] **X7** `routing.py:280-300` 錯誤訊息含完整 API key，遮蔽或只取 status_code
- [ ] **X8** `AppState.swift:1258` Google API key 改存 Keychain
- [ ] **X10** `http_server.py:236-284` pydantic 加 `Field(ge/le)` + `allow_inf_nan=False`
- [ ] **X13** `PrivilegedDaemonInstaller.swift:185-193` 移除不帶 `-u` 的 `pkill -f`
- [ ] **X12** `UpdateService.swift` 檢查 `url.scheme == "https"`；manifest 加 sha256
- [ ] **X9** `rpc.py:126` bind 前 `os.umask(0o077)`；`getpeereid` 驗證對端 uid；RPC 帶 session token

## Phase 7 — 可維護性（等上面穩定）

- [ ] **P12** 抽出 `MapContextMenuBuilder` / `MapGeometryPolicy` / `CameraPersistencePolicy`（P3 就是兩份拷貝只修一份的後果）
- [ ] AppState 拆四刀：`RouteLibraryStore` / `BookmarkStore` / `BackupService` / `DeviceConnectionCoordinator`，拆完約剩 2500 行
- [ ] 新增 `test_navigator.py`；把 116 行 `interpolator` 測試改測真正在用的 `Navigator._advance`（L19：`interpolate()` 是死碼）

---

## 其餘中等／輕微項目（不進主線排程，順手夾帶）

### 邏輯
- **L8** `AppState.swift:3447-3465` pause/resume/stop 全用 `try?` 吞錯後樂觀更新 UI；`navigator.py:130` 已結束時回成功而非錯誤 → dwell 尾段會顯示「已暫停」但實際 no-op
- **L9** `AppState.swift:4308-4325` dwell Task 只檢查 nil 不辨識身分 → 中途換路線會吃掉新 monitor 的第一站。`DwellMonitor` 加 `generation: UUID`
- **L10** `AppState.swift:2457-2480` `runRoute` 在連線檢查前就設 `currentlyPlayingRoute` → 切換路線時舊路線進度遺失、未連線時進度被亂寫
- **L11** `GPXService.swift:113` 不驗座標範圍（另兩個 JSON service 都有）；`Route.swift:96` setter 吞掉編碼失敗但 `pointCount` 照更新 → 路線變空卻顯示 274 pts
- **L12** `joystick.py:152` / `random_walker.py:266` 不處理極區與換日線 → lat>90 時 dlng 爆炸
- **L13** `handlers.py:318, 400` `laps>1` 對 polyline 分支無效（閉合只加在 waypoints 上）。目前 App 端強制 laps=1 所以碰不到
- **L14** `routing.py:199-231` OSRM cache 用同步 sqlite3 跑在 event loop 上；`_cache_key` 不含 base_url
- **L15/L16** `S2Grid.swift:131, :262` 跨面鄰居回傳自己；壞 key 靜默回 (0,0,0,0)
- **L17** `LocationProxyService.swift:139` `didFailWithError` 是空的 → 一定等滿 timeout
- **L18** `GPXService.swift:77` `data(using:)?.write(...)` 失敗時靜默 no-op 且不 throw → 假的「匯出成功」
- **L20** `handlers.py:715-733` `_stop_navigation_if_any` 是死碼

### 效能
- **P5** `AppState.swift:217, :746` 共享字典造成 observation 假共享 → 連兩支 iPhone 時地圖以總和頻率重算。把選取裝置的值提升為 stored property
- **P6** `NativeMapView.swift:180-345` body 每 tick 重建整份 MapContent（4000 點路線每秒重配兩個陣列）
- **P9** 全專案無 `occlusionState` / `scenePhase` → 視窗被遮蔽時 UI 更新照跑（只停 UI，daemon 不能停）
- **P10** `AppState.swift:2803` `refreshDevices` 用 JSON 編碼→解碼往返；改泛型 `client.call` + Equatable 短路
- **P11** `AppState.swift:2801, 2835` `NSSavePanel.runModal()` 放在 async 函式裡 → MainActor continuation 行為不可預期
- **P14** per-device 字典無清理路徑（`savedStopsByDevice` 每台可留 64KB）
- **P15** `MultiStopPanel.swift:37` `stagedStops` 每次 body 重算重建整份陣列
- **P16** `GoldDittoPanel.swift:363, 391` 裸 Task 未被 onDisappear 取消

### 安全
- **X11** `device_manager.py:214-251` root 產生 0666 device-cache.json（改 chown + 0600）
- **X15** `static/phone.html:2222` `innerHTML` 插入 `ios_version`（其他地方都用 textContent）
- **X16** `http_server.py:936` geocode 對 Nominatim 回應假設過強 → 限流時 500
- **X17** `handlers.py:299, 332` stops/polyline 的 KeyError → `Internal error: 'lat'`
- **X18** `LociiGhostApp.swift:100` `try! ModelContainer` fallback 仍會 crash
- **X19** `http_server.py:1005` `_pick_free_port` bind-close-rebind race
- **X20** `Scripts/test-clean-install.sh:63` SIGKILL 時會留下 `.devbak.test`

---

## 已確認沒問題的部分

- 全庫**沒有任何硬編碼的 API key / token / secret**
- DMG 有簽章 + 公證 + staple；manifest 抓取走 HTTPS 憑證驗證，單純中間人塞不進惡意 DMG
- socket / fd / subprocess 釋放乾淨（`_get_lan_ip`、`_get_local_ipv4`、`_is_socket_alive`、254 條子網掃描連線都有 finally close）
- 背景 task 的例外不會殺掉 daemon（keepalive loop、phone session sweeper、http supervisor 都有 catch-all 且讓 CancelledError 穿透）
- session 拆除路徑逐一關閉 DVT / RSD / tunnel ctx / proxy / remote pairing service，每個獨立 try
- 專案用的是 `@Observable` 不是 `ObservableObject`，所以沒有「巨型 ViewModel 導致整棵 View tree 重繪」的問題
- `MapContainerView` 已有 `withObservationTracking` 解耦、annotation 簽名 diff、pin decimation、TimesChip 分鐘節流等調校 —— 問題在於這些沒有同步到 `NativeMapView`

## 測試現況

Daemon/tests/ 共 841 行。完全沒有測試：`navigator.py`(272)、`joystick.py`(169)、`random_walker.py`(311)、`http_server.py`(1077，L1/L3/L4 都在這)、Swift 端全部的圈數/resume/dwell 邏輯。
現有 116 行 `test_interpolator.py` 打在沒人用的 `interpolate()` 上 → 等於零 production 覆蓋率。
