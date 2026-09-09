# 課堂逐字稿 1.3：Apple 即時語音與 CC 字幕

## 使用方式

保留目前可使用的 Playground 與重要匯出檔，再解壓新版 ZIP，用 Swift Playgrounds 開啟 `LectureTranscriber.swiftpm`。這是完整專案，不用手動新增套件。

1. 新課堂預設使用 **Apple 即時語音**。右上角「錄音設定」可切換為 WhisperKit，保留 Turbo 模型選項。歷史課堂保留原本的引擎；停止後也可以切換引擎再繼續。
2. 選「中英夾雜」後，下面會出現 **中文為主／英文為主**。例如中文講解生物、夾雜英文術語選前者；英文授課、偶爾補充中文選後者。停止後可以修改主要語言。
3. 先載入語音模型，再開啟「即時翻譯字幕」準備翻譯語言。兩種模型的首次下載彼此獨立。Apple 引擎必須確認裝置及所選語言支援，若不支援會明確提示，可切回 WhisperKit。
4. 按開始錄音。右上角 CC 按鈕開關字幕模式；開啟時底部固定顯示最新兩行原文及中文翻譯，完整逐字稿仍在上方保存。字幕草稿可能修正，不需等到定稿才顯示。
5. 停止後等尾段處理完畢，再分享或產生會議整理。App 仍需要保持前景；背景錄音、播放和完整資料搬移尚未包含。

## 可以用 Apple 備忘錄的底層引擎嗎？

可以使用 Apple 公開的 `SpeechAnalyzer` 與 `SpeechTranscriber`，不是操控備忘錄 App，也不是使用私有 API。Apple 在 WWDC25 說明這項技術用於 Notes、Voice Memos 等 App 的轉錄。本版新增此路線，使用 `timeIndexedProgressiveTranscription`：持續送入音訊、接收暫時結果與最終結果。

- 需要 iPadOS 26，以及系統回報支援的裝置和語言。中文向系統要求 `zh-TW`，英文要求 `en-US`，不會偷偷把不支援的繁體中文改為其他地區。
- 語音模型與 Apple Intelligence 的摘要模型是不同資源。語音路線不會因為沒有開啟 Apple Intelligence 而主動禁止使用；是否可用依 SpeechTranscriber 的檢查與實際模型載入結果。
- 不保證拿到和備忘錄完全一樣的產品調校或混說品質。本版每次仍指定一個主要語言，不是中英文兩套辨識同時投票。
- 實作使用已有的本機 PCM 錄音，以小塊音訊持續送入 Apple 引擎，輸入佇列有容量上限；輸入過快時等候，不丟棄音訊。最終結果才推進可恢復的保存位置，停止時等待尾段完成。

