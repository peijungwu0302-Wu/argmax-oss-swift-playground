# 課堂逐字稿 1.2：雙語錄音工作區

這次參考 InkNote AI 官網與使用者提供的錄音畫面，重做錄音流程與資訊排列，保留自己的 App 名稱與圖示。沒有使用 InkNote 的程式碼、品牌素材或未公開模型，也不表示具有相同的辨識速度或準確率。

## 開始使用

1. 先保留目前能開啟的 Playground，並匯出重要逐字稿。新版 ZIP 解壓後，用 Swift Playgrounds 開啟 `LectureTranscriber.swiftpm`。不用手動加入套件、修改 import 或重設圖示。
2. 在主畫面輸入課堂名稱，選「中英夾雜」（中文為主）或「英文」。預設仍為 Large v3 Turbo；右上角「錄音設定」可以改模型、事先載入、填專有名詞。
3. 如需中文翻譯，先連網開啟「即時翻譯字幕」，允許 Apple 下載英語／繁體中文語言。畫面顯示翻譯已就緒後，再開始正式錄音。已下載語言與 Whisper 模型後可離線使用。
4. 按「開始錄音」。iPad 寬畫面會左右並排原文與翻譯；窄畫面上下排列。可以搜尋文字、關閉「跟隨最新」、加入重點標記。
5. 按「停止並儲存」，等最後一段辨識完畢。接著可繼續錄音、分享翻譯，或打開「會議紀錄」產生整理。
6. 左上角歷史紀錄可開啟或刪除錄音。刪除需確認，會一併移除該堂錄音、文字、翻譯、整理與本機匯出檔。

## 實際新增的功能

- 米白色畫布、大計時器、語言分段選擇、原文／中文翻譯區、底部固定錄音操作。
- Apple Translation 裝置端英翻中。中文原文保留；中英混說依英語片段分開翻譯，不將整段中文指定成英文。這種片段分割可能減少上下文，特別短的術語、人名與日期仍應校正。
- 已確認的段落依序翻譯並保存。原文草稿最多約每三秒嘗試一次翻譯；只有仍對應當前草稿的結果才顯示，過時結果會捨棄。三秒是嘗試間隔，並非顯示延遲保證。
- 翻譯錯誤會顯示在翻譯卡片，可關閉再開啟重試；不會停止錄音或刪除原文。關閉翻譯不會刪除已保存的譯文。
- 長按原文可以編輯；相關翻譯作廢，開啟翻譯後重新產生。翻譯匯出只包含完成的段落。
- iPadOS 26 的 Foundation Models：Apple Intelligence 就緒時，停止後可在裝置端分段整理重點、決議、待辦，並保存結果。長課堂逐段處理，不直接把完整長課堂塞進一次提示；目前輸出是分段整理，未再合併成單一全局摘要。
- Apple Intelligence 未就緒時，會產生明確標示的「原文整理」，保留所有時間戳與文字；不冒充 AI 摘要。模型發生錯誤時也能手動選擇原文整理。
- 開始 AI 整理前釋放 App 持有的 Whisper 模型參考，減少同時占用；之後繼續錄音會重新從已下載的模型載入。
- 繼續錄音或修改原文後，舊的會議紀錄會提示需重新整理。文字與翻譯可透過系統分享；翻譯匯出 Markdown，原文仍支援 TXT／Markdown／SRT。

## 在你的 M2 iPad 上

保留 Turbo 預設，是依照你先前實測較準的結果。UI 改版並不會改變 Whisper 的基本準確率。這版仍使用 WhisperKit 的解碼草稿，尚未改用 Apple SpeechAnalyzer，也沒有實作 InkNote 官網所宣傳的說話者分離、掃描、文件問答或列印工具。

AI 會議整理需要系統的 Apple Intelligence 可用，取決於語言、地區、設定與模型是否下載完畢；M2 晶片本身不是充分條件。Swift Playgrounds 宿主下是否能實際使用 Apple 的翻譯與文字模型，仍需在你的 iPad 測試。模擬器不能驗證裝置端翻譯的真實效果。

錄音／翻譯期間請保持 App 在前景。開始產生 AI 會議紀錄前需停止並完成錄音辨識；整理期間不能切换課堂或開始錄音，以降低重疊工作。此版沒有背景錄音、錄音播放、完整資料備份／還原或 PDF／Word 匯出。

舊版保存格式可讀取；但新匯入的 Playground／獨立 App 可能使用不同資料容器，既有錄音與模型不會自動搬過來。不要先刪除舊專案。

## 驗證

新增資料測試涵蓋：舊版檔案相容、譯文與原文對應、編輯後譯文失效、追加錄音後整理過期、長文 Unicode 分段不漏字，以及翻譯／整理保存後重開。

雲端建置與畫面啟動測試通過，也不代表已驗證真機的模型下載、錄音延遲、中英準確率、翻譯或 Apple Intelligence 推論。本版真機建議用同一段一分鐘中英錄音，比較草稿速度、翻譯延遲與完成後的保存內容。

## 參考

- [InkNote AI 官網](https://www.inknoteai.com/)：使用者指定的錄音與雙語字幕流程參考。
- [Apple Translation API](https://developer.apple.com/videos/play/wwdc2024/10117/)：翻譯工作綁定 SwiftUI view、語言下载、分批處理和模擬器限制。
- [Apple Foundation Models](https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models)：裝置端模型可用性與文字生成。
- [WhisperKit AudioStreamTranscriber](https://github.com/argmaxinc/argmax-oss-swift/blob/main/Sources/WhisperKit/Core/Audio/AudioStreamTranscriber.swift)：原文草稿與確認段落。

私人安裝繼續採用 [Windows／iPad 安裝說明](PRIVATE_INSTALL.zh-Hant.md)，不用公開上架 App Store。
