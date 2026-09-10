import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
check(TranscriptExport.clock(59.9996, milliseconds: true) == "00:01:00,000", "Milliseconds must carry into the next minute")
check(TranscriptExport.clock(3600.125, milliseconds: true) == "01:00:00,125", "Hour timestamps")
check(TranscriptExport.clock(-1) == "00:00:00", "Clamp negative timestamps")
let early = TranscriptLine(start: 0, end: 7, text: "確認句")
let tail = TranscriptLine(start: 7, end: 12, text: "尚未說完")
let live = WindowDecision.make(lines: [early, tail], samples: 12 * 16000, offset: 0, final: false)
check(live.confirmed == [early] && live.provisional == [tail], "Keep the unstable tail provisional")
check(live.consumed == 7 * 16000, "Advance only to the confirmed segment boundary")
let stopped = WindowDecision.make(lines: [tail], samples: 5 * 16000, offset: 7, final: true)
check(stopped.confirmed == [tail] && stopped.consumed == 5 * 16000, "Pause must flush short trailing speech")
let silence = WindowDecision.make(lines: [], samples: 12 * 16000, offset: 0, final: false)
check(silence.consumed == 10 * 16000, "Silence must progress while retaining right context")
let spanning = TranscriptLine(start: 40, end: 66, text: "很長的連續語句")
let full = WindowDecision.make(lines: [spanning], samples: 26 * 16000, offset: 40, final: false)
check(full.confirmed == [spanning] && full.consumed == 26 * 16000, "Long unsegmented speech must not stall")
let preview = WindowDecision.make(lines: [early], samples: 7 * 16000, offset: 0, final: false)
check(preview.consumed == 0 && preview.provisional == [early], "Short preview must not advance durable position")
let phrase = TranscriptLine(start: 0, end: 2, text: "中文 with CRISPR")
let agreement = WindowDecision.make(lines: [phrase], samples: 5 * 16000, offset: 0, final: false, previous: [phrase])
check(agreement.confirmed == [phrase] && agreement.consumed == 2 * 16000, "Repeated stable speech can confirm before twelve seconds")
let changed = TranscriptLine(start: 0, end: 2, text: "中文 with Cas9")
let disagreement = WindowDecision.make(lines: [changed], samples: 5 * 16000, offset: 0, final: false, previous: [phrase])
check(disagreement.consumed == 0, "A revised hypothesis must not be committed early")
let tooRecent = WindowDecision.make(lines: [phrase], samples: 3 * 16000, offset: 0, final: false, previous: [phrase])
check(tooRecent.consumed == 0, "Agreement must retain right context")
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
let oldJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as! [String: Any]
var legacy = oldJSON
legacy.removeValue(forKey: "vocabulary")
let oldSession = try JSONDecoder().decode(LectureSession.self, from: JSONSerialization.data(withJSONObject: legacy))
check(oldSession.vocabulary == nil, "Existing sessions without vocabulary must still open")
let neighbor = LectureSession(title: "保留的錄音", model: "test", language: "mixed", vocabulary: "Cas9")
try store.save(neighbor)
try store.delete(session.id)
check(!FileManager.default.fileExists(atPath: store.folder(session.id).path), "Deleting a session removes audio, JSON and local exports")
let remaining = try store.loadAll()
check(remaining.count == 1 && remaining[0].id == neighbor.id && remaining[0].vocabulary == "Cas9", "Deletion must preserve the other lecture and vocabulary")
try store.delete(session.id)
let outside = directory.appendingPathComponent("outside")
try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
let marker = outside.appendingPathComponent("keep.txt")
try Data("keep".utf8).write(to: marker)
let linkID = UUID()
try FileManager.default.createSymbolicLink(at: store.folder(linkID), withDestinationURL: outside)
var rejected = false
do { try store.delete(linkID) } catch { rejected = true }
check(rejected && FileManager.default.fileExists(atPath: marker.path), "Deletion must reject redirected session directories")
print("PASS: streaming agreement, legacy data, isolated deletion, timestamps, SRT, persistence and recovery")
check(oldSession.translations == nil && oldSession.minutes == nil, "Old recordings open without translation or minutes fields")
var meeting = LectureSession(title: "雙語課堂", model: "test", language: "mixed")
let bilingual = TranscriptLine(start: 0, end: 3, text: "今天討論 gene editing，next week 再見。")
meeting.lines = [bilingual]
meeting.translations = [TranslatedLine(id: bilingual.id, source: bilingual.text, text: "今天討論基因編輯，下週再見。")]
check(meeting.translation(for: bilingual)?.text.contains("基因編輯") == true, "Translation is associated with its source segment")
var revised = bilingual; revised.text = "修改後的原文"
check(meeting.translation(for: revised) == nil, "An old translation must never be shown for edited source text")
meeting.minutes = "測試整理"; meeting.minutesSource = meeting.sourceText
check(meeting.minutesAreCurrent, "New notes match their source")
meeting.lines.append(TranscriptLine(start: 4, end: 5, text: "新增內容"))
check(!meeting.minutesAreCurrent, "Continuing a recording invalidates old notes")
let mixedRanges = TranslationText.englishRanges(bilingual.text)
let english = mixedRanges.map { (bilingual.text as NSString).substring(with: $0) }
check(english == ["gene editing", "next week "], "Translation separates English from Chinese without losing range offsets")
check(TranslationText.englishRanges("純中文，數字 123。").isEmpty, "Do not translate Chinese into itself")
let unicode = String(repeating: "👩🏽‍💻中英\n", count: 1000)
let chunks = MeetingNotes.chunks(unicode, limit: 137)
check(chunks.joined() == unicode && chunks.allSatisfy { $0.count <= 137 }, "Long lecture chunks retain every Unicode character within the input budget")
let storedMeeting = try JSONDecoder().decode(LectureSession.self, from: JSONEncoder().encode(meeting))
check(storedMeeting.translations?.first?.text == meeting.translations?.first?.text && storedMeeting.minutes == meeting.minutes, "Translations and notes survive reopening")
check(MeetingNotes.outline(meeting).contains("未使用 AI") && MeetingNotes.outline(meeting).contains(meeting.sourceText), "Fallback is explicitly original text and retains the entire transcript")
print("PASS: bilingual translation identity, stale notes, legacy decoding and bounded Unicode chunks")
check(RecognitionLanguage.primary("mixed") == "zh" && RecognitionLanguage.primary("mixed-en") == "en", "Mixed mode must honor the user's primary-language choice")
check(RecognitionLanguage.primary("auto") == nil, "Automatic mode must not secretly force Chinese")
check(oldSession.recognitionEngine == nil && oldSession.lines.allSatisfy { $0.words == nil }, "Legacy recordings keep their original engine and decode without word metadata")
let words = (0..<6).map { TranscriptWord(text: " word\($0)", start: Double($0) * 0.4, end: Double($0 + 1) * 0.4) }
let hypothesis = CaptionText.lines(words)
let eager = WindowDecision.make(lines: hypothesis, samples: 4 * 16000, offset: 0, final: false, previous: hypothesis)
check(eager.confirmed.flatMap { $0.words ?? [] } == Array(words.prefix(4)), "Stable words become durable without waiting for the whole sentence")
check(eager.provisional.flatMap { $0.words ?? [] } == Array(words.suffix(2)), "Two agreed tail words stay available for correction")
let endpoint = WindowDecision.make(lines: hypothesis, samples: 4 * 16000, offset: 0, final: false, utteranceEnded: true)
check(endpoint.consumed == 64000 && endpoint.provisional.isEmpty, "A detected utterance ending flushes the short phrase")
check(SpeechBoundary.endsWithPause(Array(repeating: 0.1, count: 16000) + Array(repeating: 0, count: 9600)), "A 600 ms quiet tail after speech is an endpoint")
check(!SpeechBoundary.endsWithPause(Array(repeating: 0.1, count: 16000) + Array(repeating: 0, count: 4800)), "A brief hesitation must not end the utterance")
check(!SpeechBoundary.endsWithPause(Array(repeating: 0.003, count: 32000)), "Constant background noise is not a speech-to-silence transition")
let retained = CaptionText.after(hypothesis, time: 0.8).flatMap { $0.words ?? [] }
check(retained == Array(words.dropFirst(2)), "Rewound context must not duplicate already confirmed words")
let cc = CaptionText.screen(String(repeating: "中文 English ", count: 12) + "final", width: 20)
check(cc.components(separatedBy: "\n").count <= 2 && cc.hasSuffix("final") && !cc.contains("Eng\n"), "CC shows the newest two lines without splitting English words")
var grouped = LectureSession(title: "片段", model: "test", language: "mixed-en", recognitionEngine: "whisper")
grouped.appendConfirmed(CaptionText.lines(Array(words.prefix(2))))
let stableID = grouped.lines[0].id
grouped.translations = [TranslatedLine(id: stableID, source: grouped.lines[0].text, text: "舊翻譯")]
grouped.appendConfirmed(CaptionText.lines(Array(words.dropFirst(2).prefix(2))))
check(grouped.lines.count == 1 && grouped.lines[0].id == stableID && grouped.lines[0].words?.count == 4, "Short stable prefixes grow into the same readable caption")
check(grouped.translations?.isEmpty == true, "A growing caption must invalidate its previous partial translation")
print("PASS: primary languages, word agreement, pause endpoints, overlap deduplication and CC captions")

