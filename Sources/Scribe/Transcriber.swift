import Foundation
import Observation
import WhisperKit

struct ModelOption: Identifiable, Hashable {
    let id: String
    let name: String
    let size: String
    let summary: String

    static let all: [ModelOption] = [
        ModelOption(
            id: "openai_whisper-large-v3-v20240930",
            name: "Best",
            size: "1.6 GB",
            summary: "Whisper Large v3 Turbo. Most accurate, recommended for Apple Silicon Macs."
        ),
        ModelOption(
            id: "openai_whisper-large-v3-v20240930_626MB",
            name: "Balanced",
            size: "630 MB",
            summary: "Compressed Large v3 Turbo. Nearly as accurate, less than half the size."
        ),
        ModelOption(
            id: "openai_whisper-small_216MB",
            name: "Fast",
            size: "220 MB",
            summary: "Whisper Small. Quick to download and run, noticeably less accurate."
        ),
    ]

    static let recommended = all[0]
}

/// Thread-safe flag the WhisperKit progress callback checks to stop decoding early.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

/// Manages the local Whisper model (download, load) and works through queued recordings one at a time.
@Observable
@MainActor
final class Transcriber {
    enum Phase: Equatable {
        case needsSetup
        case downloading(Double)
        case loading
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .needsSetup
    /// True from the start of a download until that model has loaded, so the setup screen stays up through both.
    private(set) var isInstalling = false
    private(set) var activeRecordingId: Int64?
    private(set) var activeProgress: Double = 0

    private let library: Library
    private let modelsDirectory: URL
    private let defaults: UserDefaults
    @ObservationIgnored private var whisper: WhisperKit?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var activeCancelFlag: CancelFlag?

    private static let savedFolderKey = "modelFolder"
    private static let savedModelKey = "modelId"

    var installedModel: ModelOption? {
        let id = defaults.string(forKey: Self.savedModelKey)
        return ModelOption.all.first { $0.id == id }
    }

    init(library: Library, modelsDirectory: URL = AppPaths.models, defaults: UserDefaults = .standard) {
        self.library = library
        self.modelsDirectory = modelsDirectory
        self.defaults = defaults
        if let folder = defaults.string(forKey: Self.savedFolderKey),
           FileManager.default.fileExists(atPath: folder) {
            Task { await load(folder: folder) }
        }
    }

    /// Downloads the model (the app's only network access) and loads it. The tokenizer is also fetched
    /// during this first load and cached next to the models, so later launches work offline.
    func install(_ option: ModelOption) async {
        isInstalling = true
        phase = .downloading(0)
        do {
            let folder = try await WhisperKit.download(
                variant: option.id,
                downloadBase: modelsDirectory,
                progressCallback: { progress in
                    let fraction = progress.fractionCompleted
                    Task { @MainActor [weak self] in
                        guard let self, case .downloading = self.phase else { return }
                        self.phase = .downloading(fraction)
                    }
                }
            )
            defaults.set(folder.path, forKey: Self.savedFolderKey)
            defaults.set(option.id, forKey: Self.savedModelKey)
            await load(folder: folder.path)
        } catch {
            phase = .failed("Download failed: \(error.localizedDescription)")
        }
    }

    func resetModel() {
        cancelActive()
        worker?.cancel()
        whisper = nil
        phase = .needsSetup
    }

    private func load(folder: String) async {
        phase = .loading
        do {
            let config = WhisperKitConfig(
                modelFolder: folder,
                tokenizerFolder: modelsDirectory,
                verbose: false,
                logLevel: .error,
                prewarm: true,
                load: true,
                download: false
            )
            whisper = try await WhisperKit(config)
            phase = .ready
            isInstalling = false
            processQueue()
        } catch {
            phase = .failed("Couldn't load the model: \(error.localizedDescription)")
        }
    }

    // MARK: Queue

    func processQueue() {
        guard worker == nil, whisper != nil else { return }
        worker = Task { [weak self] in
            while let self, !Task.isCancelled, let whisper = self.whisper, let next = self.library.nextQueued() {
                await self.transcribe(next, with: whisper)
            }
            self?.worker = nil
        }
    }

    /// Stops the in-flight transcription if it belongs to this recording (e.g. it was deleted).
    func cancel(recordingId: Int64) {
        if activeRecordingId == recordingId { cancelActive() }
    }

    private func cancelActive() {
        activeCancelFlag?.cancel()
    }

    private func transcribe(_ recording: Recording, with whisper: WhisperKit) async {
        guard let id = recording.id else { return }
        let flag = CancelFlag()
        activeCancelFlag = flag
        activeRecordingId = id
        activeProgress = 0
        library.setStatus(.transcribing, for: id)
        defer {
            activeRecordingId = nil
            activeCancelFlag = nil
        }

        let path = library.audioURL(for: recording).path
        do {
            let samples = try await Task.detached(priority: .userInitiated) {
                try AudioProcessor.loadAudioAsFloatArray(fromPath: path)
            }.value

            // Whisper decodes in 30s windows; VAD chunking splits on silence and decodes windows in parallel.
            let options = DecodingOptions(
                task: .transcribe,
                temperatureFallbackCount: 3,
                detectLanguage: true,
                skipSpecialTokens: true,
                chunkingStrategy: .vad
            )
            let results = try await whisper.transcribe(
                audioArray: samples,
                decodeOptions: options,
                callback: { [weak self] _ in
                    if flag.isCancelled { return false }
                    let fraction = whisper.progress.fractionCompleted
                    Task { @MainActor [weak self] in
                        guard let self, self.activeRecordingId == id else { return }
                        self.activeProgress = max(self.activeProgress, min(fraction, 0.99))
                    }
                    return nil
                }
            )
            guard !flag.isCancelled else { return }

            let segments = results
                .flatMap(\.segments)
                .sorted { $0.start < $1.start }
                .compactMap { segment -> (start: Double, end: Double, text: String)? in
                    let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return nil }
                    return (Double(segment.start), Double(segment.end), text)
                }
            library.saveTranscript(for: id, segments: segments, language: results.first?.language)
        } catch {
            guard !flag.isCancelled else { return }
            library.setStatus(.failed, for: id, error: error.localizedDescription)
        }
    }
}
