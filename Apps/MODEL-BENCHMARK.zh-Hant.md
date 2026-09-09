# 中英即時字幕：第一輪實測

日期：2026-09-10。這是實際執行模型的 **Windows CPU 初步測試**，不是模擬出來的數字，也不是 iPad／iPhone 或翻譯測試。

## 環境與方法

- Intel Core i5-11400，6 核心／12 執行緒，約 16 GB 記憶體；Windows，Python 3.13.13。
- sherpa-onnx 1.13.7，CPU provider，每個模型固定 2 個推論執行緒，INT8 權重；兩個模型依序測試，沒有同時競爭 CPU。
- 使用 [sherpa-onnx 公開中英範例](https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20/tree/main/test_wavs) 的 `0.wav`～`3.wav`，合計 28.67 秒，16 kHz 單聲道 PCM。
- 每個模型每段音訊執行兩次不等待的處理速度測試，再執行一次按實際時間送入音訊的測試：每 200 ms 送入一塊，沒有預先提供未播放的聲音。以下表格使用後者。
- 每段最後增加 0.8 秒靜音，明確通知輸入結束，關閉自動端點切句。本次不能評估停頓後自然定稿的延遲、長課堂穩定性或自動切句品質。
- 「首字」是從檔案播放開始，到第一次取得非空文字的實際牆鐘時間，包含音檔開頭的靜音與模型累積語境。不是從第一個字說完起算，也不是所有字幕的固定延遲。
- 處理時間包含送入音訊、解碼與取得結果，排除刻意等待音訊播放的時間；RTF = 處理秒數／原始音訊秒數，越低代表運算餘裕越大。

## 結果

| 指標 | 中英 streaming Zipformer | 中英 streaming Paraformer |
|---|---:|---:|
| 下載的模型與詞表大小，十進位 MB | 198.27 | 237.20 |
| 程序首次初始化，秒 | 7.54 | 5.77 |
| 4 段合計 RTF | 0.230 | 0.209 |
| 約相當於原音長度的處理速度 | 4.35 倍 | 4.78 倍 |
| 首批文字出現範圍，秒 | 0.66～1.47 | 0.91～1.57 |
| 整個 Python 程序峰值 working set，MiB | 447.27 | 473.81 |

初始化數字不包含下载，沒有控制作業系統磁碟快取，不能稱為嚴格冷啟動測試。記憶體包含 Python、NumPy、模型、緩衝與測試程式，不是純模型 RAM，也不能推算 Apple 裝置用量。

| 音檔 | 原始長度，秒 | Zipformer 首字，秒 | Paraformer 首字，秒 | Zipformer RTF | Paraformer RTF |
|---|---:|---:|---:|---:|---:|
| 0.wav | 10.05 | 1.256 | 1.526 | 0.199 | 0.198 |
| 1.wav | 5.10 | 1.467 | 1.519 | 0.218 | 0.202 |
| 2.wav | 4.69 | 0.663 | 0.910 | 0.213 | 0.218 |
| 3.wav | 8.83 | 1.269 | 1.565 | 0.281 | 0.222 |

## 可以下的結論

這兩個串流候選在本機、這四段短音訊上都有足夠處理速度，且不用等十幾秒才第一次出字。因此值得作為下一輪中英字幕候選；目前沒有將它們加入 App，App 1.3 仍是 Apple Speech 與 WhisperKit。

兩者都輸出中英混合文字，但若干位置結果不同。**沒有人工核對的逐字標準答案，所以沒有計算 WER／CER，也不能宣布哪個更準或比 Turbo 更準。** 同樣不能以這批模型發布者範例代表臺灣課堂、專業術語、遠距離收音或數小時錄音。

此測試沒有 Apple Speech、Core ML WhisperKit 或 Apple Translation 的結果。Apple 模型的可用語言、翻譯首次準備、原文出字時間、譯文落後時間、耗電和發熱仍要在 iPad Air M2／iPhone 15 Pro 實機測量。iOS 編譯與模擬器啟動通過，不能代替這些數據。

下一輪需要同一段 30～60 秒的原始中英錄音，以及希望正確辨識的人名／術語。分別涵蓋中文為主與英文為主，再比較原文錯誤、第一批字幕時間、句尾定稿、譯文延遲；不能只挑速度最好的引擎。

## 重現與原始紀錄

[測試程式](../AppTests/ModelBenchmarks/run_streaming.py)、[Zipformer 原始事件](../AppTests/ModelBenchmarks/results-zipformer.json)、[Paraformer 原始事件](../AppTests/ModelBenchmarks/results-paraformer.json)。JSON 保存每個模型檔與音檔 SHA-256、逐次更新文字、供應音訊時間與實際經過時間。

模型檔來源：

- [Zipformer 模型檔](https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20/tree/main)：`encoder-epoch-99-avg-1.int8.onnx`、`decoder-epoch-99-avg-1.int8.onnx`、`joiner-epoch-99-avg-1.int8.onnx`、`tokens.txt`。
- [Paraformer 模型檔](https://huggingface.co/csukuangfj/sherpa-onnx-streaming-paraformer-bilingual-zh-en/tree/main)：`encoder.int8.onnx`、`decoder.int8.onnx`、`tokens.txt`。

資料目錄結構為 `audio/`、`zipformer/`、`paraformer/`；可在一般 Python 環境安裝 `sherpa-onnx==1.13.7` 與 `numpy==2.5.3`，再執行：

```powershell
python -X utf8 AppTests/ModelBenchmarks/run_streaming.py zipformer C:\path\to\ModelBenchmarks
python -X utf8 AppTests/ModelBenchmarks/run_streaming.py paraformer C:\path\to\ModelBenchmarks
```

模型與音檔本身沒有提交到 App 儲存庫。這只是可重現的初步實測，不是效能認證或準確率排名。
