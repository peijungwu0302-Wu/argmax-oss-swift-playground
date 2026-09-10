"""Reject binary package declarations in the shipped iPad manifest.
The approved WhisperKit 1.1.4 dependency uses source targets. Xcode success alone
is not evidence of the iPad Playgrounds dependency resolver supporting binaries.
"""
from pathlib import Path
root = Path(__file__).resolve().parents[1]
manifest = (root / "Apps/LectureTranscriber.swiftpm/Package.swift").read_text(encoding="utf-8")
assert "binaryTarget" not in manifest and "sherpa-onnx" not in manifest and "onnxruntime" not in manifest
assert manifest.count(".package(") == 1
assert 'exact: "1.1.4"' in manifest
sdk = (root / "Package@swift-6.2.swift").read_text(encoding="utf-8")
assert '.library(name: "SpeakerKit", targets: ["SpeakerKit"])' in sdk
assert 'binaryTarget' not in sdk
engine = (root / "Apps/LectureTranscriber.swiftpm/Sources/SenseVoiceEngine.swift").read_text(encoding="utf-8")
assert "import SherpaOnnxC" not in engine and "import CoreML" in engine
assert 'Process(' not in engine and '.zip"' not in engine
print("PASS: shipped manifest has no binary SDK; Core ML model download does not spawn unzip")
