"""Generate SideStore/update metadata only from an existing validated IPA."""
import datetime, json, plistlib, sys, zipfile
from pathlib import Path

def generate(ipa: Path, destination: Path):
    with zipfile.ZipFile(ipa) as archive:
        assert archive.testzip() is None
        paths = [p for p in archive.namelist() if p.startswith('Payload/') and p.count('/') == 2 and p.endswith('/Info.plist')]
        assert len(paths) == 1
        info = plistlib.loads(archive.read(paths[0]))
        appex_roots = {
            p.split('/Info.plist')[0]
            for p in archive.namelist()
            if '/PlugIns/' in p and '.appex/Info.plist' in p
        }
        assert appex_roots == {'Payload/LectureTranscriber.app/PlugIns/LectureTranscriberWidget.appex'}
        widget = plistlib.loads(archive.read('Payload/LectureTranscriber.app/PlugIns/LectureTranscriberWidget.appex/Info.plist'))
        assert widget['CFBundleIdentifier'] == 'com.peijungwu0302.lecturetranscriber.widget'
    identifier = 'com.peijungwu0302.lecturetranscriber'
    assert info['CFBundleIdentifier'] == identifier
    assert sorted(info['UIDeviceFamily']) == [1, 2]
    version, build = info['CFBundleShortVersionString'], int(info['CFBundleVersion'])
    assert ipa.name in [f'LectureTranscriber-{version}-unsigned.ipa', f'LectureTranscriber-v{version}.ipa']
    base = 'https://raw.githubusercontent.com/peijungwu0302-Wu/argmax-oss-swift-playground/playground-compatible/'
    url = f'https://github.com/peijungwu0302-Wu/argmax-oss-swift-playground/releases/download/v{version}/LectureTranscriber-v{version}.ipa'
    notes = '錄音後自動開啟 PiP 字幕、可即時調整字級與排版、完整逐字稿 Follow Live、PiP 與 Live Activity 返回目前課堂、Live Activity 計時與更新延遲修正，以及 Apple Speech／Translation 系統資源預設流程。'
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
