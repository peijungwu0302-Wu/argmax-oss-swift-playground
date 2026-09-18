# LectureTranscriber v1.9.2 (Build 21)

### 繁體中文即時規格化與串流字幕穩定性改善

- **Zipformer / Paraformer 串流字幕即時轉繁體中文**：
  Sherpa 語音辨識之 raw partial 與 final 輸出全面導入標準文字規格化層（Foundation / ICU），即時轉換為繁體中文。包括即時串流草稿、PiP 畫中畫浮動字幕、Live Activity 鎖定畫面與動態島、即時翻譯佇列以及歷史逐字稿儲存，皆統一以繁體中文呈現，降低閱讀與視覺負擔；英文及中英混說內容完整保留，不受轉換影響。

- **串流字幕穩定器 (StreamingPartialStabilizer)**：
  針對 Zipformer 與 Streaming Paraformer 串流推論過程中的高頻字詞修正，加入串流假說穩定機制。自動抑制內容相同的重複更新、過濾異常文字縮減與高頻抖動，僅在文字單調延伸或尾端合理微調（保留共用前綴）時推進更新，顯著減少字幕整句反覆重寫之視覺跳動；final 定稿文字具權威性覆蓋，並於定稿後自動重置穩定器狀態。

- **Zipformer 雙語模型下載流程驗證就緒**：
  模型中心（Model Center）已驗證 Zipformer 雙語串流模型之下載與就緒檢驗流程，支援乾淨安裝與既有安裝狀態檢查；錄音進行中維持模型狀態鎖定與切換防護，避免未備妥模型觸發中斷。

- **既有實機功能相容與穩定性**：
  維持既有在實機已驗證之功能完全相容：ScreenCaptureKit 裝置聲音擷取（零磁碟音檔寫入）、麥克風錄音與 AAC 壓縮、SenseVoice 與 WhisperKit 離線辨識、Apple 語音辨識、PiP 多比例字幕以及 SideStore 個人開發者 2 個 App ID 架構皆保持不變。

> **說明**：各型號 iOS / iPadOS 實體裝置之硬體效能與語音辨識推論延遲略有差異，實機驗證持續進行中（Real-device validation is ongoing）。
