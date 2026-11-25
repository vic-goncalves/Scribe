import XCTest
@testable import Scribe

@MainActor
final class SpeakerTests: XCTestCase {
    private func segment(_ id: Int64, _ start: Double, _ text: String, speaker: Int?) -> Segment {
        Segment(id: id, recordingId: 1, start: start, end: start + 2, text: text, speaker: speaker)
    }

    func testSpeakersAreNumberedByFirstAppearanceAndGapsInheritThePreviousSpeaker() {
        let raw = [
            TranscribedSegment(start: 0, end: 1, text: "a", speaker: 7),
            TranscribedSegment(start: 1, end: 2, text: "b", speaker: nil),
            TranscribedSegment(start: 2, end: 3, text: "c", speaker: 2),
            TranscribedSegment(start: 3, end: 4, text: "d", speaker: 7),
            TranscribedSegment(start: 4, end: 5, text: "e", speaker: 0),
        ]
        XCTAssertEqual(Transcriber.numberSpeakers(raw).map(\.speaker), [1, 1, 2, 1, 3])
        XCTAssertEqual(Transcriber.numberSpeakers([TranscribedSegment(start: 0, end: 1, text: "x", speaker: nil)]).map(\.speaker), [nil])
    }

    func testParagraphsBreakAtEverySpeakerChange() {
        let paragraphs = Paragraph.group([
            segment(1, 0, "Hi.", speaker: 1),
            segment(2, 2, "Hello.", speaker: 2),
            segment(3, 4, "How are you", speaker: 2),
            segment(4, 6, "Good.", speaker: 1),
        ])
        XCTAssertEqual(paragraphs.map(\.speaker), [1, 2, 1])
        XCTAssertEqual(paragraphs.map(\.text), ["Hi.", "Hello. How are you", "Good."])
    }

    func testLabelsOnlyShowWithMoreThanOneSpeaker() {
        let solo = [segment(1, 0, "Just me.", speaker: 1)]
        XCTAssertFalse(SpeakerLabels(segments: solo, names: [:]).showsSpeakers)
        XCTAssertNil(SpeakerLabels(segments: solo, names: [:]).label(for: Paragraph(segments: solo)))

        let duo = [segment(1, 0, "Hi.", speaker: 1), segment(2, 2, "Hey.", speaker: 2)]
        let labels = SpeakerLabels(segments: duo, names: [2: "Karen"])
        XCTAssertEqual(labels.numbers, [1, 2])
        XCTAssertEqual(labels.name(1), "Speaker 1")
        XCTAssertEqual(labels.name(2), "Karen")
    }

    func testExportsIncludeSpeakerNames() throws {
        let recording = Recording(id: 1, title: "Sync", fileName: "x.m4a", duration: 10, createdAt: Date(), status: .done)
        let segments = [segment(1, 0, "Ready?", speaker: 1), segment(2, 3, "Yes.", speaker: 2)]

        let text = String(decoding: try TranscriptExporter.data(for: .text, recording: recording, segments: segments, speakerNames: [1: "Noah"]), as: UTF8.self)
        XCTAssertEqual(text, "Sync\n\n[0:00] Noah\nReady?\n\n[0:03] Speaker 2\nYes.\n")

        let srt = String(decoding: try TranscriptExporter.data(for: .subtitles, recording: recording, segments: segments, speakerNames: [1: "Noah"]), as: UTF8.self)
        XCTAssertTrue(srt.contains("Noah: Ready?"))
        XCTAssertTrue(srt.contains("Speaker 2: Yes."))

        let markdown = String(decoding: try TranscriptExporter.data(for: .markdown, recording: recording, segments: segments), as: UTF8.self)
        XCTAssertTrue(markdown.contains("**0:03 · Speaker 2**  \nYes."))
    }

    func testRenamingAndReassigningSpeakersPersists() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ScribeSpeakers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try Library(root: root)
        let wav = root.appendingPathComponent("call.wav")
        try Data(count: 0).write(to: wav)
        let ids = await library.importFiles([wav])
        let id = try XCTUnwrap(ids.first)
        library.saveTranscript(for: id, segments: [
            TranscribedSegment(start: 0, end: 2, text: "Hi.", speaker: 1),
            TranscribedSegment(start: 2, end: 4, text: "Hello.", speaker: 2),
        ], language: "en")

        library.renameSpeaker(2, in: id, to: "  Karen ")
        XCTAssertEqual(library.speakerNames(for: id), [2: "Karen"])
        library.renameSpeaker(2, in: id, to: "")
        XCTAssertEqual(library.speakerNames(for: id), [:], "an empty name resets to the default label")

        let second = try XCTUnwrap(library.segments(for: id).last?.id)
        library.assignSpeaker(1, toSegments: [second])
        XCTAssertEqual(library.segments(for: id).map(\.speaker), [1, 1])

        library.renameSpeaker(1, in: id, to: "Noah")
        library.saveTranscript(for: id, segments: [TranscribedSegment(start: 0, end: 2, text: "Redo.", speaker: 1)], language: "en")
        XCTAssertEqual(library.speakerNames(for: id), [:], "re-transcribing renumbers speakers, so old names are cleared")
    }
}
