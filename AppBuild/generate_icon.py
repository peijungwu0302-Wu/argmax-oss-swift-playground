"""Generate the app's opaque waveform icon without placeholder assets."""
from pathlib import Path
from PIL import Image, ImageDraw

size = 1024
image = Image.new("RGB", (size, size), (5, 109, 119))
draw = ImageDraw.Draw(image)
for x, height in zip((260, 386, 512, 638, 764), (160, 340, 540, 340, 160)):
    draw.rounded_rectangle((x - 34, 512 - height // 2, x + 34, 512 + height // 2), radius=34, fill="white")
path = Path(__file__).resolve().parents[1] / "Apps/LectureTranscriber.swiftpm/Sources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
image.save(path, optimize=True)
print(path)
