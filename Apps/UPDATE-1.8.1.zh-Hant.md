# LectureTranscriber v1.8.1：PiP 穩定性與鎖定畫面即時動態 (Live Activity)

版本 1.8.1 build 14，iPhone／iPad 共用單一 universal IPA。主 App Bundle ID: `com.peijungwu0302.lecturetranscriber`，Widget Extension Bundle ID: `com.peijungwu0302.lecturetranscriber.widget`。

[GitHub Release v1.8.1](https://github.com/peijungwu0302-Wu/argmax-oss-swift-playground/releases/tag/v1.8.1) · [SideStore 安裝指南](PRIVATE_INSTALL.zh-Hant.md) · [歷史版本說明](UPDATE-1.8.0.zh-Hant.md)

---

## 1.8.1 重大更新亮點

### 1. PiP 子母畫面黑畫面徹底修復 (Root Cause 排查與修復)
- **Pixel Buffer 格式修復**：排除舊版使用 iOS 視訊硬體層不支援的 `32ARGB` 格式，全面切換為原生 Metal/GPU 支援之 `kCVPixelFormatType_32BGRA` 與 `IOSurface` 記憶體綁定。
- **立即顯示宣告（DisplayImmediately）**：針對產生的 `CMSampleBuffer` 附加 `kCMSampleAttachmentKey_DisplayImmediately = true`，解除圖層對過期或不匹配 presentationTimeStamp 的等待與丟幀，解決純黑畫面問題。
- **解耦 View 生命週期與 CaptionFeed**：移除對主執行緒 `Timer` 及 SwiftUI `updateUIView` 的更新依賴（避免背景掛起時停止重繪），建立獨立 `@MainActor CaptionFeed` 協調器，即便切換到背景也能即時向 PiP 圖層推送字幕幀。

### 2. 多長寬比例支援（3:1 / 5:1 / 6:1）
- **標準比例 (3:1, 960×320)**：適合偏方正的懸浮視窗。
- **長條字幕條 (5:1, 1200×240, 預設)**：最適合邊看 PDF/筆記邊跟隨字幕的黃金比例。
- **超寬字幕條 (6:1, 1200×200)**：極致輕薄，佔用螢幕最小高度。
- 支援動態監聽 `didTransitionToRenderSize`，根據真實 PiP 尺寸縮放字體大小與行距。
- 支援「雙語對照」、「僅翻譯（繁體中文）」、「僅原文」三種顯示模式切換。

### 3. 背景錄音與辨識持續運作（≥60s 實測保證）
- 切換至 GoodNotes、Safari、PDF 閱讀器等其他應用程式時，後台錄音、Apple Speech 即時逐字稿與繁中翻譯持續運作，字幕幀持續更新。

### 4. 鎖定畫面 Live Activity（即時動態）
- 錄音期間在鎖定畫面顯示課程名稱、錄音時間（系統原生高能效跳秒計時器）、最新原文與最新繁中翻譯。
- 支援暫停與繼續狀態切換。
- 僅在段落定稿或翻譯完成時低頻更新，避免頻繁喚醒省電兼顧穩定。

### 5. iPhone Dynamic Island（動態島）
- **Compact 緊湊視圖**：左側顯示錄音狀態圖示，右側顯示即時跳秒時間。
- **Minimal 最小視圖**：極簡錄音與暫停指示燈。
- **Expanded 展開視圖**：展示課程名稱、錄音碼表、最新原文與繁中翻譯。

### 6. SideStore 個人自簽側載最佳化
- 嚴格維持單一 Widget Extension（`com.peijungwu0302.lecturetranscriber.widget`），節省 Personal Team 的 App ID 額度。
- **100% 純本機 ActivityKit**：不使用 App Groups、不依賴 iCloud、不使用 APNs/Push，SideStore 重簽無痛相容。
- 安裝時請選擇「Keep All Extensions」，即可完整享受 Live Activity 與 Dynamic Island。