[Apple 官方介绍](https://developer.apple.com/videos/play/wwdc2025/277/)／[SpeechTranscriber 預設模式](https://developer.apple.com/documentation/speech/speechtranscriber/preset)

## 原本為什麼慢、混說為什麼差？

舊版以音訊視窗重複解碼，常要等整個段落穩定；原有條件包含 12 秒視窗與兩秒尾部語境。段落邊界若一直改變，提早确认就不容易成立。翻譯再等待定稿，延遲會累加。

原本「中英夾雜」只把 Whisper 的主要語言固定為中文，並插入一個範例句。它不是專用的双語辨識器，也沒有獨立的語言切換模型。這個選項的名稱過度暗示效果。本版新增主要語言選擇，移除該範例句；混說時也不把之前的辨識文字反覆當提示，降低錯字自我強化。這些是修正策略，不是混說準確率已達標的證據。

WhisperKit 路線另外調整：

- 模型支援時啟用字詞時間戳，比较兩次結果共同的前綴；保留最後兩個相同字詞與約 0.8 秒後續語境供修正，不必等待整句完全一致。
- 偵測約 600 ms 的低能量尾部停頓，在短句結束時確認。這是能量判斷，不是訓練好的神經 VAD；噪音、輕聲和猶豫仍可能影響切分。
- 新視窗保留前面約 250 ms 的音訊，再按字詞時間排除已確認內容，降低直接切掉字頭的風險。字詞對齊本身也可能不準。
- 短的已確認前綴會合併成可讀段落，到標點、停頓或長度上限再分開；段落增長後譯文會重新更新。
- 即時解碼不做額外 temperature fallback；停止後仍保留補完機制。支援字詞對齊需要額外計算，不能預先保證 Turbo 每輪都更快。

## 即時翻譯改了什麼？

舊的定稿翻譯與最新草稿現在輪流處理，避免新字幕一直排在全部舊段落後面。草稿每約一秒可嘗試一次翻譯，但這是排程間隔，並非一秒內完成的承諾。

同一短句繼續增加文字時，可先顯示前綴的翻譯；如果原文被修改、換到另一句或另一堂課，舊結果會捨棄。正式匯出只包含完成的段落翻譯。這仍是「先語音轉文字，再英翻中」，兩段推論的時間會相加。

目前翻譯方向固定為英文 → 繁體中文，中文保留原文；還沒有中文 → 英文切換。Apple Translation 首次需下載語言，之後在裝置上執行。語音辨識錯字仍會傳到翻譯；翻譯不能修復聽錯的原文。混說內容按英文片段翻譯，跨語言句子的完整語境仍是限制。[Apple Translation 官方說明](https://developer.apple.com/videos/play/wwdc2024/10117/)

## Whisper Notes 與中英模型選擇

[Whisper Notes 官網 FAQ 14](https://whispernotes.app/zh-Hant) 明確說明：目前是錄完後才轉錄，轉錄時文字逐步出現，並非邊錄邊辨識。其整份檔案的處理速度，不能直接代表即時字幕的首字延遲。官網的 Parakeet V3 支援範圍為 25 種歐洲語言，不適合只有中文與英文的需求；Qwen3-ASR 1.7B Beta 則列為 Mac DMG 版本功能，不能當作 iPhone 已有的選項。

| 路線 | 適合的用途 | 目前的限制 |
|---|---|---|
| Apple SpeechAnalyzer／SpeechTranscriber | 優先在 M2 iPad 和 iPhone 15 Pro 測試連續字幕；本版已接入 | 需要 OS 26 與系統支援的語言；選主要語言不保證混說正確 |
| 中英 streaming Zipformer，經 sherpa-onnx | 下一個值得比較的真正串流中英模型，可用 Swift 包装 | 本次先在 Windows 測試，尚未接入 App；不能推算 iPhone 速度 |
| 中英 streaming Paraformer，經 sherpa-onnx | 另一個真正串流中英候選 | 官方列明不提供時間戳；若使用，需補上字幕時間軸策略 |
| SenseVoiceSmall | 中文／英文短句辨識、停止後的校正候選 | 原模型不是原生串流；切短音訊做近即時辨識需要另設計切句與上下文 |
| Whisper Large v3 Turbo | 保留目前可用的辨識基準 | 重複視窗解碼與確認會增加延遲；尚未實作自動第二輪全場校正 |

模型大小不等於混說品質。是否更適合臺灣口音、英文專有名詞和教室收音，應以相同原始錄音比較。候選來源：[Zipformer](https://k2-fsa.github.io/sherpa/onnx/pretrained_models/online-transducer/zipformer-transducer-models.html)、[Paraformer](https://k2-fsa.github.io/sherpa/onnx/pretrained_models/online-paraformer/paraformer-models.html)、[SenseVoice](https://github.com/QwenAudio/SenseVoice)。

iPhone 15 Pro 可作為第二部測試裝置；本 App 的 Apple 語音路線同樣需要 iOS 26。iPhone 不能用 Swift Playgrounds 開啟這份 `.swiftpm`，需使用雲端編譯產生的 IPA，再從 Windows 簽署側載。這不需要公開上架 App Store，詳見 [私人安裝說明](PRIVATE_INSTALL.zh-Hant.md)。目前的 UI 自動測試裝置為 iPad 模擬器，尚未代表 iPhone 真機通過。

## InkNote 的 2.4 GB 和跨平台代表什麼？

[InkNote 官網](https://www.inknoteai.com/) 註明約 **2.4 GB 是首次下載的 AI 引擎，語音會議模型另行下載**。它不是「一個 2.4 GB 語音模型就包辦辨識、翻譯和整理」。官網未公開足夠資訊，無法確認它目前各平台的模型名稱、量化方式、串流切句策略或延遲。

檔案大小、執行時記憶體和每秒處理速度是三件事。量化可以減少模型權重所需空間；執行時還需要快取與工作緩衝。2.4 GB 不是 iPad 無法載入的固定上限，也不能依檔案大小判斷它一定比 Turbo 快。

模型可由各平台的推論程式執行。例如 [whisper.cpp](https://github.com/ggml-org/whisper.cpp) 支援 iOS、Android、Windows，並支援量化；[llama.cpp](https://github.com/ggml-org/llama.cpp) 也提供跨平台的文字模型執行方式。這些是跨平台可行性的例子，不是 InkNote 使用它們的查證結論。我們現在的 SwiftUI、Apple Speech、Apple Translation 不能原封不動跑到 Android。

## 和你期待的產品仍有什麼差距？

| 項目 | 1.3 現況 | 仍需要的工作 |
|---|---|---|
| 連續字幕 | Apple 串流與 Whisper 字詞確認、CC 最新兩行 | M2 真機首字時間、長課堂延遲與發熱測試 |
| 中英夾雜 | 可選主要語言，兩種引擎比較 | 同一組真實雙語音訊評測；必要時更換辨識模型，不能只靠 UI 選項 |
| 中文翻譯 | 裝置端英翻中、草稿與定稿交替處理 | 名詞、語境和長句品質；字幕延遲需真機測量 |
| 會議整理 | Apple Intelligence 可用時分段摘要；否則原文整理 | 全場統整、說話者分離、可追溯的決議／待辦核對 |
| 完整產品 | 保存、刪除、編輯、文字／字幕／翻譯分享 | 錄音播放、備份還原、背景錄音、Word／PDF 等 |
| 平台 | iPad／iPhone 原生 App | Android 專案與相容的辨識、翻譯執行方式 |

YouTube 的已上傳影片可以先處理或提供字幕，再依時間播放；即時錄音需要先等聲音發生。YouTube 本身也區分直播字幕與影片字幕，並非所有 CC 都是在觀眾裝置即時辨識。[YouTube 官方說明](https://support.google.com/youtube/answer/6373554)

## 測試與界線

已另外完成兩個中英串流模型的 Windows 實際推論，見 [第一輪實測報告](MODEL-BENCHMARK.zh-Hant.md)。它包含逐次文字更新與時間紀錄，尚不包含 Apple 裝置或翻譯測速。

自動測試涵蓋主要語言對應、舊資料相容、字詞確認、短暫停頓、重疊音訊去重、字幕兩行顯示、翻譯失效與保存；Apple 雲端負責實際 iOS 編譯及 UI 啟動。這不等於已在你的 iPad 執行 Apple 語音模型、翻譯或中英混說評測。

程式版本 `9a55160b2e7616feb01dff3ad37a20cfd7401a2f` 的 [GitHub Actions 測試](https://github.com/peijungwu0302-Wu/argmax-oss-swift-playground/actions/runs/34385950643) 兩項工作皆成功：實際 Playground 的裝置與模擬器編譯／啟動，以及資料邏輯測試與 iPad UI 測試。產出的 IPA 尚未簽署。

建議在 iPad 用相同內容各測一次 Apple 與 Turbo：中文為主 30 秒、英文為主 30 秒，包含相同專有名詞；比較第一個字幕出現時間、停頓後多久定稿、英文詞是否保留。兩引擎皆不理想時，下一步是以這組音訊選模型，而非繼續縮短 UI 刷新間隔。
