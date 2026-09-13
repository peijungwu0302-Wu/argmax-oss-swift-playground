# 1.8.0：即時翻譯雙軌架構、統一 ResourceState、1200×240 PiP 長條字幕與日期分組庫

版本 1.8.0 build 13，iPhone／iPad 共用單一 universal IPA。Bundle ID 維持 com.peijungwu0302.lecturetranscriber。

[GitHub Release v1.8.0](https://github.com/peijungwu0302-Wu/argmax-oss-swift-playground/releases/tag/v1.8.0) · [SideStore 安裝指南](PRIVATE_INSTALL.zh-Hant.md) · [歷史版本說明](UPDATE-1.7.0.zh-Hant.md)

---

## 1.8.0 重大更新亮點

### 1. 實時繁中翻譯速度與穩定性提升（Root Cause 徹底修復）
- **切換辨識引擎不中斷翻譯**：徹底排除過去切換辨識核心（Apple Speech / WhisperKit / SenseVoice）導致 live translation 凍結終止之 root cause（取消重設 translationGeneration，解耦語音辨識與翻譯生命週期）。
- **雙軌優先佇列（Dual-lane Architecture）**：
  - **LIVE 軌道（Draft Lane）**：最新即時語音草稿最高優先級，新句子到來時以最新草稿優先翻譯。
  - **BACKLOG 軌道（Confirmed Lane）**：空閒時依序補齊已定稿句子的繁中翻譯，互不阻塞。
- **可調更新頻率預設檔**：
  - 極快：0.25 秒
  - 快速：0.40 秒（預設）
  - 平衡：0.70 秒
  - 穩定：1.00 秒
  - 自訂：0.20 秒 ~ 2.00 秒
- **抽象 TranslationProvider 架構**：已建立標準介面協議；雲端服務（Google Cloud / Microsoft Azure）嚴格以 FeatureFlag 關閉（無付費 API、不發送外部網路請求）。

### 2. 統一 ResourceState 語音模型資源狀態
- 建立全域統一狀態列舉：.notDownloaded、.downloading(bytesReceived, totalBytes, progress)、.extracting、.compiling、.ready、.failed(message)。
- **嚴禁偽造進度條**：全面改為由底層 URLSessionDownloadDelegate 及 WhisperKit 實體回報之實際傳輸位元組計算進度與顯示「xx.x MB / xx.x MB (xx%)」。

### 3. PiP 長條字幕全新 5:1 比例設計（1200 × 240）
- 取代舊有 960×320 比例，改為 1200×240 長條形字幕浮動條（符合 5:1 視訊字幕黃金比例）。
- 支援三種模式快速切換：
  - **雙語對照**：原文在上（白字）、繁中翻譯在下（金色高對比粗體），多行自動折行。
  - **僅翻譯**：清晰大字號金色繁體中文。
  - **僅原文**：沉浸式白色原文。

### 4. 日期分組智慧課堂庫（Today / Yesterday / Earlier）
- 歷史列表自動按時間分組為「今天」、「昨天」、「更早之前」。
- 每張課堂卡片展示建立時間、總時長、音訊檔案容量大小、辨識引擎徽章、多版本計數，以及最新逐字稿預覽。

### 5. 多版本翻譯資料模型（TranslationVersion）
- 將 TranslationVersion 與 TranscriptVersion 解耦，支援一版逐字稿關聯多種翻譯版本。
- 100% 保持與舊版 session.translations 及 ersion.translations 向上與向下相容。
- 在 LectureDetailView 支援即時切換不同翻譯版本。

### 6. 多語言介面架構與在地化
- 支援繁體中文（zh-Hant）與英文（en）。
- 設定提供「跟隨系統」、「繁體中文」、「English」三種語言選項。
- 智慧語言支援度提示（EngineCapability），精確告知各辨識引擎在當前語言的支援能力。

### 7. Settings 10 大分區精準重排
1. 辨識核心 (置頂)
2. 即時翻譯
3. 語言設定
4. PiP 字幕與精簡視窗
5. 模型與資源管理
6. 錄音品質與儲存
7. 專有名詞提示
8. 智慧筆記與 AI 整理
9. 側載簽名維護 (SideStore Self-Refresh)
10. 關於與版本更新 (置底)