let unalignedEnglish = TranscriptLine(start: 2.4, end: 3.4, text: "English without alignment")
let mixedMetadata = hypothesis + [unalignedEnglish]
let filteredMetadata = CaptionText.after(mixedMetadata, time: 0.8)
check(filteredMetadata.contains(where: { $0.id == unalignedEnglish.id }), "An unaligned English segment must survive alongside aligned segments")
check(filteredMetadata.flatMap { $0.words ?? [] } == Array(words.dropFirst(2)), "Metadata fallback must still remove the aligned overlap")
let unalignedBeginning = TranscriptLine(start: 0, end: 0.2, text: "Keep this opening")
let metadataGap = [unalignedBeginning] + hypothesis
let gapDecision = WindowDecision.make(lines: metadataGap, samples: 4 * 16000, offset: 0, final: false, previous: metadataGap)
check(gapDecision.confirmed.first?.id == unalignedBeginning.id, "Word agreement must not consume an unaligned opening without saving it")
let removedOld = CaptionText.after([TranscriptLine(start: 0, end: 0.5, text: "old"), unalignedEnglish], time: 0.8)
check(removedOld == [unalignedEnglish], "Unaligned segment fallback still respects its segment boundary")
print("PASS: partial alignment metadata does not erase English segments or skip unsaved audio")
var languagePart = AudioPart(fileName: "switch.pcm", offset: 0, sampleCount: 160000,
    languageChanges: [AudioLanguageChange(sample: 0, language: "zh"), AudioLanguageChange(sample: 64000, language: "en"), AudioLanguageChange(sample: 128000, language: "zh")])
