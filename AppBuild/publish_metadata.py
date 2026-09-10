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
    assert ipa.name == f'LectureTranscriber-{version}-unsigned.ipa'
    base = 'https://raw.githubusercontent.com/peijungwu0302-Wu/argmax-oss-swift-playground/playground-compatible/'
    url = base + 'Deliverables/' + ipa.name
    notes = '較長前後文錄後轉錄、逐段原音核對與音訊另存、離線講者 beta、PiP beta、可調字級與 SideStore 更新。'
    minimum = info.get('MinimumOSVersion', '16.0')
    update = dict(bundleIdentifier=identifier, version=version, build=build, minimumOS=minimum, downloadURL=url, notes=notes)
    icon = base + 'Apps/LectureTranscriber.swiftpm/Sources/Assets.xcassets/AppIcon.appiconset/AppIcon.png'
    source = dict(name='LectureTranscriber 私人更新', identifier='com.peijungwu0302.lecturetranscriber.source',
        sourceURL=base + 'Deliverables/sidestore.json', subtitle='課堂逐字稿 · iPhone / iPad', iconURL=icon,
        apps=[dict(name='課堂逐字稿 LectureTranscriber', bundleIdentifier=identifier, developerName='Peijung Wu',
            localizedDescription=notes, iconURL=icon,
            versions=[dict(version=version, date=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                localizedDescription=notes, downloadURL=url, size=ipa.stat().st_size, minOSVersion=minimum)],
            appPermissions=dict(entitlements=[], privacy=[dict(name='Microphone', usageDescription=info['NSMicrophoneUsageDescription'])]))], news=[])
    destination.mkdir(parents=True, exist_ok=True)
    for name, value in [('update.json', update), ('sidestore.json', source)]:
        (destination / name).write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(f'Validated {version} build {build}; generated SideStore and in-app metadata')

if __name__ == '__main__': generate(Path(sys.argv[1]), Path(sys.argv[2]))
