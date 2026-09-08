# 課堂逐字稿 · iPad App Playground

完整 App 位於 `LectureTranscriber.swiftpm`，套件固定使用已在 iPad 通過基本匯入測試的 WhisperKit 相容版本 `1.1.3`。

App 1.0.1 隨專案附上藍綠色聲波圖示，修正直接建置 App Playground 時找不到 `__PlaceholderAppIcon` 的資源錯誤。更新時下載完整 ZIP，解壓後開啟新版專案即可，不必手動加入套件或貼程式。原有專案可保留。

已在 iPadOS 26.6.1、iPad Air 11 吋（M2）、Swift Playgrounds 4.7 確認：原專案重新選擇預設圖示後，可正常進入課堂逐字稿主畫面。已能啟動的專案可繼續使用，不必重新下載。

## 在 iPad 開啟

1. 使用 Safari 下載儲存庫 `Deliverables/LectureTranscriber.zip`。
2. 在「檔案」App 的下載項目中，點 ZIP 解壓縮。
3. 點解壓後的 `LectureTranscriber.swiftpm`，用 Swift Playground 開啟，等待套件解析完成，按播放。

這是一份完整新專案，不需要修改原本的 Hello World，也不需要再次手動加入 package 或貼入 import。
若檔案沒有直接開啟，使用「分享 → Swift Playground」，或從 Swift Playground 的瀏覽器選取該檔案。

## 第一次使用

1. 保持連網，在 App 內選 Small 與「中英自動」，按「載入模型」。
2. 首次需要下載 Core ML 模型與 tokenizer，並在 iPad 上準備模型，可能需要數分鐘。Large 選項的準備時間及記憶體需求更高。
3. 輸入課堂名稱，按「開始錄音」，允許麥克風。
4. 灰色文字是暫時結果；確認段落帶有時間，會持續儲存。
5. 按「暫停並儲存」會停止收音，再補辨識最後一段。可繼續錄音，或從右上方匯出 TXT、Markdown、SRT。

已完成模型與 tokenizer 的首次下載後，可以離線載入及辨識。切換到尚未下載的模型需要網路。

## 已包含

- 本機麥克風錄音、音量表、錄音計時。
- 多語言語音轉文字，保留原語言；也可指定中文或英文。
- 滾動短視窗辨識、確認／暫時文字、落後秒數、跟隨最新與搜尋。
- 暫停／繼續、最後一段補辨識。
- 自動保存、歷史課堂、重開後補辨識未完成音訊。
- 重點標記；長按標記按鈕可加文字註記。
- 長按確認段落可以編輯文字。
- TXT／Markdown／SRT 匯出與系統分享。
- 來電、輸入裝置拔除、音訊服務重設、進入背景時自動暫停。

## 保存與時間

錄音寫入 App Documents/Lectures，每堂課各有 session.json 與數個原始 16 kHz、單聲道、Float32 PCM 檔案。音訊不送往辨識伺服器。下載模型會連接 Hugging Face。

每五秒保存 JSON 狀態，每次確認文字及標記／編輯也保存。JSON 使用原子替換；PCM 持續寫入磁碟，暫停時同步並關檔。重新開啟時依實際 PCM 大小找回上次 checkpoint 之後的音訊。App 不會主動刪除歷史錄音。

錄音約使用 230 MB／小時，另加模型檔案空間。請保留足夠容量。解除安裝／刪除 Playground 專案可能失去其 App 本機資料，重要內容請先匯出。

所有時間為「實際收音的累計時間」，不包含暫停空檔。SRT 只包含已確認的語音段落，不將重點標記當作字幕。辨識結果可能有錯字、漏字或靜音幻覺，交付前可長按段落校正。

錄音時保持 App 在前景；App 會防止螢幕自動鎖定。主動鎖定、切到其他 App 或系統中斷會暫停，返回後使用「補辨識」再繼續。此版本沒有宣告背景錄音能力。

## 驗證邊界

GitHub Actions 的 `Lecture App Validation` 使用雲端 Mac：

- 用真實 Foundation 執行時間戳記、字幕、Unicode、匯出路徑、JSON 保存與中斷恢复測試。
- 用 Xcode 內建 AppleProductTypes 對 App Playground 的 Package.swift 做型別檢查。
- 用 Xcode 編譯相同 App Swift 原始碼與真正的 WhisperKit 1.1.3 iOS 相依套件。
- 直接以原始 `.swiftpm/Package.swift` 建置 iOS 裝置版本，涵蓋 App 圖示與資源處理。
- 直接建置 `.swiftpm` 模擬器版本，安裝、啟動並保存畫面；另以 UI 測試確認主畫面及歷史紀錄導覽。

iPad 上 Swift Playgrounds 的執行、麥克風授權、模型下載／Core ML 載入、装置上的辨識速度及音訊品質仍需真機驗證。CI 編譯與模擬器啟動成功不代表這些真機流程已測試。

建議真機一次驗收：錄中英文各 15 秒 → 標記 → 暫停 → 繼續 10 秒 → 暫停 → 匯出三種格式 → 重開 App 讀取歷史紀錄。

## 開發者

`AppBuild/project.yml` 可用 XcodeGen 產生一般 Xcode 驗證專案；`AppTests/main.swift` 為可獨立執行的資料與時間處理測試。
App 保留套件原有 LICENSE 與 Argmax attribution，沒有修改 WhisperKit 模型推論、解碼、tokenizer 或音訊處理原始碼。
