import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum TranscriptLayout {
    static let maxWidth: CGFloat = 800
    static let timestampWidth: CGFloat = 44
    static let gutter: CGFloat = 20
    /// Lines the header up with the transcript text, past the timestamp column.
    static var textInset: CGFloat { timestampWidth + gutter }
    /// Leaves room under the last paragraph for the floating player.
    static let bottomClearance: CGFloat = 40
}

struct RecordingDetailView: View {
    let recording: Recording

    @Environment(Library.self) private var library
    @Environment(Transcriber.self) private var transcriber
    @Environment(Player.self) private var player
    @Environment(AppState.self) private var appState
    @State private var segments: [Segment] = []
    @State private var paragraphs: [Paragraph] = []
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            actionBar
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            PlayerBar(duration: recording.duration)
        }
        .navigationTitle(recording.title)
        .task(id: recording.id) {
            player.load(library.audioURL(for: recording))
        }
        .task(id: recording.status) {
            guard let id = recording.id else { return }
            segments = library.segments(for: id)
            paragraphs = Paragraph.group(segments)
        }
    }

    private var actionBar: some View {
        HStack(spacing: 2) {
            Text(recording.title)
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
                .padding(.leading, 6)
            Spacer()
            Button(copied ? "Copied" : "Copy", action: copyTranscript)
            .buttonStyle(GhostButtonStyle())
            .help("Copy the transcript as plain text")
            Menu {
                ForEach(ExportFormat.allCases) { format in
                    Button(format.label) { export(format) }
                }
            } label: {
                Text("Export")
            }
            .menuStyle(.button)
            .buttonStyle(GhostButtonStyle())
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Save the transcript as a file")
        }
        .disabled(!hasTranscript)
        .padding(.horizontal, 12)
        .frame(height: 44)
    }

    private var header: RecordingHeader {
        RecordingHeader(recording: recording, wordCount: hasTranscript ? segments.reduce(0) { $0 + $1.text.split(separator: " ").count } : nil)
    }

    @ViewBuilder
    private var content: some View {
        if recording.status == .done && !paragraphs.isEmpty {
            TranscriptView(recordingId: recording.id ?? 0, paragraphs: paragraphs, header: header)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.leading, TranscriptLayout.textInset)
                statusPlaceholder
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.bottom, TranscriptLayout.bottomClearance)
            }
            .padding(.horizontal, 48)
            .padding(.top, 36)
            .frame(maxWidth: TranscriptLayout.maxWidth)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var statusPlaceholder: some View {
        switch recording.status {
        case .done:
            StatusMessage(icon: "waveform.slash", title: "No speech detected", message: "Whisper didn't find any words in this recording.")
        case .queued:
            StatusMessage(
                icon: "clock",
                title: "Waiting to transcribe",
                message: transcriber.phase == .ready ? "This recording is next in line." : "Transcription starts once the speech model is loaded."
            )
        case .transcribing:
            let progress = transcriber.activeProgress
            VStack(spacing: 12) {
                Text(progress > 0 ? "Transcribing… \(Int(progress * 100))%" : "Transcribing…")
                    .font(.system(size: 14, weight: .medium))
                    .monospacedDigit()
                ProgressBar(value: progress > 0 ? progress : nil)
                    .frame(width: 220)
                Text("You can listen while you wait.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.tertiaryText)
            }
        case .failed:
            StatusMessage(icon: "exclamationmark.triangle", title: "Transcription failed", message: recording.errorMessage ?? "Unknown error") {
                Button("Try again") {
                    if let id = recording.id { library.requeue(id) }
                    transcriber.processQueue()
                }
                .buttonStyle(PrimaryButtonStyle())
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

private struct StatusMessage<Actions: View>: View {
    let icon: String
    let title: String
    let message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Theme.tertiaryText)
                .padding(.bottom, 2)
            Text(title)
                .font(.system(size: 14, weight: .medium))
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
            actions
                .padding(.top, 6)
        }
        .frame(maxWidth: 360)
    }
}

extension StatusMessage where Actions == EmptyView {
    init(icon: String, title: String, message: String) {
        self.init(icon: icon, title: title, message: message) { EmptyView() }
    }
}

struct RecordingHeader: View {
    let recording: Recording
    let wordCount: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(recording.title)
                .font(Theme.titleFont)
                .textSelection(.enabled)
            Text(metadata)
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)
            Rectangle()
                .fill(Theme.border)
                .frame(height: 1)
                .padding(.top, 14)
        }
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var metadata: String {
        var parts = [recording.createdAt.formatted(date: .abbreviated, time: .shortened), formatDuration(recording.duration)]
        if let language = recording.language, let name = Locale.current.localizedString(forLanguageCode: language) {
            parts.append(name)
        }
        if let wordCount {
            parts.append("\(wordCount.formatted()) words")
        }
        return parts.joined(separator: "  ·  ")
    }
}

struct TranscriptView<Header: View>: View {
    let recordingId: Int64
    let paragraphs: [Paragraph]
    let header: Header

    @Environment(Player.self) private var player
    @Environment(AppState.self) private var appState
    @State private var flashedSegmentId: Int64?

