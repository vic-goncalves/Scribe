import AppKit
import XCTest
@testable import Scribe

final class TranscriptFormattingTests: XCTestCase {
    private func segment(_ id: Int64, _ start: Double, _ end: Double, _ text: String) -> Segment {
        Segment(id: id, recordingId: 1, start: start, end: end, text: text)
    }

    func testParagraphsBreakOnLongPauses() {
        let paragraphs = Paragraph.group([
            segment(1, 0, 3, "Hi everyone"),
            segment(2, 3.5, 6, "thanks for joining"),
            segment(3, 9, 12, "Let's begin"),
        ])
        XCTAssertEqual(paragraphs.map(\.text), ["Hi everyone thanks for joining", "Let's begin"])
        XCTAssertEqual(paragraphs.map(\.start), [0, 9])
    }

    func testParagraphsBreakAtSentenceEndOnceLongEnough() {
        let paragraphs = Paragraph.group([
            segment(1, 0, 10, "Short sentence."),
            segment(2, 10, 20, "Not long enough yet."),
            segment(3, 20.5, 27.5, "Now it is."),
            segment(4, 28, 30, "New paragraph"),
        ])
        XCTAssertEqual(paragraphs.map(\.segments.count), [3, 1])
    }

    func testParagraphsBreakAfterAMinuteEvenMidSentence() {
        let segments = (0..<20).map { segment(Int64($0), Double($0) * 5, Double($0) * 5 + 5, "and then") }
        let paragraphs = Paragraph.group(segments)
        XCTAssertEqual(paragraphs.map(\.start), [0, 60])
    }

    func testTimestamps() {
        XCTAssertEqual(formatTimestamp(0), "0:00")
        XCTAssertEqual(formatTimestamp(65.9), "1:05")
        XCTAssertEqual(formatTimestamp(3725), "1:02:05")
        XCTAssertEqual(formatDuration(3725), "1h 2m")
        XCTAssertEqual(formatDuration(95), "1m 35s")
    }

    func testExports() throws {
        let recording = Recording(id: 1, title: "Standup", fileName: "x.mp3", duration: 70, createdAt: Date(), status: .done)
        let segments = [segment(1, 0, 2.5, "Morning all."), segment(2, 61.25, 63, "Any blockers?")]

        let text = String(decoding: try TranscriptExporter.data(for: .text, recording: recording, segments: segments), as: UTF8.self)
        XCTAssertEqual(text, "Standup\n\n[0:00]\nMorning all.\n\n[1:01]\nAny blockers?\n")

        let srt = String(decoding: try TranscriptExporter.data(for: .subtitles, recording: recording, segments: segments), as: UTF8.self)
        XCTAssertEqual(srt, "1\n00:00:00,000 --> 00:00:02,500\nMorning all.\n\n2\n00:01:01,250 --> 00:01:03,000\nAny blockers?\n")

        let markdown = String(decoding: try TranscriptExporter.data(for: .markdown, recording: recording, segments: segments), as: UTF8.self)
        XCTAssertTrue(markdown.hasPrefix("# Standup\n"))
        XCTAssertTrue(markdown.contains("**1:01**  \nAny blockers?"))

        let docx = try TranscriptExporter.data(for: .word, recording: recording, segments: segments)
        let reopened = try NSAttributedString(data: docx, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil)
        XCTAssertTrue(reopened.string.contains("Standup"))
        XCTAssertTrue(reopened.string.contains("1:01\nAny blockers?"))
    }
}