check(languagePart.language(at: 63999, fallback: "auto") == "zh", "Audio before the switch keeps the original recognizer language")
check(languagePart.language(at: 64000, fallback: "auto") == "en", "Audio at the switch boundary uses the selected language")
check(languagePart.nextLanguageBoundary(after: 0) == 64000 && languagePart.nextLanguageBoundary(after: 64000) == 128000, "A recognizer cannot be fed audio beyond its language interval")
check(languagePart.nextLanguageBoundary(after: 128000) == nil, "The last language runs through the remaining audio")
let recoveredLanguagePart = try JSONDecoder().decode(AudioPart.self, from: JSONEncoder().encode(languagePart))
check(recoveredLanguagePart.languageChanges == languagePart.languageChanges, "Language boundaries survive interruption and reopening")
check(AudioPart(fileName: "legacy.pcm", offset: 0).language(at: 100, fallback: "en") == "en", "Legacy audio without a language timeline uses the saved language")
print("PASS: durable language intervals for continuous Apple capture and recovery")

let key = DraftTranslationKey(sessionID: UUID(), generation: UUID(), startSample: 0, source: "Hello")
var growingKey = key; growingKey.source = "Hello world"
check(key.accepts(growingKey), "An earlier prefix translation may follow the same growing phrase")
var repeatedKey = key; repeatedKey.startSample = 64000
check(!key.accepts(repeatedKey) && key != repeatedKey, "The same words spoken later require a new translation")
var switchedKey = key; switchedKey.generation = UUID()
check(!key.accepts(switchedKey), "A language switch invalidates in-flight translations")
var correctedKey = key; correctedKey.source = "Yellow"
check(!key.accepts(correctedKey), "A corrected phrase cannot display a stale prefix translation")
var captions = AppleCaptionState()
let firstDraft = TranscriptLine(start: 0, end: 2, text: "First draft")
let nextDraft = TranscriptLine(start: 2, end: 4, text: "Next phrase")
_ = captions.receive(firstDraft, final: false)
_ = captions.receive(nextDraft, final: false)
let confirmedOld = captions.receive(TranscriptLine(start: 0, end: 2, text: "First final"), final: true)
check(confirmedOld?.text == "First final" && captions.draft?.text == "Next phrase", "An older final cannot erase a newer draft")
check(captions.receive(firstDraft, final: true) == nil, "Duplicate finalized intervals cannot append duplicate transcript rows")
_ = captions.receive(firstDraft, final: false)
check(captions.draft?.text == "Next phrase", "Late volatile updates cannot resurrect already-finalized text")
_ = captions.receive(nextDraft, final: true)
check(captions.draft == nil, "The matching final clears its own draft")
let pcmValues: [Float] = [-1.1, -1, -0.3, 0, 0.3, 1, 1.1, .nan, .infinity]
let pcmData = AudioStorage.encodePCM16(pcmValues)
let pcmDecoded = AudioStorage.decodePCM16(pcmData)
check(pcmData.count == pcmValues.count * 2, "PCM16 uses half the legacy storage")
check(pcmDecoded[0] == -1 && pcmDecoded[5] < 1 && pcmDecoded[7] == 0, "PCM16 clamps safely and sanitizes invalid samples")
check(abs(pcmDecoded[2] + 0.3) < 0.00004, "PCM16 preserves speech samples within quantization tolerance")
var smallSession = LectureSession(title: "PCM16 recovery", model: "test", language: "en")
smallSession.parts = [AudioPart(fileName: "test.pcm16", offset: 0, sampleCount: 3, recordingQuality: .compact)]
try store.save(smallSession)
try pcmData.write(to: store.audioURL(smallSession, smallSession.parts[0]))
let smallRecovered = try store.loadAll().first { $0.id == smallSession.id }!
check(smallRecovered.parts[0].sampleCount == pcmValues.count && smallRecovered.parts[0].recordingQuality == .compact, "PCM16 crash recovery uses two bytes per sample and preserves archive quality")
check(AudioStorage.bytesPerSample(fileName: "old.pcm") == 4 && AudioStorage.bytesPerSample(fileName: "new.m4a") == nil, "Compressed byte counts must never be mistaken for raw sample counts")
print("PASS: translation generations, repeated phrases, late Apple finals, PCM16 quantization and recovery")

