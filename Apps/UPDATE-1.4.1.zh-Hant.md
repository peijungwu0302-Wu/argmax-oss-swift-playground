# 1.4.1：修復 iPad Playgrounds 的 unzip 套件錯誤

[下載 1.4.1 完整 iPad ZIP](https://raw.githubusercontent.com/peijungwu0302-Wu/argmax-oss-swift-playground/8c795eaa74d905caa87c1e93429f69da1b1bf3b4/Deliverables/LectureTranscriber.zip)

## 原因與修正

1.4.0 使用 sherpa-onnx／ONNX Runtime 的遠端二進位 XCFramework 套件。使用者的 Swift Playgrounds 4.7 在套件解析時報 `could not find executable for 'unzip'`，所以還沒執行 App 就失敗。Xcode 在 macOS 有不同的套件工具環境；先前的雲端編譯、iOS 模擬器推論和啟動成功，都沒有涵蓋 iPad Playgrounds 本身的依賴解析。先前將測試結果延伸成可直接在 iPad 開啟的說明不夠準確。

本版已移除這兩項套件依賴，將 SenseVoice 改接 **系統 Core ML＋Swift 原始碼**。模型逐檔下載並校驗 SHA-256，不下載模型 ZIP，也不啟動 unzip。保留 Apple、WhisperKit、錄音壓縮、字幕、翻譯和歷史紀錄功能。

下載包包含 1024×1024 的 `AppIcon.png`，與 1.4.0 的圖示內容相同。灰色縮圖不能證明圖示檔不見；套件解析失敗可能讓產品資訊或縮圖無法完成載入。這次應先解決明確的套件錯誤，毋須重新製作圖示。

## 如何更新與試錄

1. 保留舊 Playground 和重要逐字稿。下載新版完整 ZIP，解壓後用 Swift Playgrounds 開啟 `LectureTranscriber.swiftpm`；不要把它加入舊專案的 Packages。
2. 新版設定應顯示 **SenseVoice Core ML · 中英混說實驗版**。如果仍看到 sherpa-onnx／onnxruntime 套件的錯誤，請確認開啟的是新版解壓後的專案，而不是 `LectureTranscriber 5` 舊副本。
3. 先確認 Apple 模式能開啟，再到設定選 SenseVoice Core ML、載入模型。iPad 的 INT8 權重、前處理與詞表合計約 **240 MB**，首次需要網路與等待模型準備。
4. 先以「自動」試錄同一段中英混說；再比較「中文為主／英文為主」。主要語言提示可能改善，也可能降低準確度。Apple 錄音中仍可直接切換中文／English，不需先暫停；SenseVoice 的語言提示在停止狀態選擇。
5. 若 Core ML 載入或推論失敗，App 會顯示原因並保留已錄音訊，不會把無效數值定稿。可先改用 Apple／WhisperKit。

本版仍需要保持 App 前景；沒有新增背景錄音或跨 App PiP 字幕。

## SenseVoice 版本與測試界線

使用 [FluidInference 的 SenseVoice Core ML 轉換](https://huggingface.co/FluidInference/sensevoice-small-coreml)，固定版本 `cdea3526163035c19915d4a10268992d018ebd46`。Swift 前後處理依其 [SenseVoice 實作](https://github.com/FluidInference/FluidAudio/tree/main/Sources/FluidAudio/ASR/SenseVoice) 調整，附 Apache-2.0 授權聲明；沒有將整個 FluidAudio SDK 加入依賴。

- iPad 真機：INT8 權重的 Core ML 編碼器，指定 `.cpuAndNeuralEngine`；前處理使用 FP32／CPU。
- macOS／iOS 模擬器測試：FP32／CPU 模型約 944 MB，避免已知 FP16／CPU 無效數值問題。這個較大的模型不會在你的 M2 iPad 上自動下載。
- 同一模型發布者說明，INT8／FP16 圖需要 Neural Engine，CPU 回退可能出現 NaN。本版逐一檢查用於辨識的輸出數值；遇到無效數值會停止辨識並保留音訊。
- 實際輸入尺寸取自模型，沒有假定 FP32 與 INT8 支援相同視窗。保留約 2 秒後開始更新草稿、停頓提交與最長 12 秒分段的策略。
- 這是新的轉換與數值精度，不能把 1.4.0 ONNX 測試的速度或準確率直接套用。沒有測過你的 M2 Neural Engine、課堂收音和長時間發熱，就不宣稱它已達到理想即時字幕效果。

## 鍵盤聽寫與 Apple 雙語的研究結果

Apple 的 [DictationTranscriber 官方文件](https://developer.apple.com/documentation/speech/dictationtranscriber) 明確說它使用與系統聽寫／裝置端 SFSpeechRecognizer 相同的模型。它與本 App 現有的 `SpeechTranscriber` 是不同的公開辨識模組，因此你觀察到的差異值得測試。

但 `DictationTranscriber` 的初始化仍指定單一 locale。公開文件並未保證它能複製鍵盤內部的語言選擇與句內中英混說效果；加中文和英文鍵盤，也不會直接改變 App 已建立的 `SpeechTranscriber(locale:)` 設定。

兩種可比較的做法：

| 做法 | 優點 | 限制 |
|---|---|---|
| 新增 DictationTranscriber 實驗引擎 | 可接錄音音訊、逐段時間與 App 既有字幕流程；支援詞彙提示 | 需要測試中文／英文 locale 的混說表現，不能預先保證與鍵盤一樣 |
| 在 App 輸入框使用系統鍵盤麥克風 | 直接使用你觀察到的鍵盤聽寫體驗 | 使用者需要操作鍵盤；不是可自由送入錄音的轉錄 API，沒有本 App 所需的原始音訊與逐字時間資訊 |

[Apple 鍵盤聽寫說明](https://support.apple.com/guide/iphone/dictate-text-iph2c0651d2/ios)。詞彙提示可以提高專有名詞被選中的機會，不能視為任意雙語混說已解決。本版先修復開啟與 SenseVoice，相應的 DictationTranscriber 引擎尚未加入選單。

## 使用者提供的 SenseVoice 文章

已讀取 [Whisper Notes 的 SenseVoice 文章](https://whispernotes.app/zh-Hant/blog/sensevoice-fastest-cjk-transcription)。文中 52–118 倍即時是 M4 Pro 使用 MLX 處理整段音訊的吞吐量，不是 M2 iPad 上從說話到字幕出現的延遲。文章也明寫不支援串流。其模型約 827 MB；本版 Core ML INT8 約 240 MB，轉換與數值精度不同，不能直接套用速度或準確率。

[SenseVoice 官方專案](https://github.com/QwenAudio/SenseVoice) 確认 Small 支援中文、英文、粵語、日文與韓文。支援兩種語言與同一句混說準確，是兩個需要分開測量的問題。我們採短視窗重辨識來更新草稿，再在停頓處提交；這會有等待上下文、切分與重算成本。短視窗速度、定稿穩定性、翻譯延遲，仍需在實機各自測量。

另外兩個 CSDN 網址讀取受阻，知乎網址逾時；未將這三篇內容視為已核對證據。

## 完成的驗證

[GitHub Actions 34406251212](https://github.com/peijungwu0302-Wu/argmax-oss-swift-playground/actions/runs/34406251212) 的三個工作全部成功，測試原始碼提交為 `8c795ea`：

- Playground 專案在 Xcode 中完成實機目標編譯、模擬器編譯、安裝及啟動；通過無遠端二進位套件依賴檢查。
- iOS 模擬器通過 3 項邏輯測試：字幕翻譯來源一致性、PCM16／AAC 32/64 kbps 轉換回讀、Core ML SenseVoice 公開混說音訊實際推論；另通過主畫面與歷史紀錄 UI 測試。
- macOS 通過儲存與匯出、AAC 驗證，以及下列 Core ML 雙語和分段收尾測試。

iOS 的 SenseVoice 整項測試耗時 239.083 秒，包含下載約 944 MB 測試模型、首次準備和推論，**不能當成單次字幕延遲**。以上仍沒有測到 iPad Swift Playgrounds 自己的套件解析器與 M2 上的 INT8／Neural Engine 路徑；需要在真機開啟新版與試錄確認。

## 本版公開雙語音訊測試

macOS Core ML FP32／CPU 已完成真實模型下載、初始化、三種語言提示及逐步送入音訊的分段收尾測試。約 10 秒公開混說樣本的整段輸出如下（保留實際錯字）：

| 設定 | 實際輸出 |
|---|---|
| 自動 | 昨天是monday，today is禮2.the day after tomorrow是星期三。 |
| 中文為主 | 昨天是monday，today is禮拜2，the day after tomorrow是星期三。 |
| 英文為主 | Z是MdayTodayday is Liba.the day after tomorrow是星3. |

分段收尾測試每次只提供當時已收到的音訊前綴，不預先讀取後面的聲音；檢查有中英文輸出、模型能執行、最後音訊全部被處理；**不是準確率達標測試**。英文為主的輸出明顯較差，不能因 CI 通過就宣稱混說已解決。這個樣本優先試中文為主，但不能推論所有課堂都如此。

[測試紀錄與 JSON artifact](https://github.com/peijungwu0302-Wu/argmax-oss-swift-playground/actions/runs/34406251212/artifacts/10125675165)。測試音訊來自 sherpa-onnx 公開雙語模型的 `test_wavs/0.wav`，不是使用者的課堂錄音。

ZIP 的 16 個檔案已逐檔核對原始碼、圖示與授權檔；GitHub 下載副本 SHA-256：`260d4b1dad1e0b6926cc5dfe93311bb6deb7fdf873694a3145a03370e6922b36`。

## iPhone 保持 1.4.0

依先前約定，這次先修 iPad Playground，**不另發布新的 iPhone IPA**。上一版已建好的 [1.4.0 通用 IPA](https://github.com/peijungwu0302-Wu/argmax-oss-swift-playground/actions/runs/34402552126/artifacts/10124084089) 仍使用 ONNX SenseVoice，私人簽署安裝不會在 iPad 上執行 SwiftPM 的 unzip 步驟。GitHub 的新原始碼不會自動更新手機已安裝的版本。

同一份核心程式仍保留 iPhone 裝置支援，等 iPad 實測穩定後再製作新手機安裝檔。[Windows 私人安裝說明](PRIVATE_INSTALL.zh-Hant.md)。
