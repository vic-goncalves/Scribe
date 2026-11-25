import Foundation
import Observation
import ArgmaxCore
import SpeakerKit
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
    /// True while the active recording is past transcription and being split into speakers.
    private(set) var isIdentifyingSpeakers = false
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
    @ObservationIgnored private var speakerKit: SpeakerKit?

    private static let currentModelKey = "modelId"
    private static let downloadedModelsKey = "downloadedModels"
    private static let legacyFolderKey = "modelFolder"
    private static let speakerModelsKey = "speakerModelFolder"

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
            await prepareSpeakerModels()
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
            await prepareSpeakerModels()
            processQueue()
        } catch {
            guard modelId == currentModelId else { return }
            phase = .failed("Couldn't load the model: \(error.localizedDescription)")
        }
    }

    /// Loads SpeakerKit from its saved local folder. The first time, its models (~33 MB) are downloaded
    /// from Hugging Face and the folder is remembered, so speaker identification never needs the network again.
    private func prepareSpeakerModels() async {
        guard speakerKit == nil else { return }
        let savedFolder = defaults.string(forKey: Self.speakerModelsKey).flatMap {
            FileManager.default.fileExists(atPath: $0) ? $0 : nil
        }
        do {
            let config = PyannoteConfig(
                downloadBase: modelsDirectory.path,
                modelFolder: savedFolder,
                download: true,
                verbose: false
            )
            let kit = try await SpeakerKit(config)
            if savedFolder == nil, let path = (kit.diarizer as? ModelManager)?.modelPath?.path {
                defaults.set(path, forKey: Self.speakerModelsKey)
            }
            speakerKit = kit
        } catch {
            print("Speaker models unavailable, transcripts won't be split by speaker: \(error)")
        }
    }

    /// Turns SpeakerKit's speaker-tagged word runs into transcript segments.
    nonisolated static func transcribedSegments(from speakerSegments: [SpeakerSegment]) -> [TranscribedSegment] {
        speakerSegments.compactMap { segment in
            guard let first = segment.speakerWords.first, let last = segment.speakerWords.last else { return nil }
            return TranscribedSegment(
                start: Double(first.wordTiming.start),
                end: Double(last.wordTiming.end),
                text: segment.speakerWords.map(\.wordTiming.word).joined(),
                speaker: segment.speaker.speakerIds.first
            )
        }
    }

    /// Renumbers raw cluster ids as 1, 2, 3... in order of first appearance. Segments the diarizer
    /// couldn't attribute inherit the previous speaker, since a gap in detection rarely means a new voice.
    nonisolated static func numberSpeakers(_ segments: [TranscribedSegment]) -> [TranscribedSegment] {
        var numbers: [Int: Int] = [:]
        var previous: Int?
        return segments.map { segment in
            var segment = segment
            if let raw = segment.speaker {
                if numbers[raw] == nil { numbers[raw] = numbers.count + 1 }
                previous = numbers[raw]
            }
            segment.speaker = previous
            return segment
        }
    }

    /// Drops Whisper's non-speech annotations (e.g. "[BLANK_AUDIO]", "(music)") and the "- " it uses to mark
    /// turn changes (speakers are tracked separately), and clamps times to the audio length.
    nonisolated static func cleanSegments(_ raw: [TranscribedSegment], duration: Double) -> [TranscribedSegment] {
        raw.sorted { $0.start < $1.start }.compactMap { segment in
            let text = segment.text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: #"^-\s*"#, with: "", options: .regularExpression)
            let isAnnotation = text.range(of: #"^(\[[^\]]*\]|\([^)]*\)|\*[^*]*\*)$"#, options: .regularExpression) != nil
            guard !text.isEmpty, !isAnnotation else { return nil }
            let end = duration > 0 ? min(segment.end, duration) : segment.end
            return TranscribedSegment(start: segment.start, end: max(end, segment.start), text: text, speaker: segment.speaker)
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
        isIdentifyingSpeakers = false
        library.setStatus(.transcribing, for: id)
        defer {
            activeRecordingId = nil
            activeCancelFlag = nil
            isIdentifyingSpeakers = false
        }

        let path = library.audioURL(for: recording).path
        do {
            let samples = try await Task.detached(priority: .userInitiated) {
                try AudioProcessor.loadAudioAsFloatArray(fromPath: path)
            }.value

            // Whisper decodes in 30s windows; VAD chunking splits on silence and decodes windows in parallel.
            // Prefill is off so the model detects the language itself: with WhisperKit's prefilled language
            // prompt, a rough opening window can decode to nothing and silently drop its speech.
            let options = DecodingOptions(
                task: .transcribe,
                temperatureFallbackCount: 3,
                usePrefillPrompt: false,
                skipSpecialTokens: true,
                wordTimestamps: true,
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

            isIdentifyingSpeakers = true
            let raw = await identifySpeakers(samples: samples, results: results)
                ?? results.flatMap(\.segments).map { TranscribedSegment(start: Double($0.start), end: Double($0.end), text: $0.text) }
            guard !flag.isCancelled else { return }
            let segments = Self.cleanSegments(raw, duration: recording.duration)
            library.saveTranscript(for: id, segments: segments, language: results.first?.language)
        } catch {
            guard !flag.isCancelled else { return }
            library.setStatus(.failed, for: id, error: error.localizedDescription)
        }
    }

    /// Returns nil when speaker models aren't available or diarization fails; the transcript is still saved without speakers.
    private func identifySpeakers(samples: [Float], results: [TranscriptionResult]) async -> [TranscribedSegment]? {
        guard let speakerKit else { return nil }
        do {
            let diarization = try await speakerKit.diarize(audioArray: samples)
            let speakerSegments = diarization.addSpeakerInfo(to: results, strategy: .subsegment).flatMap { $0 }
            let segments = Self.numberSpeakers(Self.transcribedSegments(from: speakerSegments))
            return segments.isEmpty ? nil : segments
        } catch {
            print("Speaker identification failed: \(error)")
            return nil
        }
    }
}