let speechBurst = [Float](repeating: 0.08, count: 24000)
let quietTail = [Float](repeating: 0, count: 9600)
let senseDraft = SenseVoiceWindow.choose(speechBurst, final: false)
check(!senseDraft.commit && senseDraft.hasSpeech, "SenseVoice holds a growing utterance as a revisable draft")
let sensePause = SenseVoiceWindow.choose(speechBurst + quietTail + speechBurst, final: false)
check(sensePause.commit && sensePause.count == 33600, "SenseVoice cuts at the first complete pause without consuming the following utterance")
check(SenseVoiceWindow.choose([Float](repeating: 0, count: 32000), final: false).commit, "SenseVoice advances through silence without hallucinated decoding")
let senseBounded = SenseVoiceWindow.choose([Float](repeating: 0.08, count: 16 * 16000), final: false)
check(senseBounded.commit && senseBounded.count == 12 * 16000, "Continuous SenseVoice input cannot grow without bound or replay forever")
check(SenseVoiceWindow.choose(Array(speechBurst.prefix(8000)), final: true).commit, "Stopping flushes the short final utterance")
check(SenseVoiceWindow.modelLanguage("mixed") == "zh" && SenseVoiceWindow.modelLanguage("mixed-en") == "en" && SenseVoiceWindow.modelLanguage("auto") == "auto", "SenseVoice primary-language settings reach the model")
print("PASS: SenseVoice draft, pause boundary, silence, bounded input, final flush and language routing")

let pieces = ["<unk>", "<|zh|>", "中", "文", "▁gene", "▁editing", "<0xE4>", "<0xB8>", "<0xAD>"]
check(SenseVoiceText.decode([1, 2, 3, 4, 5], vocabulary: pieces) == "中文 gene editing", "Core ML detokenizer preserves Chinese and English word boundaries")
check(SenseVoiceText.decode([6, 7, 8], vocabulary: pieces) == "中", "Byte fallback is decoded as one UTF-8 sequence")
print("PASS: Core ML CTC text and UTF-8 byte decoding")

