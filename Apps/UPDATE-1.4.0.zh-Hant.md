> 更新：1.4.0 ZIP 在 iPad Playgrounds 4.7 會遇到二進位套件 unzip 錯誤。請改用 [1.4.1 修復包](UPDATE-1.4.1.zh-Hant.md)。以下為歷史版本紀錄；1.4.0 私人安裝 IPA 保留。

# 1.4.0：SenseVoice 中英混說實驗版、字幕／翻譯修正與錄音品質

## 開始實測

1. [下載完整 1.4.0 iPad ZIP](https://github.com/peijungwu0302-Wu/argmax-oss-swift-playground/raw/38e9896ea04c8715a0c1695499297f001f02b360/Deliverables/LectureTranscriber.zip)，解壓後用 Swift Playgrounds 開啟 `.swiftpm`；保留舊版並先匯出重要逐字稿。
2. 「錄音設定 → 辨識引擎 → SenseVoice」，先按「載入模型」。首次需網路，約 240 MB。
3. 回到主畫面先用「自動」，錄一段 30～60 秒中文中夾英文術語的聲音，再按停止並儲存。比較草稿、定稿及翻譯。
4. SenseVoice 的語言提示需在停止狀態選擇；錄音中要中英夾雜不需要來回切換，保持自動即可。Apple 的「中文／English」則可以錄音中直接切換。
5. iPhone 下載同一次 [測試與安裝檔](https://github.com/peijungwu0302-Wu/argmax-oss-swift-playground/actions/runs/34402552126) 的 `LectureTranscriber-unsigned-IPA`，依 [Windows 私人安裝](PRIVATE_INSTALL.zh-Hant.md) 簽署。iPhone 不能使用 Swift Playgrounds。

ZIP SHA-256：`b39b5c75808e222791909232ed84af3f44072c348dbba9c82441bcb948fc67c7`。同一 ZIP 包含 15 個檔案；套件與語言模型會另外下載。IPA 是通用 iPhone／iPad 版本，但尚未私人簽署；GitHub 測試產物有保存期限，下載後請自行保留。

## 已實作

- 翻譯草稿以「課堂、辨識階段、音訊位置、文字」識別，重複說同一句也會再次翻譯。
- 中文／英文切換及回到前景會重建翻譯工作，先前工作的回覆不能覆蓋新字幕。
- 單一段落翻譯失敗會等待重試，後面的段落可以繼續；語言資源準備失敗時可按「重試翻譯」。
- 即時字幕只顯示與目前原文相符的翻譯，不再把上一句已完成的翻譯配到新句子。
- 舊段落的 Apple 定稿不會清除較新的字幕草稿；已定稿區間的重複回覆不會再次新增逐字稿。
- 同一逐字稿段落持續變長時，「跟隨最新」也會更新捲動。

以上修正針對程式中確認存在的狀態問題，不代表已在使用者的 iPad／iPhone 上確認所有翻譯中斷都消失。

## 錄音品質怎麼選

在「錄音設定 → 錄音儲存品質」選擇，可在停止狀態改變接下來的錄音片段。

| 選項 | 停止並處理完成後約用量 | 適用 |
|---|---:|---|
| 省空間 AAC 32 kbps（預設） | 14.4 MB／小時 | 主要保留課堂人聲，優先節省空間 |
| 標準 AAC 64 kbps | 28.8 MB／小時 | 希望保留較好的錄音聽感 |
| 不壓縮 PCM 16-bit | 115.2 MB／小時 | 保留未經有損壓縮的辨識音訊 |

以上使用十進位 MB，AAC 實際大小含容器開銷，可能不同。收音及辨識皆為 16 kHz 單聲道，並非音樂高傳真錄音模式；AAC 封存會轉成編碼器支援的 32 kHz，這不會增加原本的音訊細節。

**錄音中的暫存仍約 115 MB／小時。** 即時辨識讀取 PCM16；停止錄音、補完辨識後才在背景執行緒轉成 AAC，避免壓縮改變本次即時辨識輸入。壓縮時原始檔與成品會暫時同時存在；請保持 App 開啟到儲存完成。這一版沒有把錄音中的暫存降到 14 MB／小時。

壓縮後先讀回檢查開頭和尾端，再原子寫入新檔名，最後移除舊 PCM。任何前置步驟失敗都保留原始檔。先前的 Float32 `.pcm` 錄音仍能開啟及補辨識，不會自動壓縮或變更其內容。錄音中斷後需按「補辨識」完成處理，才能壓縮該片段。原本沒有設定品質的舊錄音保持原格式。

## 背景與私人安裝：目前界線

目前 `LectureController.backgrounded()` 明確執行停止錄音。這一版保留這項行為，所以不能把背景停止完全歸因於 Swift Playgrounds，也不能承諾「只換私人安裝就好了」。

真正持續背景錄音還需要宣告並設定背景音訊、處理系統音訊中斷、確認辨識引擎在背景的運作限制，以及長時間實機驗證。[Apple 錄音背景說明](https://developer.apple.com/documentation/avfaudio/avaudiosession/category-swift.struct/record)。本版未啟用背景持續錄音。

- iPad 可先讓精簡字幕與 Goodnotes 保持同時可見；[Apple 視窗／Slide Over 說明](https://support.apple.com/en-us/125309)。Playgrounds 容器的實際多工行為仍需裝置測試。
- [Swift Playgrounds 只提供 iPad 與 Mac](https://developer.apple.com/swift-playground/)，iPhone 不能直接開啟 `.swiftpm`。
- iPhone 15 Pro 可走本專案的 [Windows 私人安裝流程](PRIVATE_INSTALL.zh-Hant.md)，不需上架 App Store。Apple 即時辨識需要 iOS 26 與相應語言資源。
- 私人安裝本身不提供任意跨 App 浮動 UI。本版也没有 PiP 字幕功能。可先用 iPad 寫筆記、iPhone 保持 App 前景顯示字幕與中英切換。

## SenseVoice：已加入可選辨識引擎

「錄音設定 → 辨識引擎 → SenseVoice · 中英混說實驗版」，按載入模型。第一次約下載 **240 MB** 的 SenseVoiceSmall INT8 模型與詞表，完成後可離線辨識。模型檔大小不是運行時 RAM 用量；載入 SenseVoice 會先釋放 App 持有的 WhisperKit 模型。

建議先選 **自動**，使用同一段中英混說比較；也可選「中英夾雜 → 中文為主／英文為主」。這兩個設定分別將 `zh`／`en` 語言提示送給模型，自動為 `auto`。它们不會換成只能輸出單一語言的詞表，但提示可能影響結果，並不保證指定主要語言一定較準。中文輸出轉為繁體，英文保留。

本版使用官方 [sherpa-onnx 1.13.7 Swift Package](https://github.com/k2-fsa/sherpa-onnx/blob/v1.13.7/Package.swift) 的靜態執行庫，ONNX Runtime 1.28.1、CPU 2 執行緒。下載固定模型版本並核對 SHA-256。它是另一個辨識引擎，不是放入 WhisperKit 的模型檔。

原始 SenseVoiceSmall 並非原生串流模型：[模型官方说明](https://github.com/QwenAudio/SenseVoice)。目前先累積約 2 秒音訊，之後每累積約 1 秒新聲音便重新辨識草稿；運算較慢時更新也會變慢。偵測到約 0.6 秒停頓便提交那一段，保留後續聲音；沒有停頓時最長以 12 秒視窗提交，避免永遠卡在同一句。停止時會補完短尾段。

這仍是**分段重算的即時草稿**。長句沒有停頓時可能在 12 秒邊界切開；開始／結束時間是音訊片段範圍，沒有假造逐字時間戳。教室噪音可能讓能量式停頓判斷失準。本版沒有宣稱達到 YouTube CC 的穩定性或自動中英混說的課堂準確率。

先前 Windows 測試：四段 28.67 秒中英範例用 3.60 秒處理。這是完整音檔吞吐量，不能當作 iPad 的字幕延遲，也不是比 Whisper 快 7.96 倍。[方法與原始結果](MODEL-BENCHMARK.zh-Hant.md)。新版另外以 App 共用的 Swift／C 實作在 macOS 執行模型，測試三個語言設定、逐步供應音訊及尾段提交；仍不等同你的 M2／A17 Pro 實機。

## Apple 中英混說研究，以及要不要先暫停

**Apple 模式錄音時直接按「中文／English」，不必先按暫停。** 程式在按下時記錄語言分界，先完成旧語言的音訊，再接續新語言，麥克風音訊持續保存。建議在自然停頓處切換；初次下載語言資源可能造成明顯等待，所以正式上課前先各載入一次。

Apple 公開 `SpeechTranscriber` 以一個 `locale` 建立辨識器，官方沒有提供保證句內中英混辨的選項。[官方初始化介面](https://developer.apple.com/documentation/speech/speechtranscriber/init(locale:transcriptionoptions:reportingoptions:attributeoptions:))。

可研究的方向與限制：

| 方向 | 能改善什麼 | 尚未解決的事 |
|---|---|---|
| 現有手動中文／英文切換 | 整段語言改變；沿用你滿意的單語表現 | 同一句快速夾雜仍可能錯 |
| 中文與英文辨識器同時處理，再選擇候選 | 有機會辨認整段語言切換 | 兩份錯誤結果如何對齊與選擇，CPU／記憶體成本，句內混說仍無保證；本版未加入 |
| 課堂術語、專有名詞提示 | 提高已知名稱被選中的機率 | Apple 文件將 `AnalysisContext.contextualStrings` 的這項支援描述在 `DictationTranscriber`，不能直接承諾對目前 `SpeechTranscriber` 生效；另一引擎還需評估延遲與品質 |
| SenseVoice 混語辨識 | 直接讓支援中英的模型處理同一段聲音 | 需實際測試你的口音、術語、收音與長句 |

[Apple 詞彙提示文件](https://developer.apple.com/documentation/speech/analysiscontext/contextualstrings)、[DictationTranscriber 說明](https://developer.apple.com/documentation/speech/dictationtranscriber)。對已辨錯的文字做語言偵測不能還原漏掉的英文，不適合作為混語問題的根本修正。

## iPhone 與 iPad 共用版本

兩者共用這份 SwiftUI、錄音、模型、字幕、翻譯與儲存程式，私人安裝 IPA 也同時包含兩種裝置支援。修核心問題不需要做兩遍；但螢幕排版、耗電、發熱、記憶體與 Apple 資源可用性仍需要各自實機檢查，不能把額外成本說成零。

依目前優先順序，這版一起產生通用 IPA，先不加 iPhone 專屬功能或另開獨立手機版本。之後優先讓 iPad 流暢；目前這份已安裝的 iPhone App 不會因 GitHub 後續更新而自己改版，等你需要時才重新簽署安裝新版。

## 驗證範圍

新增測試涵蓋重複句子、切換後過期翻譯、較舊 Apple 定稿與較新草稿交錯、PCM16 量化與中斷恢復；iOS 音訊測試會實際編碼及解碼兩種 AAC 位元率，檢查尾端、訊號誤差及原始檔保留。

雲端編譯與模擬器測試無法代替實機 Apple Translation、麥克風收音、模型切換時間、課堂準確率、背景錄音或發熱測試。測試執行結果會在下載說明記錄。


### 本版執行紀錄

程式提交：`38e9896ea04c8715a0c1695499297f001f02b360`；[測試執行](https://github.com/peijungwu0302-Wu/argmax-oss-swift-playground/actions/runs/34402552126)。

- macOS 原生 SenseVoice：實際下載、驗證模型、測試自動／中文為主／英文為主，及逐步供應音訊後完整提交。
- iOS 模擬器原生 SenseVoice：實際下載與辨識 `0.wav`，輸出「昨天是monday，today is禮拜2，the day after tomorrow是星期三。」；測試耗時包含下載和初始化，不能當作字幕延遲。
- AAC 32／64 kbps：實際編碼、讀回、尾端取樣、訊號誤差和原始檔保留檢查。
- 字幕與翻譯：跨課堂／切換階段、重複句、舊定稿和新草稿交錯的狀態檢查。
- ZIP 的全部 15 個檔案已逐一比對提交內容，並核對 GitHub 上的 ZIP SHA-256。

這些是整合與回歸測試，不是中文／英文錯誤率測試。你自己的混說錄音尚未取得，真機翻譯、長時間課堂、溫度與電池測試仍需在裝置進行。
