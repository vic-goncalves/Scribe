import AVFoundation
import XCTest
@testable import Scribe

@MainActor
final class LibraryTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ScribeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testImportCopiesAudioAndQueuesIt() async throws {
        let library = try Library(root: root)
        let wav = try makeSilentWAV(seconds: 2)
        let notes = root.appendingPathComponent("notes.txt")
        try "hi".write(to: notes, atomically: true, encoding: .utf8)

        let ids = await library.importFiles([wav, notes])

        XCTAssertEqual(ids.count, 1, "non-audio files are skipped")
        let recording = try XCTUnwrap(library.recording(id: ids[0]))
        XCTAssertEqual(recording.title, "meeting")
        XCTAssertEqual(recording.status, .queued)
        XCTAssertEqual(recording.duration, 2, accuracy: 0.05)
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.audioURL(for: recording).path))
        XCTAssertNotEqual(library.audioURL(for: recording), wav, "the file is copied into the library")
        XCTAssertEqual(library.nextQueued()?.id, ids[0])
    }

    func testInterruptedTranscriptionIsRequeuedOnLaunch() async throws {
        let library = try Library(root: root)
        let id = try await importOne(into: library)
        library.setStatus(.transcribing, for: id)

        let relaunched = try Library(root: root)

        XCTAssertEqual(relaunched.recording(id: id)?.status, .queued)
    }

    func testSaveTranscriptStoresSegmentsInOrderAndMarksDone() async throws {
        let library = try Library(root: root)
        let id = try await importOne(into: library)

        library.saveTranscript(for: id, segments: [(0, 2, "Hello there."), (2, 4, "General Kenobi.")], language: "en")

        XCTAssertEqual(library.recording(id: id)?.status, .done)
        XCTAssertEqual(library.recording(id: id)?.language, "en")
        XCTAssertEqual(library.segments(for: id).map(\.text), ["Hello there.", "General Kenobi."])
    }

    func testRetranscribingReplacesOldSegments() async throws {
        let library = try Library(root: root)
        let id = try await importOne(into: library)
        library.saveTranscript(for: id, segments: [(0, 2, "first pass")], language: "en")

        library.saveTranscript(for: id, segments: [(0, 2, "second pass")], language: "en")

        XCTAssertEqual(library.segments(for: id).map(\.text), ["second pass"])
        XCTAssertTrue(library.search("first pass").isEmpty, "search index drops replaced segments")
    }

    func testSearchFindsExactSubstringsAndToleratesTypos() async throws {
        let library = try Library(root: root)
        let id = try await importOne(into: library)
        library.saveTranscript(for: id, segments: [
            (0, 5, "We should revisit the quarterly budget before Friday."),
            (5, 9, "The transcription quality was surprisingly good."),
            (9, 12, "Let's grab lunch."),
        ], language: "en")

        XCTAssertEqual(library.search("budget").map(\.segment.text), ["We should revisit the quarterly budget before Friday."])
        XCTAssertEqual(library.search("QUARTERLY Budget").first?.segment.start, 0, "case-insensitive, multi-word")
        XCTAssertEqual(library.search("transcrption").first?.segment.start, 5, "a missing letter still matches")
        XCTAssertEqual(library.search("suprisingly").first?.segment.start, 5, "a common misspelling still matches")
        XCTAssertEqual(library.search("ffffff").count, 0)
        XCTAssertEqual(library.search("unrelated words entirely").count, 0)
    }

    func testSearchRanksExactMatchesFirstAndHandlesShortQueries() async throws {
        let library = try Library(root: root)
        let id = try await importOne(into: library)
        library.saveTranscript(for: id, segments: [
            (0, 3, "The plannng doc is late."),
            (3, 6, "Planning starts Monday."),
            (6, 9, "Ok so we go."),
        ], language: "en")

        XCTAssertEqual(library.search("planning").map(\.segment.start), [3, 0])
        XCTAssertEqual(library.search("ok").map(\.segment.start), [6], "two-letter queries fall back to substring search")
        XCTAssertTrue(library.search("o").isEmpty, "one-letter queries return nothing")
    }

    func testEditDistance() {
        XCTAssertEqual(Library.editDistance("budget", "budjet"), 1)
        XCTAssertEqual(Library.editDistance("planning", "plannng"), 1)
        XCTAssertEqual(Library.editDistance("kitten", "sitting"), 3)
        XCTAssertEqual(Library.editDistance("", "abc"), 3)
        XCTAssertEqual(Library.editDistance("abc", ""), 3)
    }

    func testSearchHitsCarryTheRecordingTitle() async throws {
        let library = try Library(root: root)
        let id = try await importOne(into: library)
        library.rename(id, to: "  Design review  ")
        library.saveTranscript(for: id, segments: [(0, 3, "Ship it.")], language: "en")

        XCTAssertEqual(library.search("ship").first?.recordingTitle, "Design review")
    }

    func testDeleteRemovesFileSegmentsAndSearchResults() async throws {
        let library = try Library(root: root)
        let id = try await importOne(into: library)
        let recording = try XCTUnwrap(library.recording(id: id))
        library.saveTranscript(for: id, segments: [(0, 3, "Confidential roadmap")], language: "en")

        library.delete(id)

        XCTAssertNil(library.recording(id: id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.audioURL(for: recording).path))
        XCTAssertTrue(library.segments(for: id).isEmpty)
        XCTAssertTrue(library.search("roadmap").isEmpty)
    }

    // MARK: Helpers

    private func importOne(into library: Library) async throws -> Int64 {
        let ids = await library.importFiles([try makeSilentWAV(seconds: 1)])
        return try XCTUnwrap(ids.first)
    }

    private func makeSilentWAV(seconds: Double) throws -> URL {
        let url = root.appendingPathComponent("source-\(UUID().uuidString)").appendingPathComponent("meeting.wav")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let frames = AVAudioFrameCount(seconds * 16_000)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
}
