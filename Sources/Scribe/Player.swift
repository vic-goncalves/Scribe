import AVFoundation
import Observation

@Observable
@MainActor
final class Player {
    private(set) var currentTime: Double = 0
    private(set) var isPlaying = false
    private(set) var rate: Float = 1
    private(set) var loadedURL: URL?

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?

    static let rates: [Float] = [1, 1.25, 1.5, 2]

    func load(_ url: URL) {
        guard url != loadedURL else { return }
        unload()
        let player = AVPlayer(url: url)
        self.player = player
        loadedURL = url
        currentTime = 0
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.currentTime = time.seconds }
        }
        statusObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let playing = player.timeControlStatus != .paused
            Task { @MainActor in self?.isPlaying = playing }
        }
    }

    func unload() {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        player?.pause()
        statusObservation = nil
        timeObserver = nil
        player = nil
        loadedURL = nil
        isPlaying = false
        currentTime = 0
    }

    func togglePlay() {
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            if let item = player.currentItem, item.duration.isNumeric, currentTime >= item.duration.seconds - 0.1 {
                seek(to: 0)
            }
            player.playImmediately(atRate: rate)
        }
    }

    func seek(to seconds: Double, play: Bool = false) {
        guard let player else { return }
        let target = max(0, seconds)
        currentTime = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        if play && !isPlaying { player.playImmediately(atRate: rate) }
    }

    func skip(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    func cycleRate() {
        let index = Self.rates.firstIndex(of: rate) ?? 0
        rate = Self.rates[(index + 1) % Self.rates.count]
        if isPlaying { player?.rate = rate }
    }
}
