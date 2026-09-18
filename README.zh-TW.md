[English](README.md) | [繁體中文](README.zh-TW.md)

> **課堂逐字稿 App 1.9.2 (Build 21) — 繁體中文即時規格化 + 串流字幕穩定器 (Beta)**：iPhone／iPad 通用單一 IPA，支援 SideStore 個人免費憑證簽署側載（剛好 1 App + 1 Widget Extension，無額外 App ID 負擔）。全面為 Zipformer 與 Paraformer 串流語音辨識導入繁體中文即時規格化轉換（包含即時草稿、PiP 畫中畫、動態島與歷史文字稿），新增 `StreamingPartialStabilizer` 消除重複假說與過濾字幕高頻跳動／整句重寫，完成 Model Center Zipformer 雙語串流模型下載流程驗證，並保持 ScreenCaptureKit 裝置音訊擷取、SenseVoice、WhisperKit 與 PiP 既有實機功能之完整穩定性。
> [SideStore 安裝指南](Apps/PRIVATE_INSTALL.zh-Hant.md) · [v1.9.2 更新日誌](Apps/UPDATE-1.9.2.zh-Hant.md)

---

## 🎙️ 課堂逐字稿 (LectureTranscriber) 功能說明

### v1.9.2 重點更新（實機驗證持續進行中）

#### 1. Zipformer / Paraformer 串流字幕即時轉繁體中文
- **全鏈路繁體中文支援**：原生 Sherpa 辨識引擎之 raw partial 與 final 輸出即時經過 Foundation / ICU 規格化轉換，確保畫面 live draft、PiP 浮動字幕、Live Activity 動態島、即時翻譯佇列與儲存之逐字稿皆為繁體中文。
- **混合語言安全保護**：中英文混說情境完整保留英文單字與大小寫，純英文內容維持原樣不被破壞。

#### 2. 串流字幕穩定器 (StreamingPartialStabilizer)
- **消除高頻視覺抖動**：自動抑制字元內容相同的重複推論更新，並攔截異常向後抖動與文字大幅縮減。
- **單調延伸與平滑微調**：文字長度單調增長時立即推進；長度相等或尾端微調時，在保留最大共同前綴前提下更新最後變動字符，大幅減緩整句重寫的閱讀負擔。
- **定稿權威性與自動重置**：final 定稿文字具絕對優先權，分段確認後自動重置穩定器內部狀態，無接縫進入下一語句。

#### 3. Zipformer 雙語模型下載流程驗證就緒
- **模型中心狀態檢驗**：完整驗證乾淨下載安裝與已下載模型識別；錄音期間持續鎖定狀態，防範未就緒模型的非預期熱切換。

#### 4. 既有實機功能相容與穩定
- **零退化保證**：已在實機驗證之 ScreenCaptureKit 裝置聲音擷取（絕對零磁碟音訊寫入）、麥克風錄音、SenseVoice、WhisperKit、Apple 語音辨識、PiP 多比例字幕以及 SideStore 個人開發者架構保持完全相容。
- **客觀註明**：不同 iOS / iPadOS 實體裝置之硬體負載與語音特性各異，實機驗證持續進行中（Real-device validation is ongoing）。

---

### 既有功能特性 (v1.8.5 ~ v1.9.1)

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
