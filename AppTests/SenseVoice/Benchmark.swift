import Foundation

@main struct SenseVoiceValidation {
    static func main() async throws {
        let engine = SenseVoiceEngine()
        let audio = URL(fileURLWithPath: CommandLine.arguments[1])
        let samples = AudioStorage.decodePCM16(try Data(contentsOf: audio))
        var events: [[String: Any]] = []
        for language in ["auto", "mixed", "mixed-en"] {
            try await engine.load(language: language) { text, _ in print(text) }
            let begin = Date()
            let result = try await engine.transcribe(samples)
            guard result.range(of: "[A-Za-z]", options: .regularExpression) != nil,
                  result.range(of: "[\u{4e00}-\u{9fff}]", options: .regularExpression) != nil else {
                throw LectureError.message("error: Bilingual fixture did not produce both scripts: " + result)
            }
            events.append(["language": language, "text": result, "seconds": Date().timeIntervalSince(begin)])
            print("PASS: SenseVoice \(language): \(result)")
        }
        // Feed only the prefix that has arrived; no future audio in each draft.
        try await engine.load(language: "auto") { _, _ in }
        let longInput = Array((samples + samples + samples).prefix(ReviewWindow.maximumSamples))
        var cursor = 0
        for end in stride(from: 32000, to: longInput.count + 32000, by: 32000) {
            let through = min(end, longInput.count)
            while cursor < through {
                let left = min(cursor, SenseVoiceContext.overlap)
                let from = cursor - left
                let stop = min(through, from + SenseVoiceWindow.maximumSamples)
                let input = Array(longInput[from..<stop])
                let window = SenseVoiceContext.choose(input, left: left, atEnd: through == longInput.count && stop == through)
                guard !window.owned.isEmpty else { break }
                let begin = Date()
                let text = try await engine.transcribe(Array(input.prefix(window.inputCount)), owned: window.owned)
                events.append(["through": through, "start": cursor, "commit": window.commit, "text": text,
                               "inputSamples": window.inputCount, "ownedSamples": window.owned.count, "leftContext": left,
                               "seconds": Date().timeIntervalSince(begin)])
                if window.commit { cursor += window.owned.count } else { break }
            }
        }
        guard cursor == longInput.count else { throw LectureError.message("error: SenseVoice left unconsumed audio") }
        let full = try await engine.transcribeDetailed(longInput)
        guard !full.text.isEmpty, !full.words.isEmpty, full.words.allSatisfy({ $0.start >= 0 && $0.end <= Double(longInput.count) / 16000 }) else {
            throw LectureError.message("error: 30-second model input or CTC anchors failed")
        }
        events.append(["mode": "30-second-context", "samples": longInput.count, "text": full.text, "timedPieces": full.words.count])
        try JSONSerialization.data(withJSONObject: events, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        await engine.unload()
        print("PASS: Core ML FP32/CPU SenseVoice download, initialization, bilingual modes and bounded-prefix finalization")
    }
}