let noisyPhrase = [Float](repeating: 0.08, count: 32000) + [Float](repeating: 0.008, count: 12800) + [Float](repeating: 0.08, count: 32000)
let noisyCut = SenseVoiceWindow.choose(noisyPhrase, final: false)
check(noisyCut.commit && noisyCut.count > 32000 && noisyCut.count < 44800, "SenseVoice detects a pause over a steady music/noise floor")
var longNoise = [Float](repeating: 0.08, count: SenseVoiceWindow.maximumSamples)
longNoise.replaceSubrange(128000..<131200, with: [Float](repeating: 0.018, count: 3200))
let valleyCut = SenseVoiceWindow.choose(longNoise, final: false)
check(valleyCut.commit && valleyCut.count > 120000 && valleyCut.count < 140000, "Hard cap chooses an acoustic valley, not a fixed 12-second mid-word cut")
check(store.audioBytes(smallRecovered) == Int64(pcmData.count), "Library audio size reads actual disk bytes")
print("PASS: adaptive SenseVoice pause/valley and actual library file size")

// Exercise the actual range planner, including short tails and a multi-window
// recording. Ownership is continuous even though inference inputs overlap.
for length in [1, 3199, 3200, 16000, 192000, 192001, 65 * 16000 + 137] {
    for amplitude in [Float(0.0001), Float(0.08)] {
    var cursor = 0
    while cursor < length {
        let left = min(SenseVoiceContext.overlap, cursor)
        let readStart = cursor - left
        let readCount = min(SenseVoiceWindow.maximumSamples, length - readStart)
        let input = [Float](repeating: amplitude, count: readCount)
        let plan = SenseVoiceContext.choose(input, left: left, atEnd: readStart + readCount == length)
        check(plan.commit && !plan.owned.isEmpty, "Recovery must advance, including very quiet speech and sub-200ms tails")
        check(readStart + plan.owned.lowerBound == cursor, "No sample gap at an ownership boundary")
        check(plan.inputCount <= readCount && plan.inputCount <= SenseVoiceWindow.maximumSamples,
              "Inference cannot read past the saved file or model bound")
        check(plan.inputCount >= plan.owned.upperBound, "All owned audio reaches inference")
        if readStart + plan.owned.upperBound < length {
            check(plan.inputCount > plan.owned.upperBound, "A continuing segment has right context")
        }
        cursor += plan.owned.count
    }
    check(cursor == length, "Final cursor must include every last sample exactly once")
    }
}
let contextDraft = SenseVoiceContext.choose([Float](repeating: 0.08, count: 4 * 16000), left: 0, atEnd: false)
check(!contextDraft.commit && contextDraft.owned.upperBound == 3 * 16000, "Live speech keeps right context out of confirmed text")
let contextCap = SenseVoiceContext.choose([Float](repeating: 0.08, count: 12 * 16000), left: 16000, atEnd: false)
check(contextCap.commit && contextCap.owned == 16000..<176000 && contextCap.inputCount == 192000,
      "A full context window owns only its center, not the replayed edges")

let ctcVocab = ["<blank>", "<|en|>", "▁very", "▁good", "<0xE4>", "<0xB8>", "<0xAD>"]
let ctcPath = [1, 1, 1, 1, 2, 2, 0, 2, 0, 3, 0]
let wholeCTC = SenseVoiceCTC.tokens(ctcPath, owned: nil, vocabulary: ctcVocab)
check(wholeCTC == [2, 2, 3], "CTC blank-separated repeated words must survive")
let ctcLeft = SenseVoiceCTC.tokens(ctcPath, owned: 0..<2880, vocabulary: ctcVocab)
let ctcRight = SenseVoiceCTC.tokens(ctcPath, owned: 2880..<20000, vocabulary: ctcVocab)
check(ctcLeft + ctcRight == wholeCTC, "A seam owns an emission on one side only")
let bytePath = [1, 1, 1, 1, 4, 5, 6, 0, 3]
let byteLeft = SenseVoiceCTC.tokens(bytePath, owned: 0..<960, vocabulary: ctcVocab)
let byteRight = SenseVoiceCTC.tokens(bytePath, owned: 960..<20000, vocabulary: ctcVocab)
check(SenseVoiceText.decode(byteLeft, vocabulary: ctcVocab) == "中" && byteRight == [3],
      "A seam cannot split a UTF-8 fallback sequence")

