import SwiftUI

@main
struct ScribeApp: App {
    @State private var library: Library
    @State private var transcriber: Transcriber
    @State private var player = Player()
    @State private var showImporter = false

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
            RootView(showImporter: $showImporter)
                .environment(library)
                .environment(transcriber)
                .environment(player)
                .frame(minWidth: 820, minHeight: 520)
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Import Audio…") { showImporter = true }
                    .keyboardShortcut("o")
                    .disabled(transcriber.phase == .needsSetup || transcriber.isInstalling)
            }
            CommandGroup(after: .appSettings) {
                Button("Change Speech Model…") { transcriber.resetModel() }
                    .disabled(transcriber.isInstalling)
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
    @Binding var showImporter: Bool
    @Environment(Transcriber.self) private var transcriber

    var body: some View {
        if transcriber.phase == .needsSetup || transcriber.isInstalling {
            SetupView()
        } else {
            MainView(showImporter: $showImporter)
        }
    }
}
