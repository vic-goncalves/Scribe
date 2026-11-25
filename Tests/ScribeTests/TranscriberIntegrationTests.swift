import AVFoundation
import XCTest
@testable import Scribe

/// Downloads the small Whisper model (~220 MB, cached between runs) and transcribes synthesized speech end to end.
/// Run with: SCRIBE_INTEGRATION=1 swift test --filter TranscriberIntegrationTests
@MainActor
final class TranscriberIntegrationTests: XCTestCase {
    func testDownloadsModelAndTranscribesQueuedRecording() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SCRIBE_INTEGRATION"] == "1", "set SCRIBE_INTEGRATION=1")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ScribeIntegration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let modelCache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScribeTestModels")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ScribeIntegration-\(UUID().uuidString)"))

        let audio = try synthesizeSpeech(
            "The quarterly budget review is scheduled for Thursday afternoon. Please bring the hiring plan.",
            to: root.appendingPathComponent("review.m4a")
        )
        let library = try Library(root: root)
        let ids = await library.importFiles([audio])
        let id = try XCTUnwrap(ids.first)

        let fast = try XCTUnwrap(ModelOption.all.first { $0.name == "Fast" })
        let transcriber = Transcriber(library: library, modelsDirectory: modelCache, defaults: defaults)
        await transcriber.install(fast)
        XCTAssertEqual(transcriber.phase, .ready)
        XCTAssertFalse(transcriber.isInstalling)

        let deadline = Date().addingTimeInterval(300)
        while library.recording(id: id)?.status != .done, library.recording(id: id)?.status != .failed, Date() < deadline {
            try await Task.sleep(for: .milliseconds(250))
        }

        let recording = try XCTUnwrap(library.recording(id: id))
        XCTAssertEqual(recording.status, .done, recording.errorMessage ?? "")
        XCTAssertEqual(recording.language, "en")
        let segments = library.segments(for: id)
        let text = segments.map(\.text).joined(separator: " ").lowercased()
        for word in ["quarterly", "budget", "thursday", "hiring"] {
            XCTAssertTrue(text.contains(word), "expected \"\(word)\" in: \(text)")
        }
        XCTAssertGreaterThan(segments.last?.end ?? 0, 3)
        XCTAssertEqual(library.search("budjet revew").first?.segment.recordingId, id, "fuzzy search finds the new transcript")

        // A second Transcriber loads the saved model from disk without downloading.
        let relaunched = Transcriber(library: library, modelsDirectory: modelCache, defaults: defaults)
        let loadDeadline = Date().addingTimeInterval(120)
        while relaunched.phase != .ready, Date() < loadDeadline {
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTAssertEqual(relaunched.phase, .ready)
        XCTAssertEqual(relaunched.currentModel, fast)
        XCTAssertEqual(Set(relaunched.downloadedModels.keys), [fast.id])
    }

    func testSeparatesTwoDistinctVoices() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SCRIBE_INTEGRATION"] == "1", "set SCRIBE_INTEGRATION=1")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ScribeDiarization-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let modelCache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScribeTestModels")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ScribeDiarization-\(UUID().uuidString)"))

        // A female US voice and a male UK voice take turns.
        let turns = [
            ("Samantha", "Good morning. I wanted to walk through the launch checklist before Friday."),
            ("Daniel", "Sure. I reviewed the pricing page yesterday and it still has the old numbers."),
            ("Samantha", "Okay, I will fix the pricing page today and send it to legal for review."),
            ("Daniel", "Great. Then the only open item is the announcement email for customers."),
        ]
        let audio = try synthesizeConversation(turns, to: root.appendingPathComponent("launch.wav"))
        let library = try Library(root: root)
        let ids = await library.importFiles([audio])
        let id = try XCTUnwrap(ids.first)

        let fast = try XCTUnwrap(ModelOption.all.first { $0.name == "Fast" })
        let transcriber = Transcriber(library: library, modelsDirectory: modelCache, defaults: defaults)
        await transcriber.install(fast)

        let deadline = Date().addingTimeInterval(300)
        while library.recording(id: id)?.status != .done, library.recording(id: id)?.status != .failed, Date() < deadline {
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTAssertEqual(library.recording(id: id)?.status, .done)

        let paragraphs = Paragraph.group(library.segments(for: id))
        func speaker(saying phrase: String) -> Int? {
            paragraphs.first { $0.text.lowercased().contains(phrase) }?.speaker
        }
        let samantha = speaker(saying: "launch checklist")
        let daniel = speaker(saying: "pricing page yesterday")
        XCTAssertNotNil(samantha)
        XCTAssertNotNil(daniel)
        XCTAssertNotEqual(samantha, daniel, "different voices get different speakers: \(paragraphs.map { "\($0.speaker ?? 0): \($0.text)" })")
        XCTAssertEqual(speaker(saying: "send it to legal"), samantha)
        XCTAssertEqual(speaker(saying: "announcement email"), daniel)
    }

    /// Speaks each turn with its voice and joins them with short pauses into one WAV file.
    private func synthesizeConversation(_ turns: [(voice: String, text: String)], to url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1))
        let output = try AVAudioFile(forWriting: url, settings: format.settings)
        let pause = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        pause.frameLength = 16_000
        for (index, turn) in turns.enumerated() {
            let aiff = url.deletingLastPathComponent().appendingPathComponent("turn\(index).aiff")
            let wav = url.deletingLastPathComponent().appendingPathComponent("turn\(index).wav")
            try run("/usr/bin/say", ["-v", turn.voice, "-o", aiff.path, turn.text])
            try run("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEF32@22050", "-c", "1", aiff.path, wav.path])
            let input = try AVAudioFile(forReading: wav, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: AVAudioFrameCount(input.length)))
            try input.read(into: buffer)
            try output.write(from: buffer)
            try output.write(from: pause)
        }
        return url
    }

    private func synthesizeSpeech(_ text: String, to url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let aiff = url.deletingPathExtension().appendingPathExtension("aiff")
        try run("/usr/bin/say", ["-o", aiff.path, text])
        try run("/usr/bin/afconvert", ["-f", "m4af", "-d", "aac", aiff.path, url.path])
        return url
    }

    private func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(tool) failed")
    }
}
