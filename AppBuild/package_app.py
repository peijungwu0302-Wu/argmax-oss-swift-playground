"""Build a portable iPad ZIP; entry names always use forward slashes."""
from pathlib import Path
import hashlib
import zipfile

root = Path(__file__).resolve().parents[1]
app = root / "Apps" / "LectureTranscriber.swiftpm"
destination = root / "Deliverables" / "LectureTranscriber.zip"
destination.parent.mkdir(exist_ok=True)
sources = [app / "Package.swift", *sorted(p for p in (app / "Sources").rglob("*") if p.is_file())]
assert sum(p.suffix == ".swift" for p in sources) == 17, "Unexpected app source inventory"
assert len(sources) == 21, "App icon catalog must be included"
assert 'exact: "1.1.4"' in sources[0].read_text(encoding="utf-8")
assert "sherpa-onnx" not in sources[0].read_text(encoding="utf-8"), "iPad Playgrounds cannot unpack remote binary dependencies"
with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_DEFLATED) as archive:
    for source in sources:
        info = zipfile.ZipInfo(source.relative_to(app.parent).as_posix(), date_time=(2026, 9, 10, 0, 0, 0))
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = 0o100644 << 16
        archive.writestr(info, source.read_bytes())
with zipfile.ZipFile(destination) as archive:
    assert archive.testzip() is None
    assert "LectureTranscriber.swiftpm/Package.swift" in archive.namelist()
    for entry in archive.namelist():
        assert "\\" not in entry and ".." not in entry
        assert entry.endswith((".swift", ".json", ".png", ".txt")), entry
    assert "LectureTranscriber.swiftpm/Sources/Assets.xcassets/AppIcon.appiconset/AppIcon.png" in archive.namelist()
print(f"Packaged {len(sources)} files: {destination}")
print(f"SHA256 {hashlib.sha256(destination.read_bytes()).hexdigest()}")
