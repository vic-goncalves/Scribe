import SwiftUI

struct SidebarView: View {
    @Binding var selection: Int64?
    let searchText: String
    let onSelectHit: (SearchHit) -> Void
    let onDelete: (Int64) -> Void

    @Environment(Library.self) private var library
    @Environment(Transcriber.self) private var transcriber
    @State private var hits: [SearchHit] = []
    @State private var renaming: Recording?
    @State private var renameText = ""

    var body: some View {
        Group {
            if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                recordingList
            } else {
                searchResults
            }
        }
        .task(id: searchText) {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            hits = library.search(searchText)
        }
        .alert("Rename Recording", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $renameText)
            Button("Rename") {
                if let id = renaming?.id { library.rename(id, to: renameText) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var recordingList: some View {
        List(selection: $selection) {
            ForEach(library.recordings) { recording in
                RecordingRow(recording: recording, progress: progress(for: recording))
                    .tag(recording.id)
                    .contextMenu { menu(for: recording) }
            }
        }
        .overlay {
            if library.recordings.isEmpty {
                Text("No recordings yet")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var searchResults: some View {
        List {
            if hits.isEmpty {
                Text("No matches")
                    .foregroundStyle(.secondary)
            }
            ForEach(groupedHits, id: \.recordingId) { group in
                Section(group.title) {
                    ForEach(group.hits) { hit in
                        Button { onSelectHit(hit) } label: {
                            SearchHitRow(hit: hit, query: searchText)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// Groups hits by recording, ordering recordings by their best-scoring hit.
    private var groupedHits: [(recordingId: Int64, title: String, hits: [SearchHit])] {
        var order: [Int64] = []
        var byRecording: [Int64: [SearchHit]] = [:]
        for hit in hits {
            let id = hit.segment.recordingId
            if byRecording[id] == nil { order.append(id) }
            byRecording[id, default: []].append(hit)
        }
        return order.map { id in
            let group = byRecording[id]!.sorted { $0.segment.start < $1.segment.start }
            return (id, group[0].recordingTitle, group)
        }
    }

    private func progress(for recording: Recording) -> Double? {
        transcriber.activeRecordingId == recording.id ? transcriber.activeProgress : nil
    }

    @ViewBuilder
    private func menu(for recording: Recording) -> some View {
        if let id = recording.id {
            Button("Rename…") {
                renameText = recording.title
                renaming = recording
            }
            Button("Show Audio in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([library.audioURL(for: recording)])
            }
            if recording.status == .done || recording.status == .failed {
                Button("Transcribe Again") {
                    library.requeue(id)
                    transcriber.processQueue()
                }
            }
            Divider()
            Button("Delete", role: .destructive) { onDelete(id) }
        }
    }
}

private struct RecordingRow: View {
    let recording: Recording
    let progress: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(recording.title)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 5) {
                status
                Text(recording.createdAt.formatted(.dateTime.month(.abbreviated).day().year()))
                Text("·")
                Text(formatDuration(recording.duration))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var status: some View {
        switch recording.status {
        case .queued:
            Image(systemName: "clock")
                .help("Waiting to transcribe")
        case .transcribing:
            ProgressView(value: progress ?? 0)
                .progressViewStyle(.circular)
                .controlSize(.mini)
                .help("Transcribing")
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .help(recording.errorMessage ?? "Transcription failed")
        case .done:
            EmptyView()
        }
    }
}

private struct SearchHitRow: View {
    let hit: SearchHit
    let query: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(formatTimestamp(hit.segment.start))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 36, alignment: .leading)
            Text(highlighted)
                .font(.callout)
                .lineLimit(3)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    /// Bolds each query word wherever it appears verbatim (fuzzy-only matches stay unhighlighted).
    private var highlighted: AttributedString {
        var text = AttributedString(hit.segment.text)
        let words = query.split(separator: " ").map(String.init).filter { $0.count >= 2 }
        for word in words {
            var searchRange = text.startIndex..<text.endIndex
            while let range = text[searchRange].range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) {
                text[range].inlinePresentationIntent = .stronglyEmphasized
                text[range].backgroundColor = .yellow.opacity(0.35)
                searchRange = range.upperBound..<text.endIndex
            }
        }
        return text
    }
}
