> 最新版本為 [1.5.0](UPDATE-1.5.0.zh-Hant.md)：iPhone／iPad 共用 IPA，新增音訊匯入、播放與分享；請先閱讀新版操作說明。

# 課堂逐字稿 · iPad App Playground

App 1.3.1 新增錄音中 Apple 中文／English 手動切換與精簡字幕畫面，修正部分字詞時間資料缺失時漏掉文字的問題，並移除舊辨識文字的提示回饋。請讀 [1.3.1 使用與問題分析](UPDATE-1.3.1.zh-Hant.md)。仍需真機驗證切換延遲、英文辨識與多工錄音。

上課前請先讀 [Apple 即時字幕快速設定](START-APPLE-LIVE.zh-Hant.md)。App 1.3.0 的 [使用與差距說明](UPDATE-1.3.zh-Hant.md)、[1.2 改版說明](UPDATE-1.2.zh-Hant.md) 與以下內容保留先前版本的技術背景；新版模型載入位於右上角「錄音設定」，停止按鈕為「停止並儲存」。

完整 App 位於 `LectureTranscriber.swiftpm`，套件固定使用已在 iPad 通過基本匯入測試的 WhisperKit 相容版本 `1.1.3`。

App 1.0.1 隨專案附上藍綠色聲波圖示，修正直接建置 App Playground 時找不到 `__PlaceholderAppIcon` 的資源錯誤。更新時下載完整 ZIP，解壓後開啟新版專案即可，不必手動加入套件或貼程式。原有專案可保留。

已在 iPadOS 26.6.1、iPad Air 11 吋（M2）、Swift Playgrounds 4.7 確認：原專案重新選擇預設圖示後，可正常進入課堂逐字稿主畫面。已能啟動的專案可繼續使用，不必重新下載。

## App 1.1.0：即時草稿與刪除

- 預設改為 Large v3 Turbo；依使用者在 M2 iPad 的辨識回饋選定，並非各裝置通用的效能保證。
- 至少新增一秒音訊即可啟動下一輪辨識。直接顯示 WhisperKit 解碼 callback 產生的文字，每 150 ms 最多更新一次 UI；這是檢查／刷新間隔，不是保證的語音辨識延遲。
- 同一段的草稿反覆修正；連續兩輪相同且保留兩秒後續音訊的段落可提早確認。其他段落保留原先的時間窗確認與暫停補完機制。草稿不會當作已確認文字匯出。
- 「中英混說（中文為主）」使用中文主語言與中英提示文字；自動偵測仍是單一主語言判斷，不是兩種辨識器同時投票，也不是翻譯。英文為主的課堂可選 English。
- 可在新課堂開始前填入人名、課名、術語；提示與最近已確認文字提供有限上下文。提示不是保證，也可能造成錯誤，應對照實際錄音。
- 歷史紀錄新增垃圾桶與左滑刪除；確認後刪除該堂課的錄音、文字、標記及本機匯出檔。模型和其他課堂保留。錄音／辨識中的課堂須先暫停並等候作業完成。
- 顯示本輪辨識時間與草稿所涵蓋音訊的落後秒數；「尚未定稿」包含仍保留的語境，不等於看不到文字的延遲。

舊版 JSON 可讀取；但重新匯入 Playground 或改成獨立 App 可能使用不同資料容器。更新前保留原專案，重要逐字稿先匯出，不會自動搬移舊錄音或已下載模型。

實作參考：[WhisperKit 官方 AudioStreamTranscriber](https://github.com/argmaxinc/argmax-oss-swift/blob/main/Sources/WhisperKit/Core/Audio/AudioStreamTranscriber.swift)。保留本 App 寫入磁碟及斷點恢復的錄音方式，參考官方逐步解碼／草稿與確認段落的區分，並非直接替換成官方全部錄音管線。尚未實作官方 eager 模式的逐字時間戳記演算法。

## 在 iPad 開啟

1. 使用 Safari 下載儲存庫 `Deliverables/LectureTranscriber.zip`。
2. 在「檔案」App 的下載項目中，點 ZIP 解壓縮。
3. 點解壓後的 `LectureTranscriber.swiftpm`，用 Swift Playground 開啟，等待套件解析完成，按播放。

這是一份完整新專案，不需要修改原本的 Hello World，也不需要再次手動加入 package 或貼入 import。
若檔案沒有直接開啟，使用「分享 → Swift Playground」，或從 Swift Playground 的瀏覽器選取該檔案。

## 第一次使用

1. 保持連網，在 App 內選 Large v3 Turbo 與「中英混說（中文為主）」，按「載入模型」。英文為主則改選 English。
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
- 來電、輸入裝置拔除、音訊服務重設時自動暫停；Playground 進入背景也會暫停。1.5.0 IPA 的背景行為見下方。

## 保存與時間

錄音寫入 App Documents/Lectures，每堂課各有 session.json 與數個原始 16 kHz、單聲道、Float32 PCM 檔案。音訊不送往辨識伺服器。下載模型會連接 Hugging Face。

每五秒保存 JSON 狀態，每次確認文字及標記／編輯也保存。JSON 使用原子替換；PCM 持續寫入磁碟，暫停時同步並關檔。重新開啟時依實際 PCM 大小找回上次 checkpoint 之後的音訊。App 不會主動刪除歷史錄音。

錄音約使用 230 MB／小時，另加模型檔案空間。請保留足夠容量。解除安裝／刪除 Playground 專案可能失去其 App 本機資料，重要內容請先匯出。

所有時間為「實際收音的累計時間」，不包含暫停空檔。SRT 只包含已確認的語音段落，不將重點標記當作字幕。辨識結果可能有錯字、漏字或靜音幻覺，交付前可長按段落校正。

即時字幕需要視窗可見；App 在前景錄音時會防止螢幕自動鎖定。1.5.0 IPA 宣告背景音訊能力，切到背景／鎖屏時保存錄音，返回後追上未處理的聲音；Playground 進入背景會暫停。系統麥克風中斷仍可能停止，詳見 [1.5.0 背景使用與真機短測](UPDATE-1.5.0.zh-Hant.md)。

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

私人安裝與後續改善見 [私人安裝說明](PRIVATE_INSTALL.zh-Hant.md)。
