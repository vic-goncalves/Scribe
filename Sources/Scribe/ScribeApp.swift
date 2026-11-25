import AppKit
import SwiftUI

/// Receives files opened from Finder ("Open With", or dropped on the Dock icon) and holds them until the main window can import them.
@Observable
final class AppDelegate: NSObject, NSApplicationDelegate {
    @ObservationIgnored var importHandler: (([URL]) -> Void)? {
        didSet { deliverPending() }
    }
    @ObservationIgnored private var pending: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        pending += urls
        deliverPending()
    }

    private func deliverPending() {
        guard let importHandler, !pending.isEmpty else { return }
        let urls = pending
        pending = []
        importHandler(urls)
    }
}

/// Asks the detail view to jump to a moment in a recording (from a search result).
struct SeekRequest: Equatable {
    let recordingId: Int64
    let time: Double
    let segmentId: Int64?
    let token = UUID()
}

/// Window-level navigation state, shared with menu commands.
@Observable
@MainActor
final class AppState {
    var selection: Int64?
    var searchText = ""
    var seekRequest: SeekRequest?
    var showImporter = false
    var showModelPicker = false
    /// Recording awaiting delete confirmation.
    var pendingDeletion: Int64?
    /// Recording whose title should take keyboard focus for renaming.
    var renameRequest: Int64?

    func selectAdjacent(_ offset: Int, in recordings: [Recording]) {
        guard !recordings.isEmpty else { return }
        guard let current = recordings.firstIndex(where: { $0.id == selection }) else {
            selection = recordings.first?.id
            return
        }
        let next = min(max(current + offset, 0), recordings.count - 1)
        selection = recordings[next].id
    }
}

@main
struct ScribeApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var library: Library
    @State private var transcriber: Transcriber
    @State private var player = Player()
    @State private var appState = AppState()
    @AppStorage(AppearanceMode.storageKey) private var appearance = AppearanceMode.system

    init() {
        let library: Library
        do {
            library = try Library()
        } catch {
            fatalError("Couldn't open the library at \(AppPaths.root.path): \(error)")
        }
        _library = State(initialValue: library)
        _transcriber = State(initialValue: Transcriber(library: library))
    }

    var body: some Scene {
        Window("Scribe", id: "main") {
            RootView()
                .environment(library)
                .environment(transcriber)
                .environment(player)
                .environment(appState)
                .environment(appDelegate)
                .tint(.brand)
                .foregroundStyle(Theme.text)
                .frame(minWidth: 860, minHeight: 560)
                .onChange(of: appearance, initial: true) { appearance.apply() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Transcript…") { appState.showImporter = true }
                    .keyboardShortcut("n")
                    .disabled(transcriber.phase == .needsSetup || transcriber.isInstalling)
            }
            CommandGroup(after: .appSettings) {
                Button("Speech Models…") { appState.showModelPicker = true }
                    .disabled(transcriber.phase == .needsSetup || transcriber.isInstalling)
            }
            CommandGroup(before: .sidebar) {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                Divider()
            }
            CommandMenu("Go") {
                Button("Previous Recording") { appState.selectAdjacent(-1, in: library.recordings) }
                    .keyboardShortcut("[")
                Button("Next Recording") { appState.selectAdjacent(1, in: library.recordings) }
                    .keyboardShortcut("]")
            }
            CommandMenu("Playback") {
                Button(player.isPlaying ? "Pause" : "Play") { player.togglePlay() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Back 15 Seconds") { player.skip(by: -15) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command])
                Button("Forward 15 Seconds") { player.skip(by: 15) }
                    .keyboardShortcut(.rightArrow, modifiers: [.command])
            }
        }
    }
}

struct RootView: View {
    @Environment(Transcriber.self) private var transcriber

    var body: some View {
        Group {
            if transcriber.phase == .needsSetup || transcriber.isInstalling {
                SetupView()
            } else {
                MainView()
            }
        }
        .background(Theme.canvas)
    }
}
