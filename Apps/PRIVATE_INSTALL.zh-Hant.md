# 私人安裝：iPhone／iPad 與 Windows

目標是安裝到自己的 iPhone／iPad 主畫面，不公開上架 App Store。GitHub 帳號是保存原始碼用；安裝時的簽署使用自己的 Apple 帳號。

以下 iPad 步驟同樣適用 iPhone；iPhone 不支援 Swift Playgrounds，直接使用通用 IPA。1.4.0 的兩種裝置共用程式，並非兩套獨立專案。

## Windows 路線：AltStore Classic

1. 先在 Swift Playgrounds 測試本版模型載入、錄音、即時草稿、暫停、匯出，以及刪除一堂測試錄音。保留原專案，獨立 App 的資料容器不會自動繼承 Playground 的錄音與模型。
2. 依 [AltStore 官方 Windows 安裝說明](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows) 安裝 AltServer 與所需的 Apple 軟體。依官方說明使用相容的 iTunes／iCloud 版本；不要直接移除你正在使用的 iCloud 而忽略同步狀態。
3. 使用 USB 連接並解鎖 iPad，依官方流程信任電腦、啟用 Wi-Fi 同步，由 AltServer 安裝 AltStore Classic。Apple 帳號與驗證碼在自己的安裝畫面輸入。
4. 按官方流程啟用 iPad 的開發者模式與信任你的開發者身分。
5. 在本儲存庫 GitHub Actions 的成功 `Lecture App Validation` 執行中，下載 `LectureTranscriber-unsigned-IPA` artifact。GitHub 下載的是 ZIP，解壓後取得 `LectureTranscriber-unsigned.ipa`。
6. 將 IPA 存到 iPad「檔案」，開啟 AltStore 的 My Apps，使用「＋」選取 IPA，讓 AltStore 以自己的 Apple 帳號簽署安裝。Windows 上 AltServer 必須能與 iPad 連線。
7. 安裝完成後從 iPad 主畫面的「課堂逐字稿」圖示直接啟動，不再經過 Swift Playgrounds。首次在獨立 App 使用，需重新允許麥克風並下載模型。

IPA 已建置，但沒有 Apple 開發者簽章，不能在「檔案」App 點一下直接安裝。側載工具的簽署／安裝流程仍需在你的 Windows 與 iPad 上完成；雲端編譯成功不代表私人簽署已完成。

免費 Apple 帳號的開發用 provisioning profile 有效期為 7 天，需在到期前透過 AltServer 刷新。到期通常需要重新簽署才能開啟；不要用刪除 App 的方式刷新，否則可能遺失 App 資料。參考 [Apple 帳號限制](https://developer.apple.com/help/account/basics/about-your-developer-account) 和 [AltStore 入門](https://faq.altstore.io/altstore-classic/your-altstore)。

若之後希望透過 Apple 的 TestFlight 私人安裝與更新，也不必公開上架；但需 Apple Developer Program 會員（每年 99 美元或当地定價），每個測試版本最長 90 天。這不是目前已替你開通的服務，也不是本次必要支出。[會員說明](https://developer.apple.com/programs/enroll/)／[TestFlight 說明](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/)

## 本版與後續優先次序

App 1.4.0 已有 Apple 即時語音、WhisperKit 與 SenseVoice 實驗引擎。先用同一段中英混說比較 SenseVoice 自動、中文為主、英文為主；純單語則可沿用 Apple。實測與限制見 [1.4.0 說明](UPDATE-1.4.0.zh-Hant.md)。

優先改善 iPad 的字幕穩定性、混語品質與耗電；iPhone 本次提供通用安裝檔，暫不增加手機專屬功能。背景錄音、跨 App 字幕、完整備份還原與錄音播放時間軸均不是本版已完成的功能。
