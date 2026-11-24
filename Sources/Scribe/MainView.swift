import SwiftUI
import UniformTypeIdentifiers

/// Asks the detail view to jump to a moment in a recording (from a search result).
struct SeekRequest: Equatable {
    let recordingId: Int64
    let time: Double
    let segmentId: Int64?
    let token = UUID()
}

struct MainView: View {
    @Binding var showImporter: Bool
    @Environment(Library.self) private var library
    @Environment(Transcriber.self) private var transcriber
    @Environment(Player.self) private var player

    @State private var selection: Int64?
    @State private var searchText = ""
    @State private var seekRequest: SeekRequest?
    @State private var isDropTargeted = false

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection, searchText: searchText) { hit in
                selection = hit.segment.recordingId
                seekRequest = SeekRequest(recordingId: hit.segment.recordingId, time: hit.segment.start, segmentId: hit.segment.id)
            } onDelete: { id in
                delete(id)
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 400)
        } detail: {
            if let id = selection, let recording = library.recording(id: id) {
                RecordingDetailView(recording: recording, seekRequest: $seekRequest)
                    .id(id)
            } else if library.recordings.isEmpty {
                DropZoneView { showImporter = true }
            } else {
                ContentUnavailableView("Select a Recording", systemImage: "waveform", description: Text("Or drop more audio files anywhere in this window."))
            }
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search transcripts")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                ModelStatusView()
                Button("Import Audio", systemImage: "plus") { showImporter = true }
                    .help("Import audio files (⌘O)")
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { importFiles(urls) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let audio = urls.filter { Library.supportedExtensions.contains($0.pathExtension.lowercased()) }
            guard !audio.isEmpty else { return false }
            importFiles(audio)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.tint, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .background(.tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .onDeleteCommand {
            if let selection { delete(selection) }
        }
    }

    private func importFiles(_ urls: [URL]) {
        Task {
            let ids = await library.importFiles(urls)
            transcriber.processQueue()
            if let first = ids.first {
                searchText = ""
                selection = first
            }
        }
    }

    private func delete(_ id: Int64) {
        guard let recording = library.recording(id: id) else { return }
        transcriber.cancel(recordingId: id)
        if player.loadedURL == library.audioURL(for: recording) { player.unload() }
        if selection == id { selection = nil }
        library.delete(id)
    }
}

private struct ModelStatusView: View {
    @Environment(Transcriber.self) private var transcriber

    var body: some View {
        switch transcriber.phase {
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading model").font(.callout).foregroundStyle(.secondary)
            }
        case .failed(let message):
            Button("Model Unavailable", systemImage: "exclamationmark.triangle.fill") {
                transcriber.resetModel()
            }
            .foregroundStyle(.orange)
            .help("\(message)\nClick to set up the speech model again.")
        default:
            EmptyView()
        }
    }
}

private struct DropZoneView: View {
    let chooseFiles: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("Drop audio files here")
                .font(.title2.weight(.semibold))
            Text("MP3, M4A, WAV, FLAC and more. Files are copied into your library\nand transcribed on this Mac.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Choose Files…", action: chooseFiles)
                .controlSize(.large)
                .padding(.top, 4)
        }
        .padding(48)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}
