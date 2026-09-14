[English](README.md) | [繁體中文](README.zh-TW.md)

> **課堂逐字稿 App 1.8.4 (Build 17) — 裝置聲音實機啟用 + 課程詞彙 (Beta)**：iPhone／iPad 通用單一 IPA，支援 SideStore 個人免費憑證簽署側載（剛好 1 App + 1 Widget Extension，無額外 App ID 負擔）。修復實體 iOS 27 裝置聲音可用性檢測、新增 ScreenCaptureKit 音訊觀測與診斷面板（一鍵複製診斷報告）、保證裝置聲音零磁碟錄音寫入（絕對不寫入任何 .wav/.m4a/.pcm16 音訊檔）、支援「僅即時顯示（不留紀錄）」與「僅保留文字稿（不存音檔）」兩種儲存模式、新增「課程詞彙 (Course Vocabulary Beta)」支援專業術語標準化與識別別名替換（Apple Speech 脈絡詞提示 + SenseVoice 穩定詞彙修正）、升級 SegmentMerger 懸空子句整併翻譯、支援跨 App（GoodNotes／Safari／PDF 等）PiP 子母畫面即時字幕、鎖定畫面 Live Activity 與 iPhone 動態島、以及反應式全域在地化語系支援（系統預設／繁體中文／English）。
> [GitHub Release v1.8.4 下載 IPA](https://github.com/peijungwu0302-Wu/argmax-oss-swift-playground/releases/tag/v1.8.4) · [SideStore 安裝指南](Apps/PRIVATE_INSTALL.zh-Hant.md)

---

## 🎙️ 課堂逐字稿 (LectureTranscriber) v1.8.4 功能說明

**課堂逐字稿 (LectureTranscriber)** 是一款專為 iOS 與 iPadOS 設計的本機即時語音轉文字與即時翻譯工具。

### v1.8.4 重點更新

#### 1. 裝置聲音實機啟用與觀測（ScreenCaptureKit）
- **修復實體 iOS 27 誤報問題**：修復 v1.8.3 因 SDK 條件編譯導致實體 iOS 27 誤報「需要 iOS/iPadOS 27 或更新版本」的底層原因，導入動態執行階段橋接，實機無痛啟用。
- **ScreenCaptureKit 音訊串流抽取**：接收系統音訊 `CMSampleBuffer`，即時轉碼為 16 kHz Float32 單聲道 PCM，並精準計算 RMS 聲音能量音量。
- **全新「裝置聲音診斷與觀測」面板**：設定頁新增獨立診斷區塊，即時顯示封包接收狀態、首包延遲、取樣率、格式、遺失封包數與錯誤原因，並提供一鍵「複製診斷資訊」方便問題排查。
- **絕對零磁碟錄音寫入（隱私保證）**：裝置聲音音訊樣本僅在記憶體有限循環緩衝區（最多 30 秒）內供語音辨識模型處理，**絕對不會將任何音訊檔案（.wav、.m4a、.pcm16）寫入裝置磁碟儲存空間**。
- **兩種儲存模式可選**：
  - **僅即時顯示（預設）**：按下停止後，不儲存任何課堂紀錄、不保留文字稿、不產生任何音檔，完全零痕跡。
  - **僅保留文字稿**：辨識完成的即時逐字稿與中文翻譯會儲存至歷史紀錄中，方便日後查閱與匯出；音訊檔案依然完全不寫入磁碟。

#### 2. 課程詞彙 (Course Vocabulary Beta)
- **單一在地詞彙清單（上限 100 筆）**：針對課堂與技術領域專有名詞（如 `nuScenes`、`Q-Former`、`TrajQFormer`、`UniAD`、`BEVFormer`）建立專屬詞庫。
- **標準詞與識別別名**：支援為標準專有名詞設定多組常見語音識別別名（例如 `nuScenes` -> `new scenes`, `nu scenes`；`Q-Former` -> `cue former`）。
- **Apple Speech 整合**：將標準詞自動掛載至 Speech 框架的脈絡詞提示機制（`contextualStrings`），引導解碼器優先辨識正確術語。
- **SenseVoice 整合**：在穩定/定稿文字輸出時進行保守的單字與片語邊界替換，精準修正大小寫並防範前後綴污染，修正後之標準名詞直通翻譯模組。

#### 3. 全域在地化支援（Global Localization）
- **三種介面語系**：支援「系統預設」、「繁體中文」與「English」。
- **即時反應式全域套用**：在設定頁切換語系後，主畫面、歷史紀錄、課堂詳情、音訊庫、PiP 與所有對話視窗即時更新，無須重啟 App。

#### 4. 麥克風零退化與浮動 PiP 子母畫面
- **麥克風完整保存**：原麥克風錄音、AAC 高音質壓縮儲存、事後回放與重辨識 100% 保持穩定，完全不受裝置聲音改動影響。
- **跨 App 即時字幕**：支援切換至 GoodNotes、Safari、Notability、PDF Reader 等其他 App 時，透過浮動子母畫面（Picture-in-Picture）持續顯示最新原文與繁體中文翻譯字幕（支援 3:1、5:1、6:1 比例）。
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
