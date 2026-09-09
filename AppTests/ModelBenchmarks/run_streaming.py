"""Local CPU screening, not an Apple-device or translation benchmark.

Uses public sherpa-onnx example audio; never uses model output as ground truth.
Run: python -X utf8 run_streaming.py zipformer PATH_TO_BENCHMARK_DATA
"""
import ctypes
import hashlib
import json
from pathlib import Path
import platform
import statistics
import sys
import time
import wave

ROOT = Path(sys.argv[2]).resolve() if len(sys.argv) > 2 else Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "runtime"))
import numpy as np
import sherpa_onnx


def peak_working_set():
    class Counters(ctypes.Structure):
        _fields_ = [("cb", ctypes.c_ulong), ("PageFaultCount", ctypes.c_ulong)] + [
            (name, ctypes.c_size_t) for name in ["PeakWorkingSetSize", "WorkingSetSize",
                "QuotaPeakPagedPoolUsage", "QuotaPagedPoolUsage", "QuotaPeakNonPagedPoolUsage",
                "QuotaNonPagedPoolUsage", "PagefileUsage", "PeakPagefileUsage"]]
    value = Counters()
    value.cb = ctypes.sizeof(value)
    ctypes.windll.kernel32.GetCurrentProcess.restype = ctypes.c_void_p
    ctypes.windll.psapi.GetProcessMemoryInfo.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_ulong]
    ok = ctypes.windll.psapi.GetProcessMemoryInfo(ctypes.windll.kernel32.GetCurrentProcess(), ctypes.byref(value), value.cb)
    return value.PeakWorkingSetSize if ok else None


def read_audio(path):
    with wave.open(str(path), "rb") as source:
        assert source.getnchannels() == 1 and source.getsampwidth() == 2
        assert source.getframerate() == 16000
        return np.frombuffer(source.readframes(source.getnframes()), dtype="<i2").astype(np.float32) / 32768


def recognize(recognizer, samples, paced):
    sr = 16000
    stream = recognizer.create_stream()
    # Identical explicit tail padding; this benchmark does NOT measure automatic
    # endpoint finalization. Audio is supplied without VAD or external resampling.
    padded = np.concatenate([samples, np.zeros(int(sr * 0.8), dtype=np.float32)])
    events, costs, lags = [], [], []
    last_text = ""
    start = time.perf_counter()
    for offset in range(0, len(padded), 3200):
        end = min(offset + 3200, len(padded))
        deadline = end / sr
        if paced:
            remaining = deadline - (time.perf_counter() - start)
            if remaining > 0:
                time.sleep(remaining)
        compute_start = time.perf_counter()
        stream.accept_waveform(sr, padded[offset:end])
        if end == len(padded):
            stream.input_finished()
        while recognizer.is_ready(stream):
            recognizer.decode_stream(stream)
        text = recognizer.get_result(stream)
        costs.append(time.perf_counter() - compute_start)
        elapsed = time.perf_counter() - start
        if paced:
            lags.append(max(0, elapsed - deadline))
        if text != last_text:
            events.append({"audio_supplied_seconds": round(end / sr, 4),
                           "wall_seconds": round(elapsed, 4), "text": text})
            last_text = text
    first = next((event for event in events if event["text"].strip()), None)
    return {
        "paced": paced, "audio_seconds": len(samples) / sr,
        "wall_seconds": time.perf_counter() - start,
        "compute_seconds": sum(costs),
        "compute_rtf": sum(costs) / (len(samples) / sr),
        "first_nonempty": first,
        "max_processing_backlog_seconds": max(lags) if lags else None,
        "p95_chunk_compute_seconds": float(np.percentile(costs, 95)),
        "final_text": last_text, "events": events,
    }


def main():
    model = sys.argv[1]
    folder = ROOT / model
    common = dict(tokens=str(folder / "tokens.txt"), num_threads=2,
                  provider="cpu", enable_endpoint_detection=False)
    begin = time.perf_counter()
    if model == "zipformer":
        recognizer = sherpa_onnx.OnlineRecognizer.from_transducer(
            encoder=str(folder / "encoder-epoch-99-avg-1.int8.onnx"),
            decoder=str(folder / "decoder-epoch-99-avg-1.int8.onnx"),
            joiner=str(folder / "joiner-epoch-99-avg-1.int8.onnx"), **common)
    elif model == "paraformer":
        recognizer = sherpa_onnx.OnlineRecognizer.from_paraformer(
            encoder=str(folder / "encoder.int8.onnx"), decoder=str(folder / "decoder.int8.onnx"), **common)
    else:
        raise ValueError(model)
    result = {"model": model, "runtime": sherpa_onnx.__version__, "python": platform.python_version(),
              "platform": platform.system(), "threads": 2, "provider": "cpu",
              "load_seconds": time.perf_counter() - begin,
              "model_files": [{"name": p.name, "bytes": p.stat().st_size,
                               "sha256": hashlib.sha256(p.read_bytes()).hexdigest()}
                              for p in sorted(folder.iterdir())], "clips": []}
    for path in sorted((ROOT / "audio").glob("[0-3].wav")):
        samples = read_audio(path)
        trials = [recognize(recognizer, samples, False) for _ in range(2)]
        paced = recognize(recognizer, samples, True)
        clip = {"file": path.name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                "trials": trials, "paced": paced}
        result["clips"].append(clip)
        print(json.dumps({"model": model, "file": path.name, "rtf": paced["compute_rtf"],
                          "first": paced["first_nonempty"], "final": paced["final_text"]}, ensure_ascii=False), flush=True)
        (ROOT / f"results-{model}.json").write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    result["peak_process_working_set_bytes"] = peak_working_set()
    result["timing_note"] = "First text is measured from file playback start, not voice onset. No ground truth, WER, endpoint finalization, Apple device, or translation measurement. Peak memory covers this whole Python process."
    (ROOT / f"results-{model}.json").write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()
