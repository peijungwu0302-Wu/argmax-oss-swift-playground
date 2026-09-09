"""SenseVoice full-clip throughput and repeated-prefix experiment, not native streaming."""
import hashlib
import json
from pathlib import Path
import sys
import time

ROOT = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "runtime"))
import numpy as np
import sherpa_onnx
import wave


def read_audio(path):
    with wave.open(str(path), "rb") as reader:
        assert reader.getframerate() == 16000 and reader.getnchannels() == 1 and reader.getsampwidth() == 2
        return np.frombuffer(reader.readframes(reader.getnframes()), dtype="<i2").astype(np.float32) / 32768


started = time.perf_counter()
recognizer = sherpa_onnx.OfflineRecognizer.from_sense_voice(
    model=str(ROOT / "sensevoice/model.int8.onnx"), tokens=str(ROOT / "sensevoice/tokens.txt"),
    num_threads=2, provider="cpu", language="auto", use_itn=True)
result = {"model": "SenseVoiceSmall INT8", "sherpa_onnx": sherpa_onnx.__version__,
          "provider": "cpu", "threads": 2, "language": "auto", "use_itn": True,
          "load_seconds": time.perf_counter() - started,
          "model_files": [{"name": p.name, "bytes": p.stat().st_size,
                           "sha256": hashlib.sha256(p.read_bytes()).hexdigest()}
                          for p in sorted((ROOT / "sensevoice").iterdir())], "clips": [],
          "limitations": "Repeated-prefix experiment re-decodes available audio every 2 seconds. No VAD, native streaming state, commitment rule, user audio, ground truth, Apple device or translation test. Full-clip throughput is not caption latency."}


def decode(samples):
    begin = time.perf_counter()
    stream = recognizer.create_stream()
    stream.accept_waveform(16000, samples)
    recognizer.decode_stream(stream)
    return {"text": stream.result.text, "compute_seconds": time.perf_counter() - begin}


for path in sorted((ROOT / "audio").glob("[0-3].wav")):
    samples = read_audio(path)
    duration = len(samples) / 16000
    full = [decode(samples) for _ in range(2)]
    prefixes = []
    begin = time.perf_counter()
    for stop in list(range(32000, len(samples), 32000)) + [len(samples)]:
        remaining = stop / 16000 - (time.perf_counter() - begin)
        if remaining > 0:
            time.sleep(remaining)
        event = decode(samples[:stop])
        event.update(audio_supplied_seconds=stop / 16000, wall_seconds=time.perf_counter() - begin)
        prefixes.append(event)
    clip = {"file": path.name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "audio_seconds": duration, "full_clip_trials": full, "paced_prefix_events": prefixes}
    result["clips"].append(clip)
    (ROOT / "results-sensevoice.json").write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({"file": path.name, "audio_seconds": duration,
                      "full_compute_seconds": full[1]["compute_seconds"],
                      "first_prefix": prefixes[0], "final_text": full[1]["text"]}, ensure_ascii=False), flush=True)
