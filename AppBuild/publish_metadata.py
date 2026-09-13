"""Generate SideStore/update metadata only from an existing validated IPA."""
import datetime, json, plistlib, sys, zipfile
from pathlib import Path

def generate(ipa: Path, destination: Path):
    with zipfile.ZipFile(ipa) as archive:
        assert archive.testzip() is None
        paths = [p for p in archive.namelist() if p.startswith('Payload/') and p.count('/') == 2 and p.endswith('/Info.plist')]
        assert len(paths) == 1
        info = plistlib.loads(archive.read(paths[0]))
        assert not any('.appex/' in p for p in archive.namelist())
    identifier = 'com.peijungwu0302.lecturetranscriber'
    assert info['CFBundleIdentifier'] == identifier
    assert sorted(info['UIDeviceFamily']) == [1, 2]
    version, build = info['CFBundleShortVersionString'], int(info['CFBundleVersion'])
    assert ipa.name in [f'LectureTranscriber-{version}-unsigned.ipa', f'LectureTranscriber-v{version}.ipa']
    base = 'https://raw.githubusercontent.com/peijungwu0302-Wu/argmax-oss-swift-playground/playground-compatible/'
    url = f'https://github.com/peijungwu0302-Wu/argmax-oss-swift-playground/releases/download/v{version}/LectureTranscriber-v{version}.ipa'
    notes = '單一課堂多版本逐字稿架構（Apple Speech Live 即時辨識、Whisper v3 錄後高精確轉錄、SenseVoice）、整合式 LectureDetailView 跨片段連續播放與點擊時間軸 Seek、逐字稿雙語/僅中文/僅原文檢視、版本切換與比較、專有名詞詞庫提示、自動舊版 session.json 無痛相容升級、SideStore 側載最佳化。'
    minimum = info.get('MinimumOSVersion', '16.0')
    update = dict(bundleIdentifier=identifier, version=version, build=build, minimumOS=minimum, downloadURL=url, notes=notes)
    icon = base + 'Apps/LectureTranscriber.swiftpm/Sources/Assets.xcassets/AppIcon.appiconset/AppIcon.png'
    source = dict(name='LectureTranscriber 私人更新', identifier='com.peijungwu0302.lecturetranscriber.source',
        sourceURL=base + 'Deliverables/sidestore.json', subtitle='課堂逐字稿 · iPhone / iPad', iconURL=icon,
        apps=[dict(name='課堂逐字稿 LectureTranscriber', bundleIdentifier=identifier, developerName='Peijung Wu',
            localizedDescription=notes, iconURL=icon,
            versions=[dict(version=version, date=datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                localizedDescription=notes, downloadURL=url, size=ipa.stat().st_size, minOSVersion=minimum)],
            appPermissions=dict(entitlements=[], privacy={k:v for k,v in info.items() if k.startswith('NS') and 'UsageDescription' in k}))], news=[])
    destination.mkdir(parents=True, exist_ok=True)
    for name, value in [('update.json', update), ('sidestore.json', source)]:
        (destination / name).write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(f'Validated {version} build {build}; generated SideStore and in-app metadata')

if __name__ == '__main__': generate(Path(sys.argv[1]), Path(sys.argv[2]))
