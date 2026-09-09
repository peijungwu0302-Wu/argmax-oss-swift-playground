import Foundation

struct TranscriptLine: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var start: Double
    var end: Double
    var text: String
    var words: [TranscriptWord]? = nil
}
struct TranscriptWord: Codable, Equatable, Sendable {
    var text: String
    var start: Double
    var end: Double
}
enum RecognitionLanguage {
    static func primary(_ value: String) -> String? {
        switch value { case "mixed", "zh": return "zh"; case "mixed-en", "en": return "en"; default: return nil }
    }
    static func isMixed(_ value: String) -> Bool { value == "mixed" || value == "mixed-en" }
}
struct SpeechDecode: Sendable { var lines: [TranscriptLine]; var endsWithPause: Bool }
struct Bookmark: Codable, Identifiable, Sendable {
    var id = UUID()
    var seconds: Double
    var note: String
}
struct AudioPart: Codable, Identifiable, Sendable {
    var id = UUID()
    var fileName: String
    var offset: Double
    var sampleCount: Int = 0
    var processedSamples: Int = 0
    var languageChanges: [AudioLanguageChange]? = nil
    var recordingQuality: RecordingQuality? = nil
    func language(at sample: Int, fallback: String) -> String {
        languageChanges?.last(where: { $0.sample <= sample })?.language ?? fallback
    }
    func nextLanguageBoundary(after sample: Int) -> Int? {
        languageChanges?.first(where: { $0.sample > sample })?.sample
    }
}
enum RecordingQuality: String, Codable, CaseIterable, Identifiable, Sendable {
    case compact, standard, uncompressed
    var id: String { rawValue }
    var bitRate: Int? {
        switch self { case .compact: return 32000; case .standard: return 64000; case .uncompressed: return nil }
    }
    var title: String {
        switch self {
        case .compact: return "省空間 AAC · 約 14 MB／小時"
        case .standard: return "標準 AAC · 約 29 MB／小時"
        case .uncompressed: return "不壓縮 PCM · 約 115 MB／小時"
        }
    }
}
enum AudioStorage {
    static func bytesPerSample(fileName: String) -> Int? {
        switch URL(fileURLWithPath: fileName).pathExtension.lowercased() {
        case "pcm": return 4 // Legacy Float32 recordings.
        case "pcm16": return 2
        default: return nil // Compressed audio uses the persisted original sample count.
        }
    }
    static func encodePCM16(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let safe = sample.isFinite ? max(-1, min(1, sample)) : 0
            let value = Int16(max(-32768, min(32767, Int((safe * 32768).rounded()))))
            let bits = UInt16(bitPattern: value)
            data.append(UInt8(truncatingIfNeeded: bits)); data.append(UInt8(truncatingIfNeeded: bits >> 8))
        }
        return data
    }
    static func decodePCM16(_ data: Data) -> [Float] {
        let bytes = [UInt8](data)
        return stride(from: 0, to: bytes.count - bytes.count % 2, by: 2).map {
            Float(Int16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8)) / 32768
        }
    }
}

struct DraftTranslationKey: Hashable {
    var sessionID: UUID
    var generation: UUID
    var startSample: Int
    var source: String
    func accepts(_ current: Self) -> Bool {
        sessionID == current.sessionID && generation == current.generation
            && abs(startSample - current.startSample) < 800
            && !source.isEmpty && current.source.hasPrefix(source)
    }
}

// Progressive results may finalize an older interval after a newer draft arrived.
// Only the matching draft can be cleared by that final result.
struct AppleCaptionState {
    var draft: TranscriptLine?
    var finalizedEnd: Double = 0
    mutating func receive(_ line: TranscriptLine, final: Bool) -> TranscriptLine? {
        guard line.start.isFinite, line.end.isFinite, line.start >= 0, line.end >= line.start else { return nil }
        if final {
            guard line.end > finalizedEnd else { return nil }
            finalizedEnd = line.end
            if let current = draft, current.end <= line.end + 0.01 { draft = nil }
            return line.text.isEmpty ? nil : line
        }
        guard line.end > finalizedEnd else { return nil }
        if let current = draft, line.start < current.start - 0.01 { return nil }
        draft = line
        return nil
    }
}
struct AudioLanguageChange: Codable, Equatable, Sendable {
    var sample: Int
    var language: String
}

