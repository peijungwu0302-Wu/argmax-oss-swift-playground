import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
check(TranscriptExport.clock(59.9996, milliseconds: true) == "00:01:00,000", "Milliseconds must carry into the next minute")
check(TranscriptExport.clock(3600.125, milliseconds: true) == "01:00:00,125", "Hour timestamps")
check(TranscriptExport.clock(-1) == "00:00:00", "Clamp negative timestamps")
let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
let store = try SessionStore(root: directory)
var session = LectureSession(title: "中文 / English 課堂", model: "test", language: "auto")
session.lines = [TranscriptLine(start: 2.1, end: 3.25, text: "Hello 中文"), TranscriptLine(start: 0, end: 1, text: "開場")]
session.bookmarks = [Bookmark(seconds: 2, note: "重點")]
session.parts = [AudioPart(fileName: "test.pcm", offset: 0, sampleCount: 16000, processedSamples: 16000)]
try store.save(session)
// Simulate a crash after audio was persisted but before JSON was checkpointed.
try Data(repeating: 0, count: 32000 * 4).write(to: store.audioURL(session, session.parts[0]))
let recovered = try store.loadAll()[0]
check(recovered.parts[0].sampleCount == 32000, "Recovery must account for unsaved audio samples")
check(recovered.parts[0].processedSamples == 16000, "Recovery must retain last confirmed boundary")
check(recovered.hasPendingAudio, "Interrupted audio must be recoverable")
check(recovered.lines == session.lines, "UTF-8 transcript must survive persistence")
let srt = TranscriptExport.render(session, as: .srt)
check(srt.hasPrefix("1\n00:00:00,000 --> 00:00:01,000\n開場\n"), "SRT must sort segments and start numbering at one")
check(srt.contains("2\n00:00:02,100 --> 00:00:03,250\nHello 中文"), "SRT time and Unicode preservation")
check(!srt.contains("重點"), "Bookmarks must not create phantom subtitle cues")
check(TranscriptExport.render(recovered, as: .txt).contains("尚有音訊未完成"), "Incomplete export must be disclosed")
check(TranscriptExport.render(session, as: .markdown).contains("## 重點標記"), "Markdown bookmarks")
let exported = try store.export(session, format: .txt)
check(exported.deletingLastPathComponent() == store.folder(session.id), "Title must not escape export directory")
let exportedText = try String(contentsOf: exported, encoding: .utf8)
check(exportedText.contains("Hello 中文"), "Real exported file content")
print("PASS: timestamps, SRT, Unicode, atomic persistence, interruption recovery, safe export paths")
