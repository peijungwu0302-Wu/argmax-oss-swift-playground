"""Build a portable iPad ZIP; entry names always use forward slashes."""
from pathlib import Path
import hashlib
import zipfile

root = Path(__file__).resolve().parents[1]
app = root / "Apps" / "LectureTranscriber.swiftpm"
destination = root / "Deliverables" / "LectureTranscriber.zip"
destination.parent.mkdir(exist_ok=True)
sources = [app / "Package.swift", *sorted((app / "Sources").glob("*.swift"))]
assert len(sources) == 7, "Unexpected app source inventory"
assert 'exact: "1.1.3"' in sources[0].read_text(encoding="utf-8")
with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_DEFLATED) as archive:
    for source in sources:
        info = zipfile.ZipInfo(source.relative_to(app.parent).as_posix(), date_time=(2026, 9, 9, 0, 0, 0))
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = 0o100644 << 16
        archive.writestr(info, source.read_bytes())
with zipfile.ZipFile(destination) as archive:
    assert archive.testzip() is None
    assert "LectureTranscriber.swiftpm/Package.swift" in archive.namelist()
    for entry in archive.namelist():
        assert "\\" not in entry and ".." not in entry
        assert entry.endswith(".swift"), entry
print(f"Packaged {len(sources)} files: {destination}")
print(f"SHA256 {hashlib.sha256(destination.read_bytes()).hexdigest()}")
