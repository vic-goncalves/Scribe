import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct RecordingDetailView: View {
    let recording: Recording
    @Binding var seekRequest: SeekRequest?

    @Environment(Library.self) private var library
    @Environment(Transcriber.self) private var transcriber
    @Environment(Player.self) private var player
    @State private var segments: [Segment] = []
    @State private var paragraphs: [Paragraph] = []
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            PlayerBar(duration: recording.duration)
        }
        .navigationTitle(recording.title)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup {
                Button(copied ? "Copied" : "Copy Transcript", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    copyTranscript()
                }
                .help("Copy the transcript as plain text")
                Menu("Export", systemImage: "square.and.arrow.up") {
                    ForEach(ExportFormat.allCases) { format in
                        Button(format.label) { export(format) }
                    }
                }
                .help("Save the transcript as a file")
            }
        }
        .task(id: recording.id) {
            player.load(library.audioURL(for: recording))
        }
        .task(id: recording.status) {
            guard let id = recording.id else { return }
            segments = library.segments(for: id)
            paragraphs = Paragraph.group(segments)
        }
    }

    private var subtitle: String {
        var parts = [
            recording.createdAt.formatted(date: .abbreviated, time: .shortened),
            formatDuration(recording.duration),
        ]
        if let language = recording.language,
           let name = Locale.current.localizedString(forLanguageCode: language) {
            parts.append(name)
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var content: some View {
        switch recording.status {
        case .done where paragraphs.isEmpty:
            ContentUnavailableView("No Speech Detected", systemImage: "waveform.slash")
        case .done:
            TranscriptView(recordingId: recording.id ?? 0, paragraphs: paragraphs, seekRequest: $seekRequest)
        case .queued:
            ContentUnavailableView {
                Label("Waiting to Transcribe", systemImage: "clock")
            } description: {
                Text(transcriber.phase == .ready ? "This recording is next in line." : "Transcription starts once the speech model is loaded.")
            }
        case .transcribing:
            VStack(spacing: 12) {
                ProgressView(value: transcriber.activeProgress)
                    .frame(width: 260)
                Text("Transcribing… \(Int(transcriber.activeProgress * 100))%")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text("You can play the audio while you wait.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        case .failed:
            ContentUnavailableView {
                Label("Transcription Failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(recording.errorMessage ?? "Unknown error")
            } actions: {
                Button("Try Again") {
                    if let id = recording.id { library.requeue(id) }
                    transcriber.processQueue()
                }
            }
        }
    }

    private var hasTranscript: Bool { recording.status == .done && !segments.isEmpty }

    private func copyTranscript() {
        guard hasTranscript else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(TranscriptExporter.plainText(title: recording.title, paragraphs: paragraphs), forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    private func export(_ format: ExportFormat) {
        guard hasTranscript else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(recording.title).\(format.fileExtension)"
        if let type = UTType(filenameExtension: format.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try TranscriptExporter.data(for: format, recording: recording, segments: segments).write(to: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

struct TranscriptView: View {
    let recordingId: Int64
    let paragraphs: [Paragraph]
    @Binding var seekRequest: SeekRequest?

    @Environment(Player.self) private var player
    @State private var flashedSegmentId: Int64?

    var body: some View {
        let activeSegmentId = activeSegmentId(at: player.currentTime)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(paragraphs) { paragraph in
                        ParagraphRow(
                            paragraph: paragraph,
                            activeSegmentId: activeSegmentId,
                            flashedSegmentId: flashedSegmentId
                        )
                        .id(paragraph.id)
                    }
                }
                .padding(.horizontal, 36)
                .padding(.vertical, 28)
                .frame(maxWidth: 780, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: activeParagraphId(for: activeSegmentId)) { _, id in
                guard player.isPlaying, let id else { return }
                withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(id, anchor: .center) }
            }
            .task(id: seekRequest) {
                guard let request = seekRequest, request.recordingId == recordingId else { return }
                seekRequest = nil
                player.seek(to: request.time)
                let target = paragraphs.first { p in p.segments.contains { $0.id == request.segmentId } }
                try? await Task.sleep(for: .milliseconds(50))
                if let target { proxy.scrollTo(target.id, anchor: .center) }
                flashedSegmentId = request.segmentId
                try? await Task.sleep(for: .seconds(2))
                withAnimation { flashedSegmentId = nil }
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == ParagraphRow.seekScheme, let time = Double(url.host() ?? "") else {
                return .systemAction
            }
            player.seek(to: time, play: true)
            return .handled
        })
    }

    /// The segment being played: the last one starting at or before the playhead.
    private func activeSegmentId(at time: Double) -> Int64? {
        guard time > 0 else { return nil }
        var active: Segment?
        for paragraph in paragraphs {
            guard paragraph.start <= time + 0.05 else { break }
            for segment in paragraph.segments where segment.start <= time + 0.05 {
                active = segment
            }
        }
        guard let active, time <= active.end + 1.5 else { return nil }
        return active.id
    }

    private func activeParagraphId(for segmentId: Int64?) -> Int64? {
        guard let segmentId else { return nil }
        return paragraphs.first { p in p.segments.contains { $0.id == segmentId } }?.id
    }
}

private struct ParagraphRow: View {
    static let seekScheme = "scribe-seek"

    let paragraph: Paragraph
    let activeSegmentId: Int64?
    let flashedSegmentId: Int64?

    @Environment(Player.self) private var player

    var body: some View {
        let isActive = paragraph.segments.contains { $0.id == activeSegmentId }
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            Button {
                player.seek(to: paragraph.start, play: true)
            } label: {
                Text(formatTimestamp(paragraph.start))
                    .font(.callout.monospacedDigit().weight(.medium))
                    .foregroundStyle(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(width: 58, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Play from \(formatTimestamp(paragraph.start))")

            Text(attributedText)
                .font(.system(size: 15))
                .lineSpacing(6)
                .tint(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Each segment is a link to its start time, so clicking any sentence plays from there.
    private var attributedText: AttributedString {
        var result = AttributedString()
        for (index, segment) in paragraph.segments.enumerated() {
            var run = AttributedString(segment.text + (index < paragraph.segments.count - 1 ? " " : ""))
            run.link = URL(string: "\(Self.seekScheme)://\(segment.start)")
            if segment.id == flashedSegmentId {
                run.backgroundColor = .yellow.opacity(0.4)
            } else if segment.id == activeSegmentId {
                run.backgroundColor = .accentColor.opacity(0.18)
            }
            result += run
        }
        return result
    }
}

private struct PlayerBar: View {
    let duration: Double

    @Environment(Player.self) private var player
    @State private var scrubTime: Double?

    var body: some View {
        HStack(spacing: 14) {
            Button { player.skip(by: -15) } label: {
                Image(systemName: "gobackward.15")
            }
            .help("Back 15 seconds (⌘←)")

            Button { player.togglePlay() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.tint)
                    .contentTransition(.symbolEffect(.replace))
            }
            .help(player.isPlaying ? "Pause (⇧⌘P)" : "Play (⇧⌘P)")

            Button { player.skip(by: 15) } label: {
                Image(systemName: "goforward.15")
            }
            .help("Forward 15 seconds (⌘→)")

            Text(formatTimestamp(scrubTime ?? player.currentTime))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { min(scrubTime ?? player.currentTime, max(duration, 1)) },
                    set: { scrubTime = $0 }
                ),
                in: 0...max(duration, 1)
            ) { editing in
                if !editing, let scrubTime {
                    player.seek(to: scrubTime)
                    self.scrubTime = nil
                }
            }
            .controlSize(.small)

            Text(formatTimestamp(duration))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, alignment: .leading)

            Button { player.cycleRate() } label: {
                Text(player.rate == 1 ? "1×" : "\(player.rate.formatted())×")
                    .font(.callout.monospacedDigit().weight(.medium))
                    .frame(width: 38)
            }
            .help("Playback speed")
        }
        .buttonStyle(.borderless)
        .font(.title3)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
