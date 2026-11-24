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
    /// True from the start of a first-run download until that model has loaded, so the setup screen stays up through both.
    private(set) var isInstalling = false
    private(set) var activeRecordingId: Int64?
    private(set) var activeProgress: Double = 0
    private(set) var currentModelId: String?
    /// Model id -> folder for every fully downloaded model.
    private(set) var downloadedModels: [String: String] = [:]
    /// Progress of downloads in flight, by model id.
    private(set) var downloadProgress: [String: Double] = [:]
    private(set) var downloadErrors: [String: String] = [:]

    private let library: Library
    private let modelsDirectory: URL
    private let defaults: UserDefaults
    @ObservationIgnored private var whisper: WhisperKit?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var activeCancelFlag: CancelFlag?

    private static let currentModelKey = "modelId"
    private static let downloadedModelsKey = "downloadedModels"
    private static let legacyFolderKey = "modelFolder"

    var currentModel: ModelOption? {
        ModelOption.all.first { $0.id == currentModelId }
    }

    init(library: Library, modelsDirectory: URL = AppPaths.models, defaults: UserDefaults = AppPaths.defaults) {
        self.library = library
        self.modelsDirectory = modelsDirectory
        self.defaults = defaults

        var downloaded = defaults.dictionary(forKey: Self.downloadedModelsKey) as? [String: String] ?? [:]
        let savedId = defaults.string(forKey: Self.currentModelKey)
        if let savedId, let legacyFolder = defaults.string(forKey: Self.legacyFolderKey), downloaded[savedId] == nil {
            downloaded[savedId] = legacyFolder
        }
        downloadedModels = downloaded.filter { FileManager.default.fileExists(atPath: $0.value) }
        defaults.set(downloadedModels, forKey: Self.downloadedModelsKey)

        if let savedId, let folder = downloadedModels[savedId] {
            currentModelId = savedId
            Task { await load(folder: folder) }
        }
    }

    // MARK: Models

    /// First-run setup: download a model, then switch to it. The setup screen follows `phase` throughout.
    func install(_ option: ModelOption) async {
        isInstalling = true
        phase = .downloading(0)
        guard await download(option) else {
            phase = .failed(downloadErrors[option.id] ?? "Download failed")
            return
        }
        await use(option)
    }

    /// Downloads a model without switching to it. This is the app's only network access; the tokenizer
    /// is fetched on the model's first load and cached next to it, so later launches work offline.
    @discardableResult
    func download(_ option: ModelOption) async -> Bool {
        guard downloadProgress[option.id] == nil else { return false }
        downloadProgress[option.id] = 0
        downloadErrors[option.id] = nil
        defer { downloadProgress[option.id] = nil }
        do {
            let folder = try await WhisperKit.download(
                variant: option.id,
                downloadBase: modelsDirectory,
                progressCallback: { progress in
                    let fraction = progress.fractionCompleted
                    Task { @MainActor [weak self] in
                        guard let self, self.downloadProgress[option.id] != nil else { return }
                        self.downloadProgress[option.id] = fraction
                        if case .downloading = self.phase { self.phase = .downloading(fraction) }
                    }
                }
            )
            downloadedModels[option.id] = folder.path
            defaults.set(downloadedModels, forKey: Self.downloadedModelsKey)
            return true
        } catch {
            downloadErrors[option.id] = "Download failed: \(error.localizedDescription)"
            return false
        }
    }

    /// Switches to a downloaded model. A transcription in progress is restarted with the new model.
    func use(_ option: ModelOption) async {
        guard let folder = downloadedModels[option.id] else { return }
        if let active = activeRecordingId {
            cancelActive()
            library.requeue(active)
        }
        whisper = nil
        currentModelId = option.id
        defaults.set(option.id, forKey: Self.currentModelKey)
        await load(folder: folder)
    }

    /// Frees disk space. The model in use can't be deleted.
    func deleteModel(_ option: ModelOption) {
        guard option.id != currentModelId, let folder = downloadedModels[option.id] else { return }
        try? FileManager.default.removeItem(atPath: folder)
        downloadedModels[option.id] = nil
        defaults.set(downloadedModels, forKey: Self.downloadedModelsKey)
    }

    private func load(folder: String) async {
        phase = .loading
        let modelId = currentModelId
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
            let loaded = try await WhisperKit(config)
            // Another switch may have started while this model was loading; the newest choice wins.
            guard modelId == currentModelId else { return }
            whisper = loaded
            phase = .ready
            isInstalling = false
            processQueue()
        } catch {
            guard modelId == currentModelId else { return }
            phase = .failed("Couldn't load the model: \(error.localizedDescription)")
        }
    }

    /// Drops Whisper's non-speech annotations (e.g. "[BLANK_AUDIO]", "(music)") and clamps times to the audio length.
    nonisolated static func cleanSegments(_ raw: [(start: Double, end: Double, text: String)], duration: Double) -> [(start: Double, end: Double, text: String)] {
        raw.sorted { $0.start < $1.start }.compactMap { segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let isAnnotation = text.range(of: #"^(\[[^\]]*\]|\([^)]*\)|\*[^*]*\*)$"#, options: .regularExpression) != nil
            guard !text.isEmpty, !isAnnotation else { return nil }
            let end = duration > 0 ? min(segment.end, duration) : segment.end
            return (segment.start, max(end, segment.start), text)
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

            let segments = Self.cleanSegments(
                results.flatMap(\.segments).map { (Double($0.start), Double($0.end), $0.text) },
                duration: recording.duration
            )
            library.saveTranscript(for: id, segments: segments, language: results.first?.language)
        } catch {
            guard !flag.isCancelled else { return }
            library.setStatus(.failed, for: id, error: error.localizedDescription)
        }
    }
}