struct WindowDecision {
    var confirmed: [TranscriptLine]
    var provisional: [TranscriptLine]
    var consumed: Int
    static func make(lines: [TranscriptLine], samples: Int, offset: Double, final: Bool, previous: [TranscriptLine] = [], utteranceEnded: Bool = false) -> WindowDecision {
        if final || utteranceEnded {
            return WindowDecision(confirmed: lines, provisional: [], consumed: samples)
        }
        let words = lines.flatMap { $0.words ?? [] }
        let oldWords = previous.flatMap { $0.words ?? [] }
        // Prefix agreement may only use complete word metadata. Otherwise a
        // wordless segment in the middle could be silently skipped and consumed.
        let completeWords = !lines.isEmpty && lines.allSatisfy { $0.words?.isEmpty == false }
        let completeOldWords = !previous.isEmpty && previous.allSatisfy { $0.words?.isEmpty == false }
        if completeWords && completeOldWords && !words.isEmpty && !oldWords.isEmpty {
            var common: [TranscriptWord] = []
            for (word, previousWord) in zip(words, oldWords) {
                let lhs = word.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let rhs = previousWord.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard lhs == rhs, abs(word.start - previousWord.start) < 0.8,
                      abs(word.end - previousWord.end) < 0.8 else { break }
                common.append(word)
            }
            // Keep two agreed words and 0.8 seconds of right context open for correction.
            let stableCount = max(0, common.count - 2)
            let wordCutoff = offset + Double(samples) / 16000.0 - 0.8
            var stable: [TranscriptWord] = []
            for word in common.prefix(stableCount) {
                guard word.end <= wordCutoff else { break }
                stable.append(word)
            }
            if let last = stable.last, last.end > offset {
                let consumed = min(samples, max(1, Int(((last.end - offset) * 16000).rounded())))
                return WindowDecision(confirmed: CaptionText.lines(stable), provisional: CaptionText.lines(Array(words.dropFirst(stable.count))), consumed: consumed)
            }
        }
        let cutoff = offset + Double(samples) / 16000 - 2
        var confirmed = samples >= 12 * 16000 ? lines.filter { $0.end <= cutoff } : []
        // Earlier confirmation requires agreement across successive decodes, with right context.
        // Compare only a contiguous prefix so we never skip unconfirmed audio in the middle.
        if confirmed.isEmpty && samples >= 3 * 16000 {
            for (line, old) in zip(lines, previous) {
                guard line.end <= cutoff,
                      abs(line.start - old.start) <= 0.5, abs(line.end - old.end) <= 0.5,
                      line.text.trimmingCharacters(in: .whitespacesAndNewlines) == old.text.trimmingCharacters(in: .whitespacesAndNewlines) else { break }
                confirmed.append(line)
            }
        }
        var consumed = 0
        if final || (samples == 26 * 16000 && confirmed.isEmpty) {
            confirmed = lines; consumed = samples
        } else if let last = confirmed.last {
            consumed = min(samples, max(1, Int(((last.end - offset) * 16000).rounded())))
        } else if lines.isEmpty && samples >= 12 * 16000 {
            consumed = samples - 2 * 16000
        }
        return WindowDecision(confirmed: confirmed,
            provisional: lines.filter { line in !confirmed.contains(where: { $0.id == line.id }) }, consumed: consumed)
    }
}
struct LectureSession: Codable, Identifiable, Sendable {
    var id = UUID()
    var title: String
    var createdAt = Date()
    var model: String
    var language: String
    var vocabulary: String? = nil
    var recognitionEngine: String? = nil
    var parts: [AudioPart] = []
    var lines: [TranscriptLine] = []
    var bookmarks: [Bookmark] = []
    var translations: [TranslatedLine]? = nil
    var minutes: String? = nil
    var minutesKind: String? = nil
    var minutesSource: String? = nil
    var sourceText: String { lines.map { "[\(TranscriptExport.clock($0.start))] \($0.text)" }.joined(separator: "\n") }
    var minutesAreCurrent: Bool { minutes != nil && minutesSource == sourceText }
    func translation(for line: TranscriptLine) -> TranslatedLine? {
        translations?.first { $0.id == line.id && $0.source == line.text }
    }
    mutating func appendConfirmed(_ additions: [TranscriptLine]) {
        for addition in additions {
            if let last = lines.last, let oldWords = last.words, let newWords = addition.words,
               !oldWords.isEmpty, !newWords.isEmpty, addition.start - last.end < 0.7,
               addition.start >= last.end - 0.08, addition.end - last.start <= 6,
               !"。！？.!?".contains(last.text.last ?? " "), last.text.count + addition.text.count <= 100 {
                let joined = oldWords + newWords
                lines[lines.count - 1].text = joined.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                lines[lines.count - 1].end = addition.end
                lines[lines.count - 1].words = joined
                translations?.removeAll { $0.id == last.id }
            } else { lines.append(addition) }
        }
    }
    var duration: Double { parts.reduce(0) { $0 + Double($1.sampleCount) / 16000 } }
    var hasPendingAudio: Bool { parts.contains { $0.processedSamples < $0.sampleCount } }
}

