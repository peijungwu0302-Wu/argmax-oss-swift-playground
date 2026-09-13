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
    notes = '實時繁中翻譯速度與穩定性提升、切換辨識引擎不中斷翻譯、雙軌優先佇列與可調頻率、統一 ResourceState 真實位元組進度、全新 1200×240 (5:1) PiP 長條字幕、日期分組課堂庫、跨片段連續播放與時間軸跳轉高亮、多版本翻譯解耦相容、中英雙語在地化、iPhone/iPad 通用 SideStore 側載最佳化。'
    minimum = info.get('MinimumOSVersion', '16.0')
    update = dict(bundleIdentifier=identifier, version=version, build=build, minimumOS=minimum, downloadURL=url, notes=notes)
    icon = base + 'Apps/LectureTranscriber.swiftpm/Sources/Assets.xcassets/AppIcon.appiconset/AppIcon.png'
    new_version_entry = dict(
        version=version,
        date=datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        localizedDescription=notes,
        downloadURL=url,
        size=ipa.stat().st_size,
        minOSVersion=minimum
    )
    versions_list = [new_version_entry]
    existing_sidestore = destination / 'sidestore.json'
    if existing_sidestore.exists():
        try:
            old_data = json.loads(existing_sidestore.read_text(encoding='utf-8'))
            old_versions = old_data.get('apps', [{}])[0].get('versions', [])
            for ov in old_versions:
                if ov.get('version') != version:
                    versions_list.append(ov)
        except Exception:
            pass
    source = dict(name='LectureTranscriber 私人更新', identifier='com.peijungwu0302.lecturetranscriber.source',
        sourceURL=base + 'Deliverables/sidestore.json', subtitle='課堂逐字稿 · iPhone / iPad', iconURL=icon,
        apps=[dict(name='課堂逐字稿 LectureTranscriber', bundleIdentifier=identifier, developerName='Peijung Wu',
            localizedDescription=notes, iconURL=icon,
            versions=versions_list,
            appPermissions=dict(entitlements=[], privacy={k:v for k,v in info.items() if k.startswith('NS') and 'UsageDescription' in k}))], news=[])
    destination.mkdir(parents=True, exist_ok=True)
    for name, value in [('update.json', update), ('sidestore.json', source)]:
        (destination / name).write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(f'Validated {version} build {build}; generated SideStore and in-app metadata')

if __name__ == '__main__': generate(Path(sys.argv[1]), Path(sys.argv[2]))
