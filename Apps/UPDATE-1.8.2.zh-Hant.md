# LectureTranscriber v1.8.2

版本 1.8.2 build 15，維持 iPhone／iPad 共用 IPA、既有 Bundle ID 與唯一的 Live Activity Widget Extension。

## 即時字幕

- 開始錄音後可自動開啟子母字幕。
- 子母字幕成為主要跨 App 即時字幕模式。
- 改善 3:1、5:1、6:1 排版，預設為 5:1。
- 新增 75%～150% 字幕大小、左右對齊、上下位置與原文／翻譯間距。
- 支援真正 PiP 即時預覽與錄音中即時調整。
- 可還原子母字幕預設設定。

## 完整逐字稿

- 即時字幕與完整逐字稿正式分工；定稿歷史不會被草稿覆蓋。
- PiP Return to App 與 Live Activity 可直接進入目前課堂。
- 改善 Follow Live、回到即時與歷史內容瀏覽。

## Live Activity

- 修正錄音時間顯示異常巨大的問題。
- 改善鎖定畫面標題、字幕層級與狀態排版。
- meaningful partial 採節流與合併，final 原文及翻譯立即更新。

## Apple Speech / Translation

- Apple Speech 是首次安裝的預設辨識引擎。
- 缺少系統語音資源時，開始錄音流程會透過 Apple 官方 API 自動準備；沒有可信百分比時顯示不定進度。
- Apple Translation 預設啟用並翻譯為繁體中文；沿用系統正式資源準備流程。

## 多語言辨識

- Apple Speech 保留單一主要語言模式。
- SenseVoice 定位為中英混合／多語快速辨識，沿用現有端側模型與自動語言能力。