enum CaptionText {
    static func after(_ lines: [TranscriptLine], time: Double) -> [TranscriptLine] {
        // Alignment metadata can be missing for only some segments. Preserve
        // those segments using their own time range instead of flattening them away.
        return lines.flatMap { line -> [TranscriptLine] in
            if let words = line.words, !words.isEmpty {
                return self.lines(words.filter { ($0.start + $0.end) / 2 >= time })
            }
            return line.end > time ? [line] : []
        }
    }
    static func lines(_ words: [TranscriptWord]) -> [TranscriptLine] {
        var output: [TranscriptLine] = []; var group: [TranscriptWord] = []
        for word in words {
            if let last = group.last, word.start - last.end > 0.7 {
                output.append(line(group)); group = []
            }
            group.append(word)
            let text = group.map(\.text).joined()
            if text.count >= 48 || "。！？.!?".contains(word.text.last ?? " ") {
                output.append(line(group)); group = []
            }
        }
        if !group.isEmpty { output.append(line(group)) }
        return output
    }
    private static func line(_ words: [TranscriptWord]) -> TranscriptLine {
        TranscriptLine(start: words.first!.start, end: words.last!.end,
                       text: words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines), words: words)
    }
    static func screen(_ text: String, width: Int = 44) -> String {
        guard width > 0 else { return "" }
        // Wrap Latin words as units and CJK as characters; display only the latest two lines.
        var tokens: [String] = []; var latin = ""
        for character in text {
            if character.isASCII && !character.isWhitespace { latin.append(character) }
            else {
                if !latin.isEmpty { tokens.append(latin); latin = "" }
                tokens.append(String(character))
            }
        }
        if !latin.isEmpty { tokens.append(latin) }
        var lines: [String] = []; var current = ""; var used = 0
        for token in tokens {
            let cost = token.reduce(0) { $0 + ($1.isASCII ? 1 : 2) }
            if used + cost > width && !current.isEmpty { lines.append(current); current = ""; used = 0 }
            if current.isEmpty && token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            current += token; used += cost
        }
        if !current.isEmpty { lines.append(current) }
        return lines.suffix(2).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum SpeechBoundary {
    static func endsWithPause(_ samples: [Float]) -> Bool {
        guard samples.count >= 16000 else { return false }
        let block = 320
        var energies: [Double] = []
        for start in stride(from: 0, through: samples.count - block, by: block) {
            let value = samples[start..<(start + block)].reduce(0.0) { $0 + Double($1 * $1) }
            energies.append(sqrt(value / Double(block)))
        }
        let peak = energies.max() ?? 0
        if peak < 0.0001 { return true }
        let threshold = max(0.0003, min(0.003, peak * 0.08))
        return energies.count >= 30 && energies.suffix(30).allSatisfy { $0 < threshold }
            && energies.dropLast(30).contains { $0 > threshold * 3 }
    }
}

struct TranslatedLine: Codable, Identifiable, Sendable {
    var id: UUID
    var source: String
    var text: String
}

enum MeetingNotes {
    // Split on Character boundaries, including a single unusually long utterance.
    static func chunks(_ text: String, limit: Int = 1800) -> [String] {
        guard limit > 0 else { return [] }
        var result: [String] = []; var chunk = ""
        for character in text {
            chunk.append(character)
            if chunk.count >= limit { result.append(chunk); chunk = "" }
        }
        if !chunk.isEmpty { result.append(chunk) }
        return result
    }
    static func outline(_ session: LectureSession) -> String {
        var text = "# \(session.title)\n\n原文整理（未使用 AI 摘要）\n\n"
        if !session.bookmarks.isEmpty {
            text += "## 已標記重點\n" + session.bookmarks.map { "- [\(TranscriptExport.clock($0.seconds))] \($0.note)" }.joined(separator: "\n") + "\n\n"
        }
        text += "## 完整逐字稿\n\n" + session.sourceText
        return text
    }
}

enum TranslationText {
    static func englishRanges(_ text: String) -> [NSRange] {
        let pattern = "[A-Za-z][A-Za-z0-9 \\t'’.,!?;:\"()/%+-]*"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map(\.range)
    }
}
enum LectureError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}
enum TranscriptFormat: String, CaseIterable, Identifiable {
    case txt = "TXT", markdown = "Markdown", srt = "SRT"
    var id: String { rawValue }
    var fileExtension: String {
        switch self { case .txt: return "txt"; case .markdown: return "md"; case .srt: return "srt" }
    }
}
enum TranscriptExport {
    static func clock(_ seconds: Double, milliseconds: Bool = false) -> String {
        let total = max(0, Int((seconds * 1000).rounded()))
        let result = String(format: "%02d:%02d:%02d", total / 3_600_000, (total / 60_000) % 60, (total / 1000) % 60)
        return milliseconds ? result + String(format: ",%03d", total % 1000) : result
    }
    static func render(_ session: LectureSession, as format: TranscriptFormat) -> String {
        let lines = session.lines.sorted { $0.start < $1.start }
        if format == .srt {
            return lines.enumerated().map { index, line in
                "\(index + 1)\n\(clock(line.start, milliseconds: true)) --> \(clock(max(line.end, line.start + 0.05), milliseconds: true))\n\(line.text.trimmingCharacters(in: .whitespacesAndNewlines))\n"
            }.joined(separator: "\n")
        }
        let heading = format == .markdown ? "# " : ""
        var result = "\(heading)\(session.title)\n\n\(session.createdAt.formatted())\n錄音時間：\(clock(session.duration))（不含暫停）\n\n"
        if session.hasPendingAudio { result += "尚有音訊未完成辨識；本次匯出只包含已確認段落。\n\n" }
        result += lines.map { "[\(clock($0.start))] \($0.text)" }.joined(separator: "\n\n")
        if !session.bookmarks.isEmpty {
            result += format == .markdown ? "\n\n## 重點標記\n\n" : "\n\n重點標記\n\n"
            result += session.bookmarks.map { "- [\(clock($0.seconds))] \($0.note)" }.joined(separator: "\n")
        }
        return result + "\n"
    }
}

