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

- **最新版本**：v1.10.2
- **發布日期**：2026-05-14
- **下載連結**：[Google Drive 下載資料夾](https://drive.google.com/drive/folders/120WcPQLsSddBR_A4hDipw4USQGbMFHlf?usp=sharing) —— DMG 已通過 Apple Developer ID 簽名 + Apple notarize，雙擊即可開啟，不會被 Gatekeeper 擋下

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

**v1.10.2**（2026-05-14）

- **修正一般使用者下載後無法啟動的 bug**：v1.10.0 的 .app 假設使用者本機
  `~/Documents/LociiGhost/Daemon/` 有原始碼 + venv（dev mode 設計留下的
  限制）。v1.10.2 把整個 PyInstaller daemon binary（94 MB）直接打包進
  `.app/Contents/Resources/lociighostd/`，沒有 Python、沒有 source code 的
  使用者也能雙擊就跑。
- DMG 體積因此從 4.7 MB → 44 MB（含整個 Python runtime 跟所有相依套件）。

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
