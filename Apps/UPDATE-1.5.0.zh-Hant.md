# 1.5.0：通用 IPA、音訊檔案與字幕改善

[免登入直接下載 iPhone／iPad 通用 IPA](../Deliverables/LectureTranscriber-1.5.0-unsigned.ipa) · [下載 iPad Playground ZIP](https://raw.githubusercontent.com/peijungwu0302-Wu/argmax-oss-swift-playground/249462051612488fcc093788d75c214ee2564487/Deliverables/LectureTranscriber.zip) · [全部測試結果](https://github.com/peijungwu0302-Wu/argmax-oss-swift-playground/actions/runs/34414929516)

## 同一份 IPA 更新 iPhone／iPad

本版為 1.5.0，build 10。iPhone 與 iPad 共用原始碼、IPA 和 `com.peijungwu0302.lecturetranscriber`；沒有加入小工具、通知服務或其他 App Extension。打包程式會檢查 Bundle ID、裝置家族 `[1, 2]`、圖示、背景音訊與無擴充套件。

IPA 沒有 Apple 簽章，需由 Windows／AltStore 等私人簽署流程安裝。公開下載檔本身就是 `LectureTranscriber-1.5.0-unsigned.ipa`，不需登入 GitHub 或再解開外層 artifact ZIP。請用相同 Apple 帳號、相同簽署工具和相同識別設定更新原 App。不要換 Bundle ID 做分身，也不要先刪除有重要錄音的 App。簽署工具可能修改最終識別碼，不能只看原始碼就保證與你目前安裝的 App 相同。

穩定 Bundle ID 可避免因每版改名而產生不同 App，但無法取消平台限制。免費帳號通常是每台裝置最多 3 個側載 App、簽署有效期 7 天；App IDs 另有同時最多 10 個、約一週到期的限制。這個 App 本身只有一個識別碼，每台安裝占一個 App 位置。來源：[AltStore 使用說明](https://faq.altstore.io/altstore-classic/your-altstore)、[App IDs](https://faq.altstore.io/altstore-classic/app-ids)。

Playground 與獨立 IPA 的資料容器分開，不會自動帶入舊錄音。先從舊版本匯出音訊和逐字稿，再更新／轉移；本版可匯入音訊重新辨識，還不是整堂課的 JSON、標記、會議紀錄完整備份還原。

## 本機課堂與匯入

- 「歷史紀錄 → 本機課堂」顯示每堂課實際音訊檔案合計大小，不用錄音時長估算；不包含模型、逐字稿與暫存匯出檔。
- 點課堂名稱開啟逐字稿；點旁邊的音訊入口，查看每個停止／繼續形成的片段，包含開始時間、長度、格式、大小，並可播放、暫停及分享。
- 主畫面「匯出 → 錄音檔案：播放與分享」也可開啟目前課堂音訊。舊 `.pcm`／`.pcm16` 會暫時轉為通用 WAV；`.m4a` 直接播放和分享。分享以片段為單位，尚未自動合併整堂課。
- 「本機課堂 → 匯入音訊」選取 WAV、M4A、MP3 或舊 PCM 音訊。程式在本機以小批緩衝讀取，轉為 16 kHz 單聲道，建立新課堂；外部原檔不修改、不上傳伺服器。某些受保護或系統不支援的格式會顯示錯誤。
- 匯入後按「補辨識」，使用目前選擇的引擎與語言；完成後依選定的 AAC 品質壓縮保存。匯入期間需要辨識用 PCM 暫存空間，長音訊請保持 App 在前景。

## SenseVoice 與翻譯跳動

你提供的 SenseVoice 輸出幾乎每 12 秒成一段；程式原本的最長視窗正是 12 秒。背景音樂可能高於固定靜音門檻，讓停頓偵測長期無法觸發。這次新增相對音量的停頓判斷；到達上限時，如存在較低音量區間，優先在該處切開，保留後續音訊供下一輪辨識。均勻音訊仍保留有界的 12 秒上限，避免無限累積。

翻譯在草稿改字、轉為定稿時，原本可能清空。新版嚴格區分當前翻譯與先前結果：等待新結果時保留上一則並顯示「更新中 · 上次翻譯」，不把舊翻譯保存成新段落的翻譯。這降低空白閃跳，但沒有把離線 SenseVoice 變成原生串流引擎，也不保證所有音樂中切點都準確。

Apple 引擎提供自己的結果區間，SenseVoice 目前標示音訊視窗時間，YouTube 又有另一組字幕切點；三者時間戳不能直接當成逐字對齊來比較。

從你提供的文字可見，這段純英文素材中 Apple 保留較多內容；SenseVoice 的 Safari 句子與螢幕材質描述有漏辨。這不否定它對你中英混說更實用，但也不能只靠調切點保證修正全部漏字。你提供的是兩次錄音後的文字，而非同一音訊檔，我尚未用原音重跑，所以沒有宣稱本版已修復該影片的錯誤率。

最有用的比較方式：把同一個音訊檔分別匯入新課堂，用 Apple 英文、SenseVoice 自動辨識，比較漏句與翻譯延遲；避免兩次外放收音差異干擾結果。

## 日文翻譯

「錄音設定 → 翻譯來源語言」新增「日文 → 中文」，可搭配 SenseVoice 自動辨識。預設「英文 → 中文」維持中英混說中保留中文、翻譯英文的做法。來源切換會重新翻譯已有段落，需要系統的對應翻譯語言資源；目前是手動選英文或日文來源，不是中英日任意混說的自動翻譯路由。

翻譯來源會隨課堂保存，匯入音訊也沿用選擇。日文實際準確率及裝置端翻譯，仍需真機測試。

## 背景與 Slide Over

IPA 加入 `UIBackgroundModes = audio`，並允許 iPad 視窗使用。已在前景開始錄音後：

| 狀態 | 本版行為 |
|---|---|
| 字幕視窗仍可見，例如 iPad 並排／Slide Over | 繼續收音、辨識和翻譯 |
| IPA 完全進入背景／鎖屏 | 持續保存錄音，暫停送入新音訊做辨識與翻譯；回到視窗後追上未處理的音訊 |
| Swift Playgrounds 進入背景 | 暫停保存，返回後補辨識 |
| 來電、麥克風中斷、系統終止 App | 可能停止；已有音訊保留，返回後確認並補辨識 |

[Apple record 類別文件](https://developer.apple.com/documentation/avfaudio/avaudiosession/category-swift.struct/record) 說明背景錄音需要 `audio` 模式；宣告能力不代表已在使用者裝置完成實測。

iPadOS 26.2 以後支援將一個視窗設為 Slide Over。可先在系統選用 Windowed Apps，開啟本 App 的「精簡字幕」，再使用視窗控制選單／Dock 的 Slide Over 操作與 Goodnotes 配合。參考 [Apple iPadOS 26 多工說明](https://support.apple.com/en-us/125309)。iPhone 可裝相同 IPA 與測試背景收音，但沒有 iPad 的 Slide Over；本版未加入 PiP 浮動字幕。

真機建議先做短測：錄音 30 秒 → 與 Goodnotes 並排／Slide Over 30 秒 → 完全切到背景 30 秒 → 返回並等待補完 → 停止。檢查音訊播放是否連續、長度是否接近 90 秒。長課堂前再測來電與鎖屏，不能只看編譯成功就當作背景可靠性通過。

## 可自行修改的會議紀錄提示詞

流程是「音訊 → 辨識逐字稿 → 分段文字 → Apple Intelligence 整理」，每段使用獨立上下文，最後合併各段筆記；目前沒有再做跨段全局去重。這由 Apple Foundation Models 處理，不是 SenseVoice 直接產生會議紀錄。Apple Intelligence 不可用時退回附時間戳的原文整理，不會假裝產生 AI 摘要。

進入「會議紀錄」，可直接編輯最多 800 字的整理偏好，保存到這台裝置，下次整理會沿用，也可恢復預設。輸出會保存本次使用的提示詞。提示詞控制筆記格式與重點；語音辨識仍由選定的語音模型處理。

可用範例：

> 用繁體中文按主題整理課堂筆記，保留英文術語及來源時間戳。列出定義、老師的例子與待釐清問題；只依逐字稿，不補寫未提及的數字或結論。最後列出三個複習問題，答案必須能在原文找到。

辨識漏掉的內容不會因整理而恢復；AI 輸出需要回看原文。參考 [Apple LanguageModelSession](https://developer.apple.com/documentation/foundationmodels/languagemodelsession)。

## 驗證狀態

程式版本 `249462051612488fcc093788d75c214ee2564487` 的 [GitHub Actions 34414929516](https://github.com/peijungwu0302-Wu/argmax-oss-swift-playground/actions/runs/34414929516) 三個工作全部通過：

- `ios-build`：資料保存、匯出與 SenseVoice 分段邊界檢查；macOS AAC／PCM／WAV 轉換及立體聲降混取樣；iOS 編譯；iPad 模擬器 5 項功能測試與 1 項介面測試；通用裝置版本編譯及 IPA 封裝。
- 模擬器功能測試包含實際 Core ML SenseVoice 公開中英音訊、匯入後建立可補辨識課堂且保留原檔、音訊格式讀寫、翻譯與來源對應，以及實際安裝 App 的 Bundle ID、版本、裝置家族與背景音訊宣告。介面測試涵蓋啟動畫面、設定與歷史入口。
- `sensevoice-native`：macOS Core ML 載入公開雙語音訊，檢查自動／中文／英文選項及逐步增加音訊的輸出；不等同標準錯誤率或 iPad 延遲評測。
- `playground-package`：App Playground 套件的 Apple SDK 編譯與模擬器啟動；沒有代替 iPad 上 Swift Playgrounds 本身的套件解析及操作測試。

[IPA artifact](https://github.com/peijungwu0302-Wu/argmax-oss-swift-playground/actions/runs/34414929516/artifacts/10128984622) 的外層 ZIP 為 2,244,295 bytes，需登入 GitHub 下載；模型首次使用另行下載，未包在 IPA。封裝檢查通過固定 Bundle ID、iPhone／iPad 裝置家族、1.5.0／build 10、背景音訊、圖示、無 App Extension 及 ZIP 完整性。

Windows 本機另完成 19 個 Swift 檔案的語法檢查、17 項 ZIP 內容完整性與 `git diff --check`。Playground ZIP 的 SHA-256：

```text
320127e0fa2fbab2270d0b25f7b75f9ec7a444980b6d26ea7b70cd9d2b5e8f37
```

尚未實測你的 M2 iPad／iPhone 15 Pro 麥克風、背景／Slide Over、日文翻譯或這段 YouTube 原音。本次雲端模型測試使用 FP32 模擬器／macOS 路徑，不能代替真機 INT8／Neural Engine 表現；沒有宣稱已達到即時字幕的固定延遲或漏字率目標。