// Small atomic JSON records; audio is stored separately.
struct SessionStore {
    let root: URL
    init() throws {
        root = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Lectures", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    func save(_ session: LectureSession) throws {
        try FileManager.default.createDirectory(at: folder(session.id), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(session).write(to: folder(session.id).appendingPathComponent("session.json"), options: .atomic)
    }
    func loadAll() throws -> [LectureSession] {
        var result: [LectureSession] = []
        for directory in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            let file = directory.appendingPathComponent("session.json")
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            var session = try JSONDecoder().decode(LectureSession.self, from: Data(contentsOf: file))
            for index in session.parts.indices {
                let audio = directory.appendingPathComponent(session.parts[index].fileName)
                guard FileManager.default.fileExists(atPath: audio.path) else {
                    // JSON is saved before opening the mic; a crash in between can leave an empty part.
                    if session.parts[index].sampleCount == 0 { continue }
                    throw LectureError.message("找不到錄音檔：\(session.title) / \(session.parts[index].fileName)")
                }
                if let width = AudioStorage.bytesPerSample(fileName: audio.lastPathComponent),
                   let size = try FileManager.default.attributesOfItem(atPath: audio.path)[.size] as? NSNumber {
                    session.parts[index].sampleCount = size.intValue / width
                }
            }
            result.append(session)
        }
        return result.sorted { $0.createdAt > $1.createdAt }
    }
    func audioURL(_ session: LectureSession, _ part: AudioPart) -> URL {
        folder(session.id).appendingPathComponent(part.fileName)
    }
    func delete(_ id: UUID) throws {
        // Derive the destination solely from the session UUID, never a title or imported filename.
        let destination = folder(id).standardizedFileURL
        guard destination.deletingLastPathComponent().path == root.standardizedFileURL.path,
              destination.resolvingSymlinksInPath().lastPathComponent == id.uuidString,
              destination.resolvingSymlinksInPath().deletingLastPathComponent().path == root.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw LectureError.message("錄音位置不正確，無法刪除。")
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
    }
    func export(_ session: LectureSession, format: TranscriptFormat) throws -> URL {
        let name = session.title.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ ")).inverted)
            .joined(separator: "_").prefix(60)
        let url = folder(session.id).appendingPathComponent("\(name.isEmpty ? "逐字稿" : String(name)).\(format.fileExtension)")
        try TranscriptExport.render(session, as: format).write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
