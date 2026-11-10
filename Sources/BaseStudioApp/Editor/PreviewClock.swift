import AVFoundation
import BaseStudioCore
import Foundation

/// The sound side of editor playback.
@MainActor
protocol PreviewAudioOutput: AnyObject {
    /// Build/refresh the audio for the current edit. false = no sound to play.
    func prepare() async -> Bool
    /// Seek to `sec` (exactly) and start playing.
    func start(at sec: Double) async
    func pause()
    func seek(to sec: Double)
    /// Where the sound is now, and where it ends (timeline seconds).
    var currentSeconds: Double { get }
    var endSeconds: Double { get }
}

/// Drives the editor playhead. With sound, the sound's clock is the only
/// clock: the picture does not move until the sound is prepared and
/// playing, and holds while the player buffers. Only when there is no
/// sound (none recorded, or it failed to build) — or past the end of the
/// sound — does a plain timer move the playhead.
@MainActor
final class PreviewClock {
    private let output: PreviewAudioOutput
    private let interval: TimeInterval
    private var timer: Timer?
    private var generation = 0
    private var followsAudio = false
    /// Without sound: wall-clock anchor, so late timer ticks don't slow
    /// playback down.
    private var silentAnchor: (wall: CFAbsoluteTime, sec: Double)?
    private(set) var isRunning = false
    private(set) var seconds: Double = 0
    private var duration: Double = 0
    /// Called on every tick with the new playhead, and once with `ended`.
    var onTick: ((_ sec: Double, _ ended: Bool) -> Void)?

    init(output: PreviewAudioOutput, interval: TimeInterval = 1.0 / 24.0) {
        self.output = output
        self.interval = interval
    }

    func play(from sec: Double, duration: Double) {
        guard !isRunning else { return }
        isRunning = true
        generation += 1
        let gen = generation
        seconds = sec
        self.duration = duration
        Task {
            let hasAudio = await output.prepare()
            guard isRunning, gen == generation else { return }
            if hasAudio, seconds < output.endSeconds {
                await output.start(at: seconds)
                guard isRunning, gen == generation else { return }
            }
            followsAudio = hasAudio
            silentAnchor = nil
            startTimer()
        }
    }

    func pause() {
        isRunning = false
        generation += 1
        timer?.invalidate()
        timer = nil
        output.pause()
    }

    func seek(to sec: Double) {
        seconds = sec
        silentAnchor = nil
        if isRunning, followsAudio { output.seek(to: sec) }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func tick() {
        guard isRunning else { return }
        if followsAudio, seconds < output.endSeconds - 0.01 {
            // Holds still while the player buffers.
            seconds = output.currentSeconds
        } else {
            let now = CFAbsoluteTimeGetCurrent()
            if let a = silentAnchor {
                seconds = a.sec + (now - a.wall)
            } else {
                silentAnchor = (now, seconds)
            }
        }
        if seconds >= duration {
            pause()
            onTick?(duration, true)
        } else {
            onTick?(seconds, false)
        }
    }
}

/// `AVPlayer` implementation for the real editor: plays the whole preview
/// item (picture via PreviewCompositor + sound), shown by PlayerLayerView.
@MainActor
final class PlayerPreviewAudio: PreviewAudioOutput {
    let player = AVPlayer()
    private let makeItem: () async -> AVPlayerItem?
    var stale = true
    private var end: Double = 0

    init(makeItem: @escaping () async -> AVPlayerItem?) { self.makeItem = makeItem }

    /// Called when the item can't play (status .failed) — the owner falls
    /// back to the per-frame preview.
    var onItemFailed: ((Error?) -> Void)?

    func prepare() async -> Bool {
        if stale {
            stale = false
            let item = await makeItem()
            player.replaceCurrentItem(with: item)
            end = (try? await item?.asset.load(.duration).seconds) ?? 0
        }
        guard let item = player.currentItem else { return false }
        // A built item can still fail to prepare (e.g. the compositor or a
        // track); wait for a verdict (bounded) instead of assuming it plays.
        for _ in 0..<100 where item.status == .unknown {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        if item.status == .failed {
            BSLog.error("preview item failed: \(String(describing: item.error))")
            player.replaceCurrentItem(with: nil)
            stale = true
            onItemFailed?(item.error)
            return false
        }
        return true
    }

    func start(at sec: Double) async {
        await player.seek(to: CMTime(seconds: sec, preferredTimescale: 48_000),
                          toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
    }

    func pause() { player.pause() }

    /// Chase seek (Apple QA1820): while a seek is in flight, remember only
    /// the newest target and go there when it finishes. Firing a seek per
    /// drag step let AVPlayer drop the last one — a drag to 80 s ended at 70 s.
    private var seekInFlight = false
    private var pendingSeek: Double?

    func seek(to sec: Double) {
        pendingSeek = sec
        guard !seekInFlight else { return }
        chase()
    }

    private func chase() {
        guard let target = pendingSeek else { seekInFlight = false; return }
        pendingSeek = nil
        seekInFlight = true
        player.seek(to: CMTime(seconds: target, preferredTimescale: 48_000),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.chase() }
        }
    }

    var currentSeconds: Double { player.currentTime().seconds }
    var endSeconds: Double { end.isFinite ? end : 0 }
}
