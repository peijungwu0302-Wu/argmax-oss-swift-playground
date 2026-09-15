"""Package one unsigned universal app; fail if identity or extra app slots change."""
from pathlib import Path
import sys, plistlib, zipfile

app = Path(sys.argv[1])
output = Path(sys.argv[2])
with (app / "Info.plist").open("rb") as f:
    info = plistlib.load(f)

assert info["CFBundleIdentifier"] == "com.peijungwu0302.lecturetranscriber"
assert sorted(info["UIDeviceFamily"]) == [1, 2]
assert info["CFBundleShortVersionString"] == "1.9.0" and info["CFBundleVersion"] == "19"
assert "audio" in info["UIBackgroundModes"]
assert info.get("UIRequiresFullScreen") is False
assert info.get("NSSupportsLiveActivities") is True, "Missing NSSupportsLiveActivities entitlement in Info.plist"

# Check Widget Extension: Exactly one widget extension allowed (com.peijungwu0302.lecturetranscriber.widget)
extensions = list(app.glob("PlugIns/*.appex"))
assert len(extensions) == 1, f"Expected exactly one widget extension, found: {extensions}"
widget_appex = extensions[0]
with (widget_appex / "Info.plist").open("rb") as f:
    widget_info = plistlib.load(f)

assert widget_info["CFBundleIdentifier"] == "com.peijungwu0302.lecturetranscriber.widget", f"Unexpected widget bundle ID: {widget_info['CFBundleIdentifier']}"
assert widget_info["CFBundleShortVersionString"] == "1.9.0" and widget_info["CFBundleVersion"] == "19"

assert not (app / "embedded.mobileprovision").exists(), "Distribute an unsigned app for personal signing"
assert info.get("CFBundleIcons"), "Missing packaged app icon"

output.parent.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as z:
    for file in app.rglob("*"):
        if file.is_file():
            z.write(file, "Payload/" + app.name + "/" + file.relative_to(app).as_posix())

with zipfile.ZipFile(output) as z:
    assert z.testzip() is None
    names = z.namelist()
    assert any(n.startswith(f"Payload/{app.name}/PlugIns/LectureTranscriberWidget.appex") for n in names), "IPA missing embedded widget extension"

print("PASS: single Widget extension, universal iPhone/iPad, background audio, NSSupportsLiveActivities, version 1.9.0 (19) and unsigned IPA integrity")
print(output)
