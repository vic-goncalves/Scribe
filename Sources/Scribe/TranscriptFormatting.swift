import AppKit
import Foundation

/// A run of consecutive segments shown as one block under a single timestamp.
struct Paragraph: Identifiable {
    let segments: [Segment]
    var id: Int64 { segments[0].id ?? 0 }
    var start: Double { segments[0].start }
    var end: Double { segments[segments.count - 1].end }
    var text: String { segments.map(\.text).joined(separator: " ") }

    /// Whisper segments are a few seconds long. Group them into readable paragraphs,
    /// breaking on long pauses or after a sentence once the paragraph is long enough.
    static func group(_ segments: [Segment]) -> [Paragraph] {
        var paragraphs: [Paragraph] = []
        var current: [Segment] = []
        for segment in segments {
            if let first = current.first, let last = current.last {
                let pause = segment.start - last.end
                let length = segment.start - first.start
                let endsSentence = last.text.last.map { ".?!".contains($0) } ?? false
                if pause >= 2 || length >= 60 || (length >= 25 && endsSentence) {
                    paragraphs.append(Paragraph(segments: current))
                    current = []
                }
            }
            current.append(segment)
        }
        if !current.isEmpty { paragraphs.append(Paragraph(segments: current)) }
        return paragraphs
    }
}

func formatTimestamp(_ seconds: Double, alwaysShowHours: Bool = false) -> String {
    let total = Int(max(0, seconds.isFinite ? seconds : 0))
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    if h > 0 || alwaysShowHours { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: "%d:%02d", m, s)
}

func formatDuration(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    if h > 0 { return "\(h)h \(m)m" }
    if m > 0 { return "\(m)m \(s)s" }
    return "\(s)s"
}

enum ExportFormat: String, CaseIterable, Identifiable {
    case text, markdown, word, subtitles

    var id: String { rawValue }

    var label: String {
        switch self {
        case .text: "Plain Text (.txt)"
        case .markdown: "Markdown (.md)"
        case .word: "Word Document (.docx)"
        case .subtitles: "Subtitles (.srt)"
        }
    }

    var fileExtension: String {
        switch self {
        case .text: "txt"
        case .markdown: "md"
        case .word: "docx"
        case .subtitles: "srt"
        }
    }
}

enum TranscriptExporter {
    static func plainText(title: String, paragraphs: [Paragraph]) -> String {
        let body = paragraphs.map { "[\(formatTimestamp($0.start))]\n\($0.text)" }.joined(separator: "\n\n")
        return "\(title)\n\n\(body)\n"
    }

    static func data(for format: ExportFormat, recording: Recording, segments: [Segment]) throws -> Data {
        let paragraphs = Paragraph.group(segments)
        switch format {
        case .text:
            return Data(plainText(title: recording.title, paragraphs: paragraphs).utf8)
        case .markdown:
            let body = paragraphs.map { "**\(formatTimestamp($0.start))**  \n\($0.text)" }.joined(separator: "\n\n")
            let meta = "\(recording.createdAt.formatted(date: .long, time: .shortened)) · \(formatDuration(recording.duration))"
            return Data("# \(recording.title)\n\n_\(meta)_\n\n\(body)\n".utf8)
        case .subtitles:
            let blocks = segments.enumerated().map { index, segment in
                "\(index + 1)\n\(srtTime(segment.start)) --> \(srtTime(segment.end))\n\(segment.text)"
            }
            return Data((blocks.joined(separator: "\n\n") + "\n").utf8)
        case .word:
            let document = attributedDocument(recording: recording, paragraphs: paragraphs)
            return try document.data(
                from: NSRange(location: 0, length: document.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]
            )
        }
    }

    private static func srtTime(_ seconds: Double) -> String {
        let ms = Int((seconds * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
    }

    private static func attributedDocument(recording: Recording, paragraphs: [Paragraph]) -> NSAttributedString {
        let doc = NSMutableAttributedString()
        let spacing = NSMutableParagraphStyle()
        spacing.paragraphSpacing = 10

        doc.append(NSAttributedString(string: recording.title + "\n", attributes: [
            .font: NSFont.boldSystemFont(ofSize: 20),
        ]))
        let meta = "\(recording.createdAt.formatted(date: .long, time: .shortened)) · \(formatDuration(recording.duration))\n\n"
        doc.append(NSAttributedString(string: meta, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.gray,
        ]))
        for paragraph in paragraphs {
            doc.append(NSAttributedString(string: formatTimestamp(paragraph.start) + "\n", attributes: [
                .font: NSFont.boldSystemFont(ofSize: 10),
                .foregroundColor: NSColor.gray,
            ]))
            doc.append(NSAttributedString(string: paragraph.text + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .paragraphStyle: spacing,
            ]))
        }
        return doc
    }
}
