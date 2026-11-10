import AVFoundation
import BaseStudioCore
import Foundation

/// Which audio files a take plays, and where timeline-zero sits in each.
/// Export and the editor preview both read this, so what you hear while
/// editing is what the exported file contains.
public enum AudioPlan {

    /// System audio (inside screen.mov) and mic.m4a, each with the file-time
    /// of timeline-zero. Missing or silent-by-mode sources are left out.
    public static func sources(
        project: Project,
        bundleURL: URL,
        meta: RecordingMetadata,
        mode: ExportPipeline.AudioMode = .both
    ) async -> [AudioMixer.Source] {
        guard mode != .mute,
              let primary = project.sources.first(where: { $0.id == SourceID.screen }) ?? project.sources.first
        else { return [] }
        let primaryURL = bundleURL.appendingPathComponent(primary.relativeMediaPath)
        let originPTS = primary.firstPTS.cmTime
        let segIn = project.videoTrack.segments.first?.sourceIn.cmTime ?? originPTS

        var out: [AudioMixer.Source] = []
        let wantSystem = mode == .both || mode == .systemOnly
        let wantMic = mode == .both || mode == .micOnly
        if wantSystem, await hasAudio(primaryURL) {
            out.append(.init(url: primaryURL, originPTS: primary.fileTime(at: segIn), gain: 0.85))
        }
        let micURL = bundleURL.appendingPathComponent("mic.m4a")
        if wantMic, FileManager.default.fileExists(atPath: micURL.path) {
            // Legacy bundles (pre-`micFirstPTS`) assumed mic shared the
            // screen anchor. micOrigin may be negative (mic started after
            // segIn) — that stretch is silence.
            let micHostFirstPTS = meta.micFirstPTS?.cmTime ?? originPTS
            out.append(.init(url: micURL, originPTS: CMTimeSubtract(segIn, micHostFirstPTS), gain: 1.0))
        }
        return out
    }

    static func hasAudio(_ url: URL) async -> Bool {
        let tracks = (try? await AVURLAsset(url: url).loadTracks(withMediaType: .audio)) ?? []
        return !tracks.isEmpty
    }
}

/// Editor playback audio: the same sources as export, laid out on the
/// timeline through the same `TimeMap` (speed regions scale their range).
public enum PreviewAudio {

    public struct Built {
        public let composition: AVComposition
        public let audioMix: AVAudioMix
    }

    public static func build(sources: [AudioMixer.Source], timeMap: TimeMap) async throws -> Built? {
        let comp = AVMutableComposition()
        var params: [AVMutableAudioMixInputParameters] = []
        let ts: CMTimeScale = 48_000
        func t(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: ts) }

        for src in sources {
            let asset = AVURLAsset(url: src.url)
            guard let srcTrack = try await asset.loadTracks(withMediaType: .audio).first,
                  let track = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            let srcRange = try await srcTrack.load(.timeRange)
            let mediaStart = srcRange.start.seconds, mediaEnd = srcRange.end.seconds

            for seg in timeMap.timelineSegments() {
                let speed = seg.speed
                // File-time range this segment wants, clipped to what exists.
                let want0 = src.originPTS.seconds + seg.sourceStart
                let want1 = src.originPTS.seconds + seg.sourceEnd
                let have0 = max(want0, mediaStart), have1 = min(want1, mediaEnd)
                let at0 = seg.timelineStart + (have0 - want0) / speed
                if have1 > have0 {
                    let range = CMTimeRange(start: t(have0), end: t(have1))
                    try track.insertTimeRange(range, of: srcTrack, at: t(at0))
                    if abs(speed - 1) > 0.001 {
                        track.scaleTimeRange(CMTimeRange(start: t(at0), duration: range.duration),
                                             toDuration: t((have1 - have0) / speed))
                    }
                }
            }
            let p = AVMutableAudioMixInputParameters(track: track)
            p.setVolume(src.gain, at: .zero)
            params.append(p)
        }
        guard !params.isEmpty else { return nil }
        let mix = AVMutableAudioMix()
        mix.inputParameters = params
        return Built(composition: comp, audioMix: mix)
    }
}
