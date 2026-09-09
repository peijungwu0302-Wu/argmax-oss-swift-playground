"""Package one unsigned universal app; fail if identity or extra app slots change."""
from pathlib import Path
import sys, plistlib, zipfile
app = Path(sys.argv[1])
output = Path(sys.argv[2])
with (app / "Info.plist").open("rb") as f:
    info = plistlib.load(f)
assert info["CFBundleIdentifier"] == "com.peijungwu0302.lecturetranscriber"
assert sorted(info["UIDeviceFamily"]) == [1, 2]
assert info["CFBundleShortVersionString"] == "1.5.0" and info["CFBundleVersion"] == "10"
assert "audio" in info["UIBackgroundModes"]
assert info.get("UIRequiresFullScreen") is False
assert not list(app.rglob("*.appex")), "Extensions would consume additional App IDs"
assert not (app / "embedded.mobileprovision").exists(), "Distribute an unsigned app for personal signing"
assert info.get("CFBundleIcons"), "Missing packaged app icon"
output.parent.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as z:
    for file in app.rglob("*"):
        if file.is_file(): z.write(file, "Payload/" + app.name + "/" + file.relative_to(app).as_posix())
with zipfile.ZipFile(output) as z:
    assert z.testzip() is None
print("PASS: single App ID, universal iPhone/iPad, background audio, icon, version and unsigned IPA integrity")
print(output)
