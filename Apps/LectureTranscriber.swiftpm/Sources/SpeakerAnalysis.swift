import Foundation
import SpeakerKit

struct LectureSpeakers: Sendable {
    var turns: [LectureSpeakerTurn]
    var names: [String: String]
}

actor SpeakerAnalysis {
    func analyze(_ lecture: LectureSession, files: [URL], progress: @escaping @Sendable (String) -> Void) async throws -> LectureSpeakers {
        progress("準備離線講者模型，首次需下載…")
        let config = PyannoteConfig(downloadRevision: "86ec9c929b52208b6656eb6a6361ed0d822a1f78", load: false, verbose: false,
                                    fullRedundancy: false, concurrentSegmenterWorkers: 1, concurrentEmbedderWorkers: 1)
        let engine = try await SpeakerKit(config)
        do {
            var turns: [LectureSpeakerTurn] = []; var names: [String: String] = [:]
            var centroids: [String: [Float]] = [:]
            for (partIndex, part) in lecture.parts.enumerated() {
                // Bound raw audio and intermediate model work for long meetings.
                for start in stride(from: 0, to: part.sampleCount, by: 300 * 16000) {
                    try Task.checkCancellation()
                    let count = min(300 * 16000, part.sampleCount - start)
                    progress("分析講者：\(TranscriptExport.clock(part.offset + Double(start) / 16000)) / \(TranscriptExport.clock(lecture.duration))")
                    let samples = try StoredAudio.read(files[partIndex], from: start, count: count)
                    let result = try await engine.diarize(audioArray: samples,
                        options: PyannoteDiarizationOptions(useExclusiveReconciliation: false))
                    var mapping: [Int: String] = [:]; var used = Set<String>()
                    let localIDs = Set(result.segments.flatMap { $0.speaker.speakerIds }).sorted()
                    for local in localIDs {
                        let vector = result.speakerCentroidEmbeddings[local]
                        let candidates = vector.map { v in
                            centroids.filter { !used.contains($0.key) }.map { ($0.key, Self.distance(v, $0.value)) }.sorted { $0.1 < $1.1 }
                        } ?? []
                        // Conservative beta linking; ambiguous blocks get a new label
                        // which the user can merge. Never assume local ID 0 is global A.
                        let match = candidates.first.flatMap { best -> String? in
                            guard best.1 < 0.25, candidates.count < 2 || candidates[1].1 - best.1 > 0.08 else { return nil }
                            return best.0
                        }
                        let id = match ?? UUID().uuidString
                        if names[id] == nil {
                            let index = names.count
                            names[id] = index < 26 ? "講者 " + String(UnicodeScalar(65 + index)!) : "講者 \(index + 1)"
                        }
                        mapping[local] = id; used.insert(id)
                        if let vector, centroids[id] == nil { centroids[id] = vector }
                    }
                    let offset = part.offset + Double(start) / 16000
                    for segment in result.segments {
                        for local in segment.speaker.speakerIds {
                            guard let id = mapping[local] else { continue }
                            let begin = max(0, Double(segment.startTime)), end = min(Double(count) / 16000, Double(segment.endTime))
                            if end > begin { turns.append(.init(start: offset + begin, end: offset + end, speakerID: id)) }
                        }
                    }
                }
            }
            await engine.unloadModels()
            return .init(turns: turns.sorted { $0.start < $1.start }, names: names)
        } catch { await engine.unloadModels(); throw error }
    }

    static func distance(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 2 }
        var dot = 0.0, aa = 0.0, bb = 0.0
        for i in a.indices { dot += Double(a[i]) * Double(b[i]); aa += Double(a[i]) * Double(a[i]); bb += Double(b[i]) * Double(b[i]) }
        guard aa > 0, bb > 0 else { return 2 }
        return 1 - dot / sqrt(aa * bb)
    }
}
