import Foundation

struct TranscriptLine: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var start: Double
    var end: Double
    var text: String
}
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
}

struct WindowDecision {
    var confirmed: [TranscriptLine]
    var provisional: [TranscriptLine]
    var consumed: Int
    static func make(lines: [TranscriptLine], samples: Int, offset: Double, final: Bool, previous: [TranscriptLine] = []) -> WindowDecision {
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
    var parts: [AudioPart] = []
    var lines: [TranscriptLine] = []
    var bookmarks: [Bookmark] = []
    var duration: Double { parts.reduce(0) { $0 + Double($1.sampleCount) / 16000 } }
    var hasPendingAudio: Bool { parts.contains { $0.processedSamples < $0.sampleCount } }
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
                if let size = try FileManager.default.attributesOfItem(atPath: audio.path)[.size] as? NSNumber {
                    session.parts[index].sampleCount = size.intValue / MemoryLayout<Float>.size
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