    var body: some View {
        let activeSegmentId = activeSegmentId(at: player.currentTime)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    header
                        .padding(.leading, TranscriptLayout.textInset)
                    ForEach(paragraphs) { paragraph in
                        ParagraphRow(
                            paragraph: paragraph,
                            activeSegmentId: activeSegmentId,
                            flashedSegmentId: flashedSegmentId
                        )
                        .id(paragraph.id)
                    }
                }
                .padding(.horizontal, 48)
                .padding(.top, 36)
                .padding(.bottom, TranscriptLayout.bottomClearance)
                .frame(maxWidth: TranscriptLayout.maxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: activeParagraphId(for: activeSegmentId)) { _, id in
                guard player.isPlaying, let id else { return }
                withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(id, anchor: .center) }
            }
            .task(id: appState.seekRequest) {
                guard let request = appState.seekRequest, request.recordingId == recordingId else { return }
                appState.seekRequest = nil
                player.seek(to: request.time)
                let target = paragraphs.first { p in p.segments.contains { $0.id == request.segmentId } }
                try? await Task.sleep(for: .milliseconds(50))
                if let target { withAnimation { proxy.scrollTo(target.id, anchor: .center) } }
                flashedSegmentId = request.segmentId
                try? await Task.sleep(for: .seconds(2.5))
                withAnimation { flashedSegmentId = nil }
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == paragraphSeekScheme, let time = Double(url.host() ?? "") else {
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

private let paragraphSeekScheme = "scribe-seek"

private struct ParagraphRow: View {
    let paragraph: Paragraph
    let activeSegmentId: Int64?
    let flashedSegmentId: Int64?

    @Environment(Player.self) private var player
    @State private var isHovered = false

    var body: some View {
        let isActive = paragraph.segments.contains { $0.id == activeSegmentId }
        HStack(alignment: .firstTextBaseline, spacing: TranscriptLayout.gutter) {
            Button {
                player.seek(to: paragraph.start, play: true)
            } label: {
                Text(formatTimestamp(paragraph.start))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(isActive || isHovered ? Color.brand : Theme.tertiaryText)
                    .frame(width: TranscriptLayout.timestampWidth, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Play from \(formatTimestamp(paragraph.start))")

            Text(attributedText)
                .font(Theme.bodyFont)
                .lineSpacing(6)
                .tint(Theme.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onHover { isHovered = $0 }
    }

    /// Each segment is a link to its start time, so clicking any sentence plays from there.
    private var attributedText: AttributedString {
        var result = AttributedString()
        for (index, segment) in paragraph.segments.enumerated() {
            var run = AttributedString(segment.text + (index < paragraph.segments.count - 1 ? " " : ""))
            run.link = URL(string: "\(paragraphSeekScheme)://\(segment.start)")
            if segment.id == flashedSegmentId {
                run.backgroundColor = Theme.highlight
            } else if segment.id == activeSegmentId {
                run.backgroundColor = Theme.activeSegment
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
            HStack(spacing: 6) {
                iconButton("gobackward.15", help: "Back 15 seconds (⌘←)") { player.skip(by: -15) }
                Button { player.togglePlay() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.canvas)
                        .offset(x: player.isPlaying ? 0 : 1)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Theme.text))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .help(player.isPlaying ? "Pause (⇧⌘P)" : "Play (⇧⌘P)")
                iconButton("goforward.15", help: "Forward 15 seconds (⌘→)") { player.skip(by: 15) }
            }

            Text(formatTimestamp(scrubTime ?? player.currentTime))
                .frame(minWidth: 36, alignment: .trailing)
            Scrubber(time: player.currentTime, duration: duration, scrubTime: $scrubTime) { player.seek(to: $0) }
            Text(formatTimestamp(duration))
                .frame(minWidth: 36, alignment: .leading)

            Button { player.cycleRate() } label: {
                Text(player.rate == 1 ? "1×" : "\(player.rate.formatted())×")
                    .frame(minWidth: 26)
            }
            .buttonStyle(GhostButtonStyle())
            .help("Playback speed")
        }
        .font(.system(size: 12).monospacedDigit())
        .foregroundStyle(Theme.secondaryText)
        .padding(.horizontal, 20)
        .frame(height: 54)
        .background(Theme.canvas)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct Scrubber: View {
    let time: Double
    let duration: Double
    @Binding var scrubTime: Double?
    let seek: (Double) -> Void

    @State private var isHovered = false

    var body: some View {
        GeometryReader { geo in
            let fraction = duration > 0 ? min(max((scrubTime ?? time) / duration, 0), 1) : 0
            let showKnob = isHovered || scrubTime != nil
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track).frame(height: 3)
                Capsule().fill(Theme.secondaryText).frame(width: geo.size.width * fraction, height: 3)
                Circle()
                    .fill(Theme.text)
                    .frame(width: 11, height: 11)
                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                    .offset(x: geo.size.width * fraction - 6)
                    .opacity(showKnob ? 1 : 0)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        scrubTime = min(max(value.location.x / geo.size.width, 0), 1) * duration
                    }
                    .onEnded { _ in
                        if let scrubTime { seek(scrubTime) }
                        scrubTime = nil
                    }
            )
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: showKnob)
        }
        .frame(height: 22)
    }
}
