# LociiGhost

<p align="right">
  <a href="README.md"><img alt="繁體中文" src="https://img.shields.io/badge/繁體中文-active-2d3748?style=flat-square"></a>
  <a href="README.en.md"><img alt="English" src="https://img.shields.io/badge/English-gray?style=flat-square"></a>
</p>

<p>
  <a href="https://ko-fi.com/jflociighost"><img alt="在 Ko-fi 上支持 YCH81 aka Jeff Hu" src="https://img.shields.io/badge/Ko--fi-Support-FF5E5B?style=flat-square&logo=kofi&logoColor=white"></a>
  <a href="LICENSE"><img alt="MIT License" src="https://img.shields.io/badge/License-MIT-2d3748?style=flat-square"></a>
  <a href="https://drive.google.com/drive/folders/120WcPQLsSddBR_A4hDipw4USQGbMFHlf?usp=sharing"><img alt="Download (Google Drive)" src="https://img.shields.io/badge/download-DMG-7fa389?style=flat-square&logo=googledrive&logoColor=white"></a>
</p>

> **iPhone GPS 模擬工具** —— Apple Silicon 原生 macOS app，從 LocWarp（keezxc1223, MIT）概念與部分參照後 Swift 重寫。
>
> 上游：[keezxc1223/locwarp](https://github.com/keezxc1223/locwarp)（MIT）

從零打造、僅支援 Apple Silicon 的 iOS 定位模擬工具，以
[LocWarp](https://github.com/keezxc1223/locwarp)（keezxc1223 著、MIT 授權）為
靈感，但重建為原生 macOS app 。

## 支持作者

如果 LociiGhost 對你有幫助，想支持開發者，歡迎贊助我一杯咖啡一杯手搖杯。

[![在 Ko-fi 上支持 YCH81 aka Jeff Hu](https://img.shields.io/badge/在%20Ko--fi%20上支持%20YCH81%20aka%20Jeff%20Hu-FF5E5B?style=for-the-badge&logo=kofi&logoColor=white)](https://ko-fi.com/jflociighost)

## 下載

- **最新版本**：v1.14.0
- **發布日期**：2026-06-13
- **下載連結**：[Google Drive 下載資料夾](https://drive.google.com/drive/folders/120WcPQLsSddBR_A4hDipw4USQGbMFHlf?usp=sharing) —— DMG 已通過 Apple Developer ID 簽名 + Apple notarize，雙擊即可開啟，不會被 Gatekeeper 擋下。**請務必用 DMG 安裝**，不要把 .app 解壓到 iCloud 同步的資料夾（Documents、Desktop），File Provider 會蓋上額外 xattr 把簽章弄壞

## 第一次使用？

👉 **完整使用者手冊：[docs/user-guide.md](docs/user-guide.md)** —— 從安裝、第一次啟動、連 iPhone、跑出第一條路線，到六種移動模式與疑難排解，一步一步帶你走完。

## 主要功能

- **六種移動模式** —— 跳點、導航、路線循環、多點停留、隨機漫步、搖桿
- **雙手機同時控制** —— 兩支手機可獨立操作兩台不同 iPhone，互不干擾
- **per-device 路線記憶** —— 每台 iPhone 的路線／途經點／目的地各自保留，
  切換側邊欄不會洗掉狀態
- **手機端遠端控制** —— PIN 認證的手機網頁介面，可在 iPhone 上遙控 Mac
- **GPX ／ 書籤匯入** —— 支援 GPX 路線、LocWarp 格式書籤 JSON、批次貼上
- **即時切換速度** —— 播放中可動態調整移動速度，無須重新規劃路徑
- **準確 ETA** —— 隨 SpeedPicker 即時重算，UI 顯示時間 = 實際播放時間
- **多路由引擎** —— OSRM 公開 demo（預設）／ Google Routes API（可選）／ 直線
- **繁中／英雙語** —— UI 可即時切換語言，無須重啟
- **Apple Silicon 原生** —— 閒置 CPU 0%、無 Chromium 開銷、Bundle < 200 MB

## 最新更新

**v1.14.0**（2026-06-13）

- **新增 S2 地圖網格系統**（皮克敏 decor 格子視覺化）。地圖右上「S2 Grid」按鈕一鍵開啟，預設 L17（約 76 m × 76 m）對應 Pikmin Bloom 把 decor pikmin 分配到地面格子的粒度；可在 L13 (~1.2 km) ↔ L20 (~9.5 m) 之間切換，方便飛人規劃覆蓋路線、看出哪些格子還沒拜訪。視野過大時自動降階確保網格不會空白，popover 同時顯示「目前顯示 L13 — 放大才能看到 L17 格子」提示。
- **修復隨機漫步跨裝置切換時狀態遺失**。在 A 裝置開啟隨機漫步後，切到 B 或地圖再切回 A，原本紫色虛線計畫路徑會消失、隨機中心圓圈會跟著當下位置漂走（而非開始時的中心）。現在每台裝置的走者狀態獨立保存，圓圈永遠錨定在按下 Start 的座標。
- **修復隨機漫步中切換移動模式速度沒實際套用**。走路 / 腳踏車 / 汽車 / 自訂切換時 UI 雖然顯示新速度，但 iPhone 實際移動節奏沒變（daemon 走者在 start 時 snapshot 速度帶）。現在 AppState 偵測到 travelProfile 或 customSpeedMps 改動時，會延遲 250 ms 自動 stop+restart 走者（沿用同樣中心 / 半徑 / 路徑引擎），速度即時生效。

**v1.13.0**（2026-05-28）

- **書籤系統大幅升級**：
  - **照片預覽**：書籤可以帶照片，匯入或備份檔附 `image_url` 即可。側邊欄列旁、右鍵選單、地圖 pin 點擊都會跳出照片視窗（**點視窗外面就關閉**，不必按 X）。
  - **書籤管理面板**（側邊欄齒輪鍵打開）：可多選書籤批次刪除、移到不同分類、批次加前綴/後綴；分類也可重新命名、合併、整類刪除（連同書籤）或只清掉分類名稱保留書籤。
  - **側邊欄搜尋**：書籤多到滿出來時直接打字過濾，有匹配的分類自動展開。
  - **地圖書籤 pin 圖層**：圖層選單新增「Show bookmarks on map」開關，所有書籤以靛紫色 pin 顯示在地圖上、低倍率自動合併成 cluster，點 pin 直接跳照片。
  - **點書籤永遠能飛地圖**：以前沒連 iPhone 就無法點書籤跳到地點；現在不論有沒有裝置都會飛過去看，瞬移功能仍只在有連接真實 iPhone 時生效。
- **連 iPhone 瞬移後拖地圖大幅變順**。Apple 圖層底層換成 SwiftUI 原生地圖元件，畫面延遲明顯改善。其他圖層（OpenStreetMap、Carto、ESRI）保持原本表現。
- **修正路線執行中右上角資訊欄卡住**。國旗、天氣、時間 chip 在路線播放時之前不會跟著移動位置更新；現在會即時跟著當前模擬位置走。
- **匯入大量書籤不再卡頓**。3000+ 筆書籤匯入從凍住數十秒變成瞬間完成；展開包含上千個書籤的分類也立即響應。

**v1.12.0**（2026-05-26）

- **路線每次執行可獨立開啟停留模式**。StartRouteSheet 新增「暫停各停靠點」勾選欄 + 停留秒數欄位，路線播放時可覆蓋全域設定，單次執行不影響其他路線。
- **修復多停靠點 dwell 模式下 lap counter 消失**。之前開啟「每站停留」跑多圈路線時，ETA 下方的「Lap x / y」badge 不見了（因為 laps 被 clamp 到 1）。現在用 `dwellCurrentLap` / `dwellTotalLaps` 追蹤 dwell 模式下的圈數，底欄正確顯示進度。
- **修復路線自動重複第二圈繼承全域 dwell 設定的 bug**。路線第一圈明確指定不用停留，第二圈卻會自動開 dwell mode（讀到全域 `dwellEnabled`）。現在 loopContext 明確傳遞 `allowDwell` 參數，每圈行為一致。
- **補完繁中翻譯**。新增 37 個缺失字符串（Settings、Recent、Pause at each waypoint、sec per waypoint 等），UI 完全繁中化。

**v1.11.1**（2026-05-19）

- **每站停留模式下地圖顯示完整剩餘路徑**。v1.11.0 開啟「每站停留」走長路線時，地圖只顯示當前 leg 的下一個目的地，後面的 stops 跟路徑都看不見。修法：navigate() 在 dwell mode 下把 dwellContext.remainingStops 寫進 activeWaypoints（顯示用），daemon 仍然只看當前 leg。
- **新增「地圖置中」開關**（標題列設定按鈕左邊）。開啟（預設）時模擬移動中地圖自動跟著定位置中；關閉後地圖留在原處不再追蹤，可自由拖動查看其他位置。瞬移、路線初始仍會帶地圖到起點一次（走 `pendingMapFly` 不過 `shouldFollowSimulatedLocation`）。設定持久化 UserDefaults `map.autoRecenter`。

**v1.11.0**（2026-05-18）

- **效能大改**。MapContainerView 274 點路線從每秒 ~550 個 MapKit annotation 操作降到 ~0（4 個 dirty-check guard + batch addAnnotations + 模擬 pin KVO in-place 更新）；follow-puck setRegion 改 animated:false 不再跟 alert 搶主執行緒。地圖拖動、按鈕點擊、切換模式全部不卡頓。
- **多點功能大進化**：
  - 停靠點清單 Navigate 後持久顯示，按「清空」或切離 multi-stop 才清
  - 批次貼上 sheet 真正鎖高度（BoundedTextEditor 用 NSScrollView 包 NSTextView）
  - MultiStopPanel + ControlPanel 兩個 list 都加 ScrollView 上限 280pt
  - **新增「我的最愛 (Preset)」**：命名收藏 stops 組合，點 preset 跳「只顯示 / 瞬移到第一個 / 取消」三選一
  - **新增「每站停留 N 秒」(dwell mode)**：Navigate 時每個 stop 停 N 秒再走下一個，底欄 ETA 顯示全程估算時間
- **隨機漫步重做**：新增「直線 / 地圖路徑 (OSRM)」選擇。Map mode 用 per-leg JIT 規劃，地圖顯示的線就是 iPhone 實際走的真實道路；也支援每點停留秒數。
- **模式切換確認彈窗**：跑著 navigation / random / joystick 切其他模式跳「停止目前的模擬？」alert。
- **ControlPanel popup 重新呼出入口**：按 X 不再清空 stops，地圖左上 chip + sidebar 按鈕兩個入口。
- **Apple Maps 錯誤建議 OSRM**：MKDirections 失敗時 toast 提示切換引擎。
- **macOS 26 Tahoe 完整支援**：
  - 首次啟動偵測非 root daemon 或 stale binary 自動跳系統授權框
  - daemon.info 加 `start_time` 比對 binary mtime detect stale daemon
  - WiFi mDNS browse 修好（pymobiledevice3 / zeroconf 新版 Address 物件 `.ip` 屬性）
  - picker 顯示 IP:port 為主標題（不再 mDNS UUID）
  - build 三個 script 加 Tahoe FS `<name> 2` 自動 rename defense
- **繁中翻譯完整補上所有新字串。**

**v1.10.8**（2026-05-16）

- **macOS 14 Sonoma 終於可以開了**。daemon 改用 Python.org universal2 Python 3.13 build（`MACOSX_DEPLOYMENT_TARGET=10.13`）取代原本的 Homebrew Python — Homebrew Python 在 macOS 15.6 上 build，把 `pyexpat.cpython-313-darwin.so` link 到 macOS 15.0 才加的 expat 2.6 symbol `XML_SetReparseDeferralEnabled`，導致 Sonoma 14.x 系統 `/usr/lib/libexpat.1.dylib` 找不到該 symbol，daemon import pyexpat 直接 `ImportError: Symbol not found`，整個 .app 起不來。新 build minOS 從 15.0 降到 11.0，Sonoma 14.x 正常啟動。
- **修好點路線時下方 ETA panel 偶爾消失的 bug**。daemon 的 `_stop_all_movement` 原本在每次 `location.teleport` / `location.navigate` 進來時都 broadcast `state="idle"`，就算根本沒任何 mover 在跑。這個多餘的 idle 事件如果在 navigate 的 RPC reply 之後才抵達 Mac，會把 `AppState.navigation` 清成 nil，BottomBar 的 ETA panel 就此消失整段路線（daemon 還在跑、地圖 marker 還在動，但下方狀態列空白）。雙端對症修：daemon 只在真有 mover 停了才 emit idle；Mac 端 `applyPositionEvent` 在收到 position event 但 `navigation == nil` 且事件聲明 `state="moving"` 時，從 payload 自動重建 NavigationVM（payload 含完整 distance_m / eta_s / speed_mps / profile / progress）。
- DMG 大小幾乎沒變（45.9 MB → 45.9 MB），native deps wheel 大多還是 arm64-only — Python.org Python 換的是 Python 自己的 minOS。執行時 **CPU / 記憶體 / 電池耗能完全不變**。順帶為未來 Intel 支援鋪好底層。
- 沒有 UI 或新功能改動，所有設定、書籤、路線、裝置配對皆延續 v1.10.7。

**v1.10.7**（2026-05-16）

- **路線「自動重複」**。點側邊欄路線時跳出的確認彈窗多了一個「我按停止前一直重複」勾選欄。勾起來後，路線跑到終點會自動從起點再來一次，直到使用者按 Stop。實作上是把 `routeLaps` 暫時拉到 9 999；daemon 把這個 lap 數抄進 session state，9 999 圈對任何實際 GPS 路線都等同於「永遠」。
- **多點批次貼上座標**。多點面板新增「Bulk-add coordinates…」按鈕，貼上一行一組 `lat, lng`（逗號 / tab / 分號皆可，`#` 開頭視為註解），每一行依序變成下一個停靠點。一次規劃 30 個點不用再點 30 下地圖。
- **搜尋欄改為置中、不再蓋到比例尺**。地址搜尋欄與右側 4 個按鈕一起浮在地圖中央，視窗大小改變時自動跟著重新置中。永遠不會擋到左上角的「0 — 2.5 km」比例尺，也不會跟右上角的控制群衝突。
- **搜尋欄右側按鈕變大 + 有底色框**。貼上 / 瞬移 / 預覽 / 導航 4 個按鈕從 `.small` 升到 `.regular`，並用一個半透明的圓角材質框住整組，從此不會跟地圖底圖混在一起找不到按鍵。
- **贊助按鈕統一導到 sponsor 頁**。側邊欄的「Buy me a bubble tea」跟 Settings 裡的支持作者連結都改為指向 [https://ych81.github.io/LociiGhost/sponsor.html](https://ych81.github.io/LociiGhost/sponsor.html)，集中展示 Ko-fi、LINE 等多種支持管道；未來新增支持選項只要改 sponsor.html 一個檔。

**v1.10.6**（2026-05-14）

- **「還原真實 GPS」終於真的飛回你當下的位置**。以前點還原會飛到 app 啟動時抓的舊 Mac 位置（permission 沒給時更是靜默無事）。現在還原會先 await Mac CoreLocation 新 fix（2 秒 timeout）再飛地圖；連線時也會主動再請求一次位置權限。拿不到 fix 時顯示「請至系統設定 → 隱私 → 位置服務開啟 LociiGhost」訊息，不再靜默。
- **WiFi 裝置列表多 IP 路徑不再撞同名**。以前單一 iPhone 透過多個 LAN 路徑被掃到時，4 個 row 全顯示 `Frankie's iPhone`，只能靠 subtitle 的 IP 區分。現在 tcp_scan 候選保留 IP 作為主名稱，每個 row 直接看名稱就能分。
- **支援匯入 LocWarp 路線 JSON**。LociiGhost 內部 schema 用 `points`、LocWarp 用 `waypoints`，`Optional` 解碼把所有 LocWarp route 都 silently 跳過了；現在兩種 key 都接受。
- **Settings → Routes 的 Import / Export JSON 結果直接顯示在 sheet 內**。原本走 `state.lastError` toast 但只在 MainView 渲染，Settings sheet 把它整個蓋掉，造成「點 Export 完全沒反應」的錯覺。Sheet 裡現在有自家的訊息列，5 秒後自動消失。
- **導航 ETA 面板平鋪展開**。`frame(width: 180)` 把整個 VStack 寬度釘死在 180 pt，距離 + ETA 文字被擠成 3 行 wrap。現在距離一行、ETA 一行、進度條全寬撐滿。
- **新增內部工具 `Scripts/test-clean-install.sh`**。強制乾淨環境驗 DMG：mv source → `.devbak.test`、清 `/Applications/LociiGhost.app` + `~/Library/com.lociighost.*`、ditto DMG 到 `~/Downloads/` 加 quarantine xattr，trap 確保 source 一定還原。防止 v1.10.0–v1.10.4 那種「dev 機跑得通、別人裝就壞」的 cascade 重演。

**v1.10.5**（2026-05-14）

- **修好 v1.10.4 雖然不閃退、但 daemon 抓不到的 bug**。Swift Foundation
  的 `URL.appending(path:)` 在 base URL 上產出 base+relative 雙層結構，
  新 API `URL.path(percentEncoded:)` 對這種結構不會 resolve —— 只回 relative
  segment。結果 `resolveExecutable()` 拿到 `"Contents/Resources/lociighostd/
  lociighostd"`（沒 `/Applications/LociiGhost.app/` 前綴），`isExecutableFile`
  回 false → 走錯分支 → 拋 `daemonNotFound`。修法：在 `Bundle.main.resourceURL.
  appending(...)` 之後加 `.absoluteURL` 把 base+relative 合成單一絕對 URL。
- 同步把 `DaemonStaging.hasBundledDaemon`（之前用 deprecated `.path`
  getter 剛好繞過這個雷）一併改成 `.absoluteURL.path(percentEncoded: false)`
  寫法，兩個 callsite 從此不會再對同一條路徑得到不同答案。

**v1.10.4**（2026-05-14，已過時，請升級到 v1.10.5）

- **真正修好 v1.10.0 一般使用者閃退的 bug**。v1.10.1–v1.10.3 各補一層後
  仍會閃退，挖到最後是 SwiftPM 自動產的 `Bundle.module` accessor 在
  .app 包裝後找不到 resource bundle，會在第一次 render iPhone row 時
  （`DeviceVM.developerModeLabel`）打到 `fatalError`。修法：把所有
  `String(localized: …, bundle: .module, …)` 改成不帶 `bundle:` 參數
  （走 Bundle.main），並在 package-app.sh 加 grep guard 預防回流。
- 順便釐清 zip 解壓到 iCloud Drive 路徑會壞掉的問題（File Provider 蓋
  FinderInfo + protected xattr），**請務必用 DMG 安裝**，從 /Volumes 拖
  到 /Applications，全程不碰 iCloud。
- 但 v1.10.4 仍有 daemon 路徑解析 bug，必須升 v1.10.5 才能正常運作。

**v1.10.2**（2026-05-14，已過時，請升級到 v1.10.5）

- 把整個 PyInstaller daemon binary（94 MB）直接打包進
  `.app/Contents/Resources/lociighostd/`，沒有 Python、沒有 source code 的
  使用者也能雙擊就跑。
- DMG 體積因此從 4.7 MB → 44 MB（含整個 Python runtime 跟所有相依套件）。
- 但 v1.10.2 還會閃退（Bundle.module bug），v1.10.4 才真正修好。

**v1.10.0**（2026-05）

- **Apple MapKit 加入為路徑引擎**，並設為預設（4 個選項：MapKit ／
  OSRM ／ Google Directions ／直線）。MapKit 不用 API key、原生整合、
  台灣地圖品質佳；cycling 模式以汽車幾何規劃、SpeedPicker 控制實際速度。
- 多段路線採 **chain stitch** 策略消除中繼點繞圈：每段 leg 的起點 =
  前一段 polyline 的終點，避免 MapKit 對同一 waypoint 在「終點 / 起點」
  角色 snap 到不同道路導致的方框 artefact。
- Sidebar 底部新增**固定支持作者區**（Ko-fi + LINE 社群按鈕），不隨內容
  滾動移動。
- 紅色 X 改為**標準 Mac 行為**：關視窗 ≠ 退出，Cmd+Q 才真的退出。
- TopStatusBar 在窄視窗時**不再字串 char-wrap**；視窗最小寬度鎖在
  1320×640，sidebar 鎖在 280–310 pt。
- iPhone 模擬位置 marker 永遠**浮在路線之上**（z-priority fix）。
- LICENSE 新增 **Brand & Support Channels carve-out**：「LociiGhost」名稱、
  icon、Ko-fi、LINE 個人保留，不在 MIT 範圍。
- **官方 Pages 網站**（[ych81.github.io/LociiGhost](https://ych81.github.io/LociiGhost/)）、
  Ko-fi 贊助連結、LINE 官方帳號（`@382ydavk`）/ 社群（「LociiGhost Mac/iOS 飛人」）。


**v1.9.4**（2026-05）

- 多手機獨立控制：單支 iPhone 的手機操控頁面可控制其他已經連線的 iPhone
  （per-tab token + per-session `controlling_udid`）
- per-device 路線持久化：切換 iPhone 不會洗掉各台的路線狀態
- OSRM `NoRoute` 自動 fallback：bike/foot 找不到路時改用 car 重試
- ETA 重算機制：跟著 SpeedPicker 走，UI 時間 = 實際播放時間
- Restore 後跳藍色提示，說明 iPhone GPS 重新定位需要 30 秒到 2 分鐘

完整 commit 歷史：[git log](https://github.com/YCH81/LociiGhost/commits/main)

## 聯絡 ／ 社群

歡迎加入 LINE 官方頻道與社群，第一時間收到釋出通知、跟其他使用者交流：

[![LINE 官方帳號](https://img.shields.io/badge/LINE-加官方帳號-06C755?style=for-the-badge&logo=line&logoColor=white)](https://line.me/R/ti/p/%40382ydavk)
[![LINE 社群](https://img.shields.io/badge/LINE-加社群-06C755?style=for-the-badge&logo=line&logoColor=white)](https://line.me/ti/g2/-x9IldV0HMk-4Ydc-U93UnvOnUPbJ1En3z9XIg)

- LINE 官方帳號 ID：`@382ydavk`
- LINE 社群名稱：「LociiGhost Mac/iOS 飛人」
- 技術 bug 報告、feature request：可以在Line社群或官方帳號回報

## 動機

現有之前改的Locwarp 的 macOS 版（`M-0.2.99.5`）功能完整，但架構上是直接從 Windows 搬過來的：
Electron renderer、web map、FastAPI HTTP server、WebSocket bridge。在 M 系列
Mac 上**明顯偏熱/處理效能不佳** —— 風扇拉滿、Activity Monitor 看到上百 MB 的 Chromium
overhead —— 對於一個要常駐背景的工具來說，形狀不對。

這次重寫的目標：

- **閒置 = 安靜。** 沒在模擬時，daemon 停在 `accept()`，SwiftUI app 不做任何
  背景工作。
- **原生渲染。** SwiftUI + MapKit，沒有 Chromium、沒有 Leaflet。
- **單一架構。** 只支援 arm64。Bundle 200 MB 以下。
- **相同的產品概念。** 六種移動模式、雙裝置同步、GPX 匯入、書籤、ETA、即時
  切換速度。

## Repo 結構

```
LociiGhost/
├── App/          Swift package（LociiGhostCore lib + lociighostctl CLI）
├── Daemon/       使用 pymobiledevice3 的 Python helper（lociighostd）
├── Scripts/      build-daemon.sh、build-app.sh
└── docs/         rpc-protocol.md 等
```

## Phase 0 狀態（已完成）

> **注意**：本節為 v0.1.0 早期 scaffolding 紀錄。目前已走到 v1.9.4
> （Phase 0–5 + distribution phase 皆完成），含多手機獨立控制、per-device
> 路線、Apple Silicon 原生 daemon 打包、Developer ID 簽名腳手架。最新進度
> 請看 [git log](https://github.com/YCH81/LociiGhost/commits/main)。

Scaffolding 與端對端 RPC round-trip 驗證完成。

- Daemon 專案有 `pyproject.toml`，JSON-RPC 2.0 server 走 Unix domain socket，
  7 個單元測試通過。
- `lociighostd` 註冊了 `ping`、`daemon.info`、`daemon.shutdown`。
- Swift package 含 `LociiGhostCore`（paths、JSON-RPC types、`DaemonClient`
  actor）跟 `lociighostctl` CLI；2 個 Swift 測試通過。
- 兩端都有 build script。

端對端量測（2026 年 5 月、M 系列、macOS 15.6.1）：

- `lociighostctl ping` → `{"pong":true,"version":"0.1.0",...}` —— round-trip
  < 5 ms
- Daemon 閒置 CPU：**0.0%**（連線穩定後）
- Daemon 閒置 RSS：~22 MB
- Shutdown 乾淨（signal handler 與 RPC method 兩條路都可）

`DaemonClient` 刻意把阻塞的 `read(2)` 放到背景 thread、**離開 actor 的
executor**，避免 syscall 阻塞時連 actor 一起死鎖。見
`App/Sources/LociiGhostCore/DaemonClient.swift`。

尚未完成（後續階段）：

- **完整 Xcode 必要**，才能打 SwiftUI 的 `.app` bundle。只裝 Command-Line
  Tools 可以 build Swift CLI 跟 core lib，但無法 link SwiftUI app 或產出可
  notarize 的 `.app`。
- Phase 1：USB 裝置探索 + 跳點（`device.list`、`device.connect`、
  `location.teleport`）。
- Phases 2–5：見計畫。

## 快速驗證（Phase 0 smoke test）

```bash
# 1. Build daemon
./Scripts/build-daemon.sh

# 2. 前景啟動
cd Daemon && source .venv/bin/activate
lociighostd --socket /tmp/lw.sock -v &

# 3. 從 Swift 端呼叫
cd ../App && swift run lociighostctl --socket /tmp/lw.sock ping
# => {"pong":true,"version":"0.1.0", ...}

# 4. 關掉它
swift run lociighostctl --socket /tmp/lw.sock shutdown
```

## 系統需求

- **macOS 14 (Sonoma) – macOS 26** —— 向上相容。Binary `minos` 是 14.0，日常
  測試到 macOS 15 / Sequoia。完整相容性矩陣 + 驗證指令見
  [`docs/compatibility.md`](docs/compatibility.md)。
- **Apple Silicon（M1 / M2 / M3 / M4）** —— Intel Mac 刻意不支援（這次重寫
  的重點就是脫離 Electron / Rosetta 的負擔）。
- **Python 3.13** 透過 Homebrew：`brew install python@3.13`。
- **Swift 6**（Phase 0 用 Command-Line Tools 即可；Phase 1 起需要完整
  Xcode 才能編 SwiftUI）。
- iPhone 端 iOS **16 – 26**。USB 在所有支援的 iOS 都能用；WiFi-only 需要
  一次性的 **Pair for WiFi** 儀式（走 M-style RemotePairing，見 changelog
  Phase 4.5）。
- Phase 4 WiFi tunnel：**不需要付費 Developer Program 會員** —— 管理員權限走
  `osascript "do shell script ... with administrator privileges"` 而不是
  `SMAppService`（每次 Mac 重啟需要一次 Touch ID 提示）。

## 歸屬

LociiGhost 是 [LocWarp](https://github.com/keezxc1223/locwarp)（**keezxc1223**
著、原以 MIT License 散佈）的完整 native-Swift 重寫。產品概念 —— 六種移動
模式、雙裝置同步、phone-control web UI、書籤 / GPX 匯入流程、OSRM 路徑快取
策略 —— 皆源自 LocWarp；本 repo 中數個原始檔保留了「ported from LocWarp」
的明確註解，以註明設計對齊處。

LociiGhost 本體（新的 Swift app、Apple-Silicon-native daemon、SwiftData
schema、原生 MapKit 整合、sage 配色的紙飛機 icon set，以及 v1.0 之後的所有
功能開發）為 **YCH81（Jeff Hu）** 的原創作品。

## 授權

LociiGhost 程式碼以 **MIT License** 散佈 —— 完整條款見 [`LICENSE`](LICENSE)。

> ⚠️ **品牌為個人保留，不在 MIT 範圍。** 完整條款見 [`LICENSE`](LICENSE)
> 的 **Brand & Support Channels** 段。

## 免責聲明

### 1. 僅限合法用途

本專案開發初衷僅供地理資訊系統（GIS）研究、行動應用程式開發測試、位置
服務原型驗證、個人地圖瀏覽及相關技術探討使用。請勿將本工具用於任何非法
用途，或違反第三方服務條款、平台政策之行為。

### 2. 帳號封禁與第三方服務風險

本工具會修改 iPhone GPS 模擬狀態，可能違反 app／遊戲服務條款／定位類
遊戲之規範。使用風險自負，可能造成帳號封禁、進度遺失、寶物清空，作者
不負任何責任。

若使用本工具，可能違反第三方平台的服務條款，進而導致帳號遭警告、限制、
封鎖或永久停權，已累積之虛擬寶物、進度、儲值點數亦可能一併損失。開發者
對因使用本工具所造成之任何帳號損失、虛擬財產損害或衍生糾紛，概不負責。

### 3. 系統與硬體風險

本專案需以系統管理員權限執行。雖然程式碼已經內部測試，但開發者不保證
於所有 macOS 版本、Apple Silicon 機型、網路環境下皆能穩定運行。

使用者應自行評估上述風險並承擔因此所產生之任何後果。本專案僅操作本身
所建立之臨時網路介面與自身設定檔（位於
`~/Library/Application Support/LociiGhost/` 與 `~/Library/Caches/LociiGhost/`），
不會修改 iOS 裝置內任何使用者資料，亦不會變更 macOS 核心檔案或既有裝置
配對記錄。

### 4. 地圖資料準確性

本專案地圖渲染採用 Apple MapKit（原生底圖），路徑規劃使用 OSRM 公開 demo
（預設）或 Google Routes API（可選，需自備 API key），地理編碼可選用
Google Geocoding API。地圖顯示之座標、路徑、地址資訊僅供參考，開發者
不保證其完整性、即時性、正確性或與實際地理位置完全一致。使用者在依照
地址搜尋、路線導航、隨機漫步等結果進行定位模擬前，應自行比對地圖顯示
是否符合預期。

### 5. 測試環境與支援範圍

本軟體僅於開發者本人測試環境驗證 —— macOS 15+ Apple Silicon、
iPhone 16 Pro Max / iOS 18.7–26.4。不保證其他裝置／iOS／macOS 組合
穩定運作。

本專案為個人業餘時間維護，無 SLA、無客服。Bug 修復、新 iOS 相容性、
新功能皆視作者時間與精力而定。

### 6. 使用者責任與法律遵循

使用者應自行遵守所在地之法律法規，包括但不限於《個人資料保護法》、
《著作權法》、《電腦處理個人資料保護法》及相關國際條約。本工具不得
用於詐欺、騷擾、規避地理限制以從事違法行為，或任何造成第三方損害的用途。

任何因濫用、誤用或違法使用本工具所引發之法律糾紛、民事賠償或刑事責任，
均由使用者個人獨自承擔，與本專案之開發者及貢獻者無涉。

### 7. 無擔保

本軟體依 MIT License 散佈，「依現狀」（AS IS）提供，無任何明示或默示
之擔保（包括但不限於適售性、特定目的適用性、無侵權之擔保）。完整法律
條款見 [`LICENSE`](LICENSE)。
