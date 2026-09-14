[English](README.md) | [繁體中文](README.zh-TW.md)

> **課堂逐字稿 App 1.8.3 (Build 16) — 裝置聲音即時字幕 + 全域在地化**：iPhone／iPad 通用單一 IPA，支援 SideStore 個人免費憑證簽署側載（剛好 1 App + 1 Widget Extension，無額外 App ID 負擔）。支援 iOS/iPadOS 27+ 透過 ScreenCaptureKit 擷取系統裝置聲音即時字幕、裝置聲音零磁碟錄音保存（絕對不寫入任何 .wav/.m4a/.pcm16 音訊檔）、支援「僅即時顯示（不留紀錄）」與「僅保留文字稿（不存音檔）」兩種儲存模式、升級低延遲且穩定的原文與繁體中文翻譯（SegmentMerger 懸空子句智慧整併）、支援跨 App（GoodNotes／Safari／PDF 等）PiP 子母畫面即時字幕、鎖定畫面 Live Activity 與 iPhone 動態島、以及即時切換的全域在地化語系支援（系統預設／繁體中文／English）。
> [GitHub Release v1.8.3 下載 IPA](https://github.com/peijungwu0302-Wu/argmax-oss-swift-playground/releases/tag/v1.8.3) · [SideStore 安裝指南](Apps/PRIVATE_INSTALL.zh-Hant.md)

---

## 🎙️ 課堂逐字稿 (LectureTranscriber) v1.8.3 功能說明

**課堂逐字稿 (LectureTranscriber)** 是一款專為 iOS 與 iPadOS 設計的本機即時語音轉文字與即時翻譯工具。

### v1.8.3 重點更新

#### 1. 裝置聲音即時字幕（ScreenCaptureKit）
- **iOS/iPadOS 27+ 系統音訊擷取**：透過 ScreenCaptureKit 框架直接捕捉本機系統播放的聲音（如線上課程、影片、Podcast 等），無需外接麥克風或外放收音。
- **絕對零磁碟錄音寫入（隱私保證）**：裝置聲音音訊樣本僅在記憶體有限循環緩衝區（最多 30 秒）內供語音辨識模型處理，**絕對不會將任何音訊檔案（.wav、.m4a、.pcm16）寫入裝置磁碟儲存空間**。
- **兩種儲存模式可選**：
  - **僅即時顯示（預設）**：按下停止後，不儲存任何課堂紀錄、不保留文字稿、不產生任何音檔，完全零痕跡。
  - **僅保留文字稿**：辨識完成的即時逐字稿與中文翻譯會儲存至歷史紀錄中，方便日後查閱與匯出；音訊檔案依然完全不寫入磁碟。
- **純淨分離不混音**：麥克風錄音與裝置聲音辨識彼此獨立，介面與狀態明確區隔，不進行任何音訊混音。

#### 2. 翻譯穩定度升級（SegmentMerger 智慧整併）
- **低延遲原文 + 穩定中文翻譯**：原文即時字幕維持極低延遲反饋，翻譯則在收到有實質語義的語音片段（≥2 個英文單字或 ≥4 個中文字元，或停頓 ≥0.5 秒）後觸發。
- **懸空子句智慧整併**：透過 `SegmentMerger` 自動判斷結尾為介系詞（of, in, to 等）、連詞（and, but, because 等）或冠詞的未完結句子，在定稿時與後續句子平滑整併，徹底解決翻譯斷句破裂、語義破碎與頻繁閃爍的問題。

#### 3. 全域在地化支援（Global Localization）
- **三種介面語系**：支援「系統預設」、「繁體中文」與「English」。
- **即時全域套用**：在設定頁切換語系後，立即動態更新主畫面、歷史紀錄、課堂詳情、音訊庫、PiP 與所有對話視窗，無需重新啟動 App。

#### 4. 浮動 PiP 子母畫面字幕與 Live Activity
- **跨 App 即時字幕**：支援切換至 GoodNotes、Safari、Notability、PDF Reader 等其他 App 時，透過浮動子母畫面（Picture-in-Picture）持續顯示最新原文與繁體中文翻譯字幕。
- **多種寬高比例**：支援 3:1、5:1（預設長條比例）與 6:1 超寬比例，並支援自訂字級縮放與排版。
- **鎖定畫面與動態島**：利用 ActivityKit 即時顯示錄音狀態、時鐘計時器、最新原文與最新翻譯，支援點擊直接深度連結（Deep Link）返回目前課堂。

#### 5. SideStore 免費個人開發者簽署最佳化
- **單一 Universal IPA**：單一安裝包同時相容 iPhone 與 iPad。
- **剛好 1 個 Widget Extension**：主 App 搭配 `LectureTranscriberWidget`，嚴格遵守 Apple 免費個人開發者帳號（Personal Team）最多 2 個 App ID 的硬性限制。
- **零額外服務負擔**：不使用 App Groups、不依賴 iCloud/CloudKit、不依賴 APNs 推播，所有狀態在本機完整運行。

---

<div align="center">

# Argmax Open-Source SDK (Swift)

</div>

本專案為 Argmax 開源推論架構之擴充整合版本，包含：
- **WhisperKit**：基於 OpenAI Whisper 之裝置端語音辨識
- **SpeakerKit**：基於 Pyannote 之語者分離與說話者標記
- **TTSKit**：文字轉語音推論框架
- **SenseVoice**：多語言超快速串流辨識支援

詳細 Argmax 開發者文件請參閱 [English README](README.md)。