var reSource = smallRecovered
reSource.lines = [TranscriptLine(start: 0, end: 1, text: "我的手動修改")]
reSource.translations = [TranslatedLine(id: reSource.lines[0].id, source: "我的手動修改", text: "my edit")]
reSource.minutes = "保留筆記"; reSource.minutesSource = reSource.sourceText
reSource.bookmarks = [Bookmark(seconds: 0.5, note: "保留標記")]
reSource.translationSource = "ja"
reSource.parts[0].processedSamples = reSource.parts[0].sampleCount
try store.save(reSource)
let originalJSON = try Data(contentsOf: store.folder(reSource.id).appendingPathComponent("session.json"))
let reCopy = try store.copyForRetranscription(reSource)
check(reCopy.id != reSource.id && reCopy.hasPendingAudio && reCopy.lines.isEmpty,
      "Even completed audio is reprocessed in an independent lecture")
check(reCopy.translations == nil && reCopy.minutes == nil && reCopy.translationSource == "ja",
      "New recognition cannot inherit stale translations or notes")
check(reCopy.bookmarks.map(\.note) == ["保留標記"] && reCopy.recognitionEngine == "sensevoice",
      "Retranscription retains bookmarks and routes to SenseVoice")
let copiedAudio = try Data(contentsOf: store.audioURL(reCopy, reCopy.parts[0]))
check(copiedAudio == pcmData,
      "Retranscription copies the exact saved recording")
try store.delete(reCopy.id)
let retainedJSON = try Data(contentsOf: store.folder(reSource.id).appendingPathComponent("session.json"))
check(retainedJSON == originalJSON,
      "Deleting a retranscription cannot alter the original edits, translations or notes")
let retainedAudio = try Data(contentsOf: store.audioURL(reSource, reSource.parts[0]))
check(retainedAudio == pcmData,
      "The source audio must remain independently available")
print("PASS: context coverage, CTC seams, UTF-8 and independent full retranscription copy")

for length in [1, 3200, 480000, 480001, 2 * 480000 + 333] {
    var cursor = 0
    while cursor < length {
        let left = min(ReviewWindow.context, cursor), begin = cursor - min(ReviewWindow.context, cursor)
        let count = min(ReviewWindow.maximumSamples, length - begin)
        let plan = ReviewWindow.choose([Float](repeating: 0.08, count: count), left: left, atEnd: begin + count == length)
        check(plan.commit && plan.owned.count > 0 && begin + plan.owned.lowerBound == cursor, "Long-context review advances without audio gaps")
        check(plan.inputCount <= 480000 && plan.owned.upperBound <= plan.inputCount, "Review respects pinned frontend 30-second capacity")
        cursor += plan.owned.count
    }
    check(cursor == length, "Review retains exact final sample")
}
var timeline = LectureSession(title: "兩段", model: "test", language: "auto")
timeline.parts = [.init(fileName: "a.pcm16", offset: 0, sampleCount: 32000), .init(fileName: "b.pcm16", offset: 2, sampleCount: 48000)]
let slices = try AudioTimeline.slices(timeline, start: 1.5, end: 3.25)
check(slices.count == 2 && slices[0].start == 24000 && slices[0].count == 8000 && slices[1].count == 20000,
      "A manual review clip crosses saved parts at the exact sample boundary")
var invalidRangeRejected = false
do { _ = try AudioTimeline.slices(timeline, start: -1, end: 2) } catch { invalidRangeRejected = true }
check(invalidRangeRejected, "Invalid clip cannot read unrelated audio")
timeline.speakerNames = ["a": "老師", "b": "學生"]
timeline.speakerTurns = [.init(start: 0, end: 2, speakerID: "a"), .init(start: 1, end: 3, speakerID: "b")]
check(timeline.speakerLabel(.init(start: 0, end: 0.8, text: "test")) == "老師：", "Confirmed speaker labels use user names")
check(timeline.speakerLabel(.init(start: 1.2, end: 1.5, text: "test")).contains("多位"), "Overlapping voices cannot be falsely assigned to one person")
print("PASS: 30-second review, sample-exact cross-part timeline and uncertain speaker labels")
