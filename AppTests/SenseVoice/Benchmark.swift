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
        var cursor = 0
        for end in stride(from: 32000, to: samples.count + 32000, by: 32000) {
            let through = min(end, samples.count)
            while cursor < through {
                let input = Array(samples[cursor..<min(through, cursor + SenseVoiceWindow.maximumSamples)])
                let window = SenseVoiceWindow.choose(input, final: through == samples.count)
                let begin = Date()
                let text = window.hasSpeech ? try await engine.transcribe(Array(input.prefix(window.count))) : ""
                events.append(["through": through, "start": cursor, "commit": window.commit, "text": text,
                               "seconds": Date().timeIntervalSince(begin)])
                if window.commit { cursor += window.count } else { break }
            }
        }
        guard cursor == samples.count else { throw LectureError.message("error: SenseVoice left unconsumed audio") }
        try JSONSerialization.data(withJSONObject: events, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        await engine.unload()
        print("PASS: Native Swift/C SenseVoice download, initialization, bilingual modes and bounded-prefix finalization")
    }
}
