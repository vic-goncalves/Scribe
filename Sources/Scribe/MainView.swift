import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @Environment(Library.self) private var library
    @Environment(Transcriber.self) private var transcriber
    @Environment(Player.self) private var player
    @Environment(AppState.self) private var appState
    @Environment(AppDelegate.self) private var appDelegate

    @State private var isDropTargeted = false

    var body: some View {
        @Bindable var appState = appState
        HStack(spacing: 0) {
            SidebarView(onImport: { appState.showImporter = true })
                .frame(width: 260)
            Rectangle()
                .fill(Theme.border)
                .frame(width: 1)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.canvas)
        }
        .ignoresSafeArea()
        .fileImporter(isPresented: $appState.showImporter, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
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
                DropOverlay()
            }
        }
        .onAppear {
            appDelegate.importHandler = { importFiles($0) }
            if appState.selection == nil { appState.selection = library.recordings.first?.id }
        }
        .sheet(isPresented: $appState.showModelPicker) {
            ModelPickerView()
        }
        .onDeleteCommand {
            appState.pendingDeletion = appState.selection
        }
        .confirmationDialog(
            "Delete “\(appState.pendingDeletion.flatMap { library.recording(id: $0)?.title } ?? "")”?",
            isPresented: Binding(get: { appState.pendingDeletion != nil }, set: { if !$0 { appState.pendingDeletion = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let id = appState.pendingDeletion { delete(id) }
            }
        } message: {
            Text("The transcript and Scribe's copy of the audio will be removed. The original file isn't affected.")
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let id = appState.selection, let recording = library.recording(id: id) {
            RecordingDetailView(recording: recording)
                .id(id)
        } else if library.recordings.isEmpty {
            EmptyLibraryView { appState.showImporter = true }
        } else {
            Text("Select a recording")
                .font(.system(size: 13))
                .foregroundStyle(Theme.tertiaryText)
        }
    }

    private func importFiles(_ urls: [URL]) {
        Task {
            let ids = await library.importFiles(urls)
            transcriber.processQueue()
            if let first = ids.first {
                appState.searchText = ""
                appState.selection = first
            }
        }
    }

    private func delete(_ id: Int64) {
        guard let recording = library.recording(id: id) else { return }
        let index = library.recordings.firstIndex { $0.id == id }
        transcriber.cancel(recordingId: id)
        if player.loadedURL == library.audioURL(for: recording) { player.unload() }
        library.delete(id)
        if appState.selection == id {
            // Keep the user in flow: select the neighbor that took the deleted row's place.
            let remaining = library.recordings
            appState.selection = index.flatMap { remaining.indices.contains($0) ? remaining[$0].id : remaining.last?.id }
        }
    }
}

private struct DropOverlay: View {
    var body: some View {
        ZStack {
            Color.brand.opacity(0.04)
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.brand.opacity(0.7), lineWidth: 2)
                .padding(6)
            Text("Drop audio to transcribe")
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.elevated).shadow(color: .black.opacity(0.12), radius: 12, y: 4))
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

private struct EmptyLibraryView: View {
    let chooseFiles: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.tertiaryText)
                .padding(.bottom, 4)
            Text("No recordings yet")
                .font(.system(size: 18, weight: .semibold))
            Text("Drop an audio file anywhere in this window, or import one.\nTranscription happens on this Mac.")
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.secondaryText)
                .lineSpacing(3)
            Button("Import audio", action: chooseFiles)
                .buttonStyle(PrimaryButtonStyle())
                .padding(.top, 8)
        }
        .padding(40)
    }
}
