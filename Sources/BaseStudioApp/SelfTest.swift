import AVFoundation
import AppKit
import BaseStudioCore
import BaseStudioRecording
import BaseStudioRender
import Foundation

/// In-app E2E harness (小o's local signed-app gate). Launched with
/// `--selftest-record`, the *signed* app drives the REAL recording stack
/// itself — record → stop → reopen → export, twice — inside a genuine
/// window-server + GPU session, then writes a machine-readable JSON report and
/// exits. This is the gate that catches `-12785`-class corruption that a
/// headless CI (no ScreenCaptureKit permission / no HW encoder session) can't.
///
/// Report path: `--selftest-out <path>` or /tmp/base-studio-selftest.json.
/// Exits 0 if every check passed, 1 otherwise.
@available(macOS 13.0, *)
enum SelfTest {

    static var isRequested: Bool {
        CommandLine.arguments.contains("--selftest-record")
    }

    private static var reportPath: String {
        if let i = CommandLine.arguments.firstIndex(of: "--selftest-out"),
           i + 1 < CommandLine.arguments.count {
            return CommandLine.arguments[i + 1]
        }
        return "/tmp/base-studio-selftest.json"
    }

    /// `--selftest-seconds N` (default 4). Long takes + the test-only
    /// BS_INJECT_SCREEN_FAIL_AT_FRAMES env exercise mid-recording encoder recovery.
    /// `--selftest-rounds N` (default 2): consecutive record → stop → reopen.
    private static var rounds: Int {
        if let i = CommandLine.arguments.firstIndex(of: "--selftest-rounds"),
           i + 1 < CommandLine.arguments.count, let v = Int(CommandLine.arguments[i + 1]) {
            return max(1, v)
        }
        return 2
    }

    /// `--selftest-sync-markers`: every 3 s flash a small white square in the
    /// top-left corner and play a short tick through a *separate* process
    /// (our own audio is excluded from capture). Each export then carries
    /// matching picture/sound events whose offset is the A/V sync error.
    @MainActor
    final class SyncMarkers {
        private var window: NSWindow?
        private var timer: Timer?
        func start() {
            let screen = NSScreen.main?.frame ?? .zero
            let w = NSWindow(contentRect: NSRect(x: screen.minX, y: screen.maxY - 160, width: 160, height: 160),
                             styleMask: .borderless, backing: .buffered, defer: false)
            w.level = .screenSaver
            w.backgroundColor = .black
            w.ignoresMouseEvents = true
            // Say what this is, in place: people closed the app thinking a
            // bare black square was a bug. The flash region (top 100 pt) stays
            // plain so the luma measurement is unaffected.
            let label = NSTextField(labelWithString: "Base Studio\n同步测试 Sync test\n约 20 分钟 · 请勿关闭")
            label.textColor = .white
            label.font = .systemFont(ofSize: 12, weight: .semibold)
            label.alignment = .center
            label.maximumNumberOfLines = 3
            label.frame = NSRect(x: 4, y: 4, width: 152, height: 52)
            w.contentView?.addSubview(label)
            w.orderFrontRegardless()
            window = w
            timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.flash() }
            }
        }
        private func flash() {
            window?.backgroundColor = .white
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            p.arguments = ["-v", "0.15", "/System/Library/Sounds/Tink.aiff"]
            try? p.run()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.window?.backgroundColor = .black
            }
        }
        func stop() { timer?.invalidate(); window?.orderOut(nil); window = nil }
    }

    /// `--selftest-pause A B`: pause A s into the take for B s. Checks that
    /// nothing was written while paused and the export is B s shorter.
    private static var pausePlan: (at: Double, length: Double)? {
        guard let i = CommandLine.arguments.firstIndex(of: "--selftest-pause"),
              i + 2 < CommandLine.arguments.count,
              let a = Double(CommandLine.arguments[i + 1]), let b = Double(CommandLine.arguments[i + 2])
        else { return nil }
        return (a, b)
    }

    /// `--selftest-pause-stop A`: pause A s in and Stop while still paused.
    /// Checks nothing after A was written (screen frames, audio) on the way out.
    private static var pauseStopAt: Double? {
        guard let i = CommandLine.arguments.firstIndex(of: "--selftest-pause-stop"),
              i + 1 < CommandLine.arguments.count else { return nil }
        return Double(CommandLine.arguments[i + 1])
    }

    /// `--selftest-cursor-tour`: during the take, move the pointer to the
    /// screen's four corners and centre (CGWarpMouseCursorPosition, no
    /// permission needed), 1 s each from second 1. After the take: the
    /// recorded cursor positions there must match the targets, and frames of
    /// the export at those moments are saved for a visual check.
    private static var cursorTour: Bool { CommandLine.arguments.contains("--selftest-cursor-tour") }

    /// Targets in global top-left points (CG space), inset from the edges.
    @MainActor
    static func cursorTargets() -> [CGPoint] {
        let f = CGDisplayBounds(CGMainDisplayID())
        let i: CGFloat = 40
        return [CGPoint(x: f.minX + i, y: f.minY + i), CGPoint(x: f.maxX - i, y: f.minY + i),
                CGPoint(x: f.maxX - i, y: f.maxY - i), CGPoint(x: f.minX + i, y: f.maxY - i),
                CGPoint(x: f.midX, y: f.midY)]
    }

    private static var recordSeconds: Double {
        if let i = CommandLine.arguments.firstIndex(of: "--selftest-seconds"),
           i + 1 < CommandLine.arguments.count, let v = Double(CommandLine.arguments[i + 1]) {
            return max(1, v)
        }
        return 4
    }

    static func runIfRequested() {
        guard isRequested else { return }
        Task { @MainActor in
            var report = Report()
            do {
                try await run(into: &report)
            } catch {
                report.error = "\(error)"
                report.pass = false
            }
            write(report)
            NSApp.terminate(nil)
            // terminate() may be deferred; force-exit so the launcher gets the code.
            exit(report.pass ? 0 : 1)
        }
    }

    @MainActor
    private static func run(into report: inout Report) async throws {
        if CommandLine.arguments.contains("--selftest-fragment-probe-realtime") {
            if CommandLine.arguments.contains("--selftest-video-gap") {
                // 60 s of a frame per second, then 50 s with no pictures while
                // audio continues, then one frame at 110 s that triggers the
                // abandon — the shape of the 10/31 take's segment 2.
                var r: [String: String] = [:]
                for hb in [false, true] {
                    r[hb ? "gap+heartbeat" : "gap"] = await realtimeFragmentProbe(seconds: 110, gap: 60..<110, heartbeat: hb)
                }
                report.fragmentProbe = r
                report.pass = r["gap+heartbeat"]?.hasPrefix("ok") == true
                return
            }
            let r = await realtimeFragmentProbe(seconds: 120)
            report.fragmentProbe = ["realtime120": r]
            report.pass = r.hasPrefix("ok")
            return
        }
        if CommandLine.arguments.contains("--selftest-fragment-probe") {
            var r: [String: String] = [:]
            for capped in [true, false] {
                for audio in [false, true] {
                    for release in [false, true] {
                        let key = "\(capped ? "timeCapped" : "frameCountOnly")\(audio ? "+audio" : "")\(release ? "+released" : "")"
                        r[key] = await fragmentProbe(timeCapped: capped, withAudio: audio, releaseWriter: release)
                    }
                }
            }
            report.fragmentProbe = r
            report.pass = r.filter { $0.key.hasPrefix("timeCapped") }.allSatisfy { $0.value.hasPrefix("ok") }
            return
        }
        if CommandLine.arguments.contains("--selftest-synthetic-writer") {
            report.syntheticWriter = await syntheticWriterProbe()
            report.pass = report.syntheticWriter?.hasPrefix("ok") == true
            return
        }
        let dir = try recordingsDir()
        var lastBundle: ProjectBundle?

        // Let the window server / GPU settle after launch, and hide our own
        // live-rendering window so screen capture doesn't fight the SwiftUI
        // Metal surface for the encoder — recording our own actively-drawing
        // window the instant we launch reliably malfunctions the H.264 session
        // (-16122 / -12785 on frame 1). The manual flow hides the window + runs
        // a 3s countdown for the same reason.
        try await Task.sleep(nanoseconds: 2_500_000_000)
        for w in NSApp.windows where !(w is NSPanel) { w.orderOut(nil) }
        try await Task.sleep(nanoseconds: 500_000_000)

        // Two rounds: stop → record again → stop must still yield 3 good tracks
        // (webcam must not vanish on the second run).
        // Diagnostic: --selftest-no-webcam isolates the screen encoder from the
        // concurrent webcam H.264 session (to tell a concurrent-encoder startup
        // race apart from a resolution / machine-state issue).
        let withWebcam = !CommandLine.arguments.contains("--selftest-no-webcam")
        let markers = CommandLine.arguments.contains("--selftest-sync-markers") ? SyncMarkers() : nil
        markers?.start()
        defer { markers?.stop() }
        let exportEach = CommandLine.arguments.contains("--selftest-export-each")
        let runID: String = {
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd-HHmmss"
            f.timeZone = TimeZone(identifier: "UTC")
            return f.string(from: Date())
        }()
        for i in 1...rounds {
            var r = RunResult(index: i)
            let session = RecordingSession(options: .init(
                includeWebcam: withWebcam, includeSystemAudio: true, includeMic: withWebcam,
                capturesOwnWindows: markers != nil
            ))
            // New bundle every run, named by run time; earlier takes are kept
            // (never removed — one was the only copy of a 330 s take).
            let bundle = try await session.start(in: dir, name: "selftest-\(runID)-\(i)")
            r.bundlePath = bundle.url.path
            // --selftest-camera-bubble: show the self-view like a real take,
            // to check it stays out of screen.mov.
            let bubble = CameraBubble()
            if CommandLine.arguments.contains("--selftest-camera-bubble"), let cam = session.webcamCaptureSession {
                bubble.show(session: cam)
            }
            var tourTimes: [CMTime] = []
            if cursorTour {
                // Runs alongside the take; positions held 1 s each.
                let targets = Self.cursorTargets()
                try await Task.sleep(nanoseconds: 1_000_000_000)
                for p in targets {
                    CGWarpMouseCursorPosition(p)
                    try await Task.sleep(nanoseconds: 500_000_000)
                    tourTimes.append(HostClock.now())          // mid-hold sample time
                    try await Task.sleep(nanoseconds: 500_000_000)
                }
                let left = recordSeconds - 1 - Double(targets.count)
                if left > 0 { try await Task.sleep(nanoseconds: UInt64(left * 1_000_000_000)) }
            } else if let at = pauseStopAt, at < recordSeconds {
                try await Task.sleep(nanoseconds: UInt64(at * 1_000_000_000))
                session.pause()
                try await Task.sleep(nanoseconds: UInt64((recordSeconds - at) * 1_000_000_000))
            } else if let plan = pausePlan, plan.at + plan.length < recordSeconds {
                try await Task.sleep(nanoseconds: UInt64(plan.at * 1_000_000_000))
                session.pause()
                try await Task.sleep(nanoseconds: UInt64(plan.length * 1_000_000_000))
                session.resume()
                try await Task.sleep(nanoseconds: UInt64((recordSeconds - plan.at - plan.length) * 1_000_000_000))
            } else {
                try await Task.sleep(nanoseconds: UInt64(recordSeconds * 1_000_000_000))
            }
            bubble.hide()
            _ = try await session.stop()
            lastBundle = bundle

            let fm = FileManager.default
            r.failureJson = fm.fileExists(atPath: bundle.failureURL.path)
            r.metadata = fm.fileExists(atPath: bundle.metadataURL.path)

            // screen.mov must be a real decodable movie (moov present).
            let asset = AVURLAsset(url: bundle.screenURL)
            let vids = (try? await asset.loadTracks(withMediaType: .video)) ?? []
            r.screenTrack = !vids.isEmpty
            r.screenDurationSec = (try? await asset.load(.duration).seconds) ?? 0
            if let t = vids.first {
                let sz = (try? await t.load(.naturalSize)) ?? .zero
                r.screenDims = "\(Int(sz.width))x\(Int(sz.height))"
            }
            // Webcam + mic tracks present AND with real duration (not just an
            // empty header). Fully async — NO DispatchSemaphore on the main
            // actor (that deadlocks the instant a real recording succeeds and
            // reaches this check, so the report would never come out).
            r.webcamTrack = await trackPlayable(bundle.url.appendingPathComponent("webcam.mov"), .video)
            r.micTrack = await trackPlayable(bundle.url.appendingPathComponent("mic.m4a"), .audio)

            // Reopen through the real editor loader.
            do {
                _ = try EditorState.load(bundleURL: bundle.url)
                r.openOk = true
            } catch {
                r.openOk = false
                r.openError = "\(error)"
            }
            // The screen must cover (almost) the whole take — a recovered
            // encoder failure may cost < 1 s, never the rest of the take.
            r.recordSeconds = recordSeconds
            // Stopped while paused: screen.mov ends at the pause start. A
            // resumed pause leaves the raw file at the full take length (gap
            // inside), so the full length is still expected then.
            let rawExpected = pauseStopAt.map { min($0, recordSeconds) } ?? recordSeconds
            r.pass = !r.failureJson && r.metadata && r.screenTrack
                && r.screenDurationSec > max(1.0, rawExpected - 1.5)
                && r.screenDurationSec < rawExpected + 3   // too long is a bug too (60 s take → 119 s)
                && r.openOk
                && (!withWebcam || (r.webcamTrack && r.micTrack))
            if exportEach {
                do {
                    let editor = try EditorState.load(bundleURL: bundle.url)
                    let out = bundle.url.appendingPathComponent("selftest-export.mp4")
                    let url = try await ExportPipeline().run(.init(
                        project: editor.project, bundleURL: bundle.url,
                        outputURL: out, fps: 60, bitrate: 8_000_000, audioMode: .both
                    ))
                    r.exportSec = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
                } catch {
                    r.exportError = "\(error)"
                }
                let expected = pauseStopAt ?? (recordSeconds - (pausePlan?.length ?? 0))
                r.pass = r.pass && r.exportSec > max(1.0, expected - 1.5) && r.exportSec < expected + 3
            }
            if cursorTour {
                // Recorded cursor (bottom-left points, as stored) vs target.
                let meta = try? JSONDecoder().decode(RecordingMetadata.self, from: Data(contentsOf: bundle.metadataURL))
                let targets = Self.cursorTargets()
                let mainH = CGDisplayBounds(CGMainDisplayID()).height
                var worst = 0.0
                if let data = try? Data(contentsOf: bundle.cursorURL),
                   let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let samples = raw["samples"] as? [[String: Any]], let meta {
                    let pts: [(Double, Double, Double)] = samples.compactMap {
                        guard let t = $0["t"] as? [String: Any], let v = t["value"] as? NSNumber,
                              let ts = t["timescale"] as? NSNumber, let x = $0["x"] as? Double, let y = $0["y"] as? Double
                        else { return nil }
                        return (v.doubleValue / ts.doubleValue, x, y)
                    }
                    for (target, at) in zip(targets, tourTimes) {
                        guard let s = pts.min(by: { abs($0.0 - at.seconds) < abs($1.0 - at.seconds) }) else { worst = .infinity; continue }
                        let d = hypot(s.1 - Double(target.x), s.2 - Double(mainH - target.y))
                        worst = max(worst, d)
                        r.cursorTour.append(String(format: "target (%.0f,%.0f) recorded (%.0f,%.0f) @%.2fs",
                            target.x, mainH - target.y, s.1, s.2, at.seconds - meta.firstVideoPTS.cmTime.seconds))
                    }
                } else { worst = .infinity }
                r.cursorWorstPt = worst
                r.pass = r.pass && worst < 3 && tourTimes.count == targets.count
                // Export frames at each hold, for the visual check.
                if let meta, FileManager.default.fileExists(atPath: bundle.url.appendingPathComponent("selftest-export.mp4").path) {
                    let gen = AVAssetImageGenerator(asset: AVURLAsset(url: bundle.url.appendingPathComponent("selftest-export.mp4")))
                    gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
                    for (k, at) in tourTimes.enumerated() {
                        let t = CMTime(seconds: at.seconds - meta.firstVideoPTS.cmTime.seconds, preferredTimescale: 600)
                        if let cg = try? await gen.image(at: t).image,
                           let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
                            try? png.write(to: bundle.url.appendingPathComponent("cursor-tour-\(k + 1).png"))
                        }
                    }
                }
            }
            if pauseStopAt != nil || pausePlan != nil {
                // Nothing from the pause may be in ANY file: screen picture,
                // system audio, webcam, mic, cursor. Stopped while paused =
                // the pause runs to the end of the take.
                let meta = try? JSONDecoder().decode(RecordingMetadata.self, from: Data(contentsOf: bundle.metadataURL))
                r.pauses = meta?.pauses?.count ?? 0
                if let meta, let p = meta.pauses?.first {
                    let end = pauseStopAt != nil ? CMTime(seconds: 1e6, preferredTimescale: 1) : p.end.cmTime
                    r.samplesInPause = await Self.samplesInPause(bundle: bundle, meta: meta,
                                                                  start: p.start.cmTime, end: end)
                }
                // Reopened project carries the cut.
                r.projectCuts = (try? EditorState.load(bundleURL: bundle.url).project.cuts.count) ?? -1
                r.silenceFailures = SilentAudio.failures
                // Timeline kept: each audio file ends where the picture ends
                // (dropped paused audio made mic.m4a 10 s short).
                if let meta {
                    let s0 = meta.firstVideoPTS.cmTime.seconds
                    let micURL = bundle.url.appendingPathComponent("mic.m4a")
                    if let m0 = meta.micFirstPTS?.cmTime.seconds,
                       let d = try? await AVURLAsset(url: micURL).load(.duration).seconds {
                        r.audioEndVsPicture["mic"] = (m0 - s0 + d) - r.screenDurationSec
                    }
                    if let t = try? await AVURLAsset(url: bundle.screenURL).loadTracks(withMediaType: .audio).first,
                       let tr = try? await t.load(.timeRange) {
                        r.audioEndVsPicture["systemAudio"] = tr.end.seconds - r.screenDurationSec
                    }
                }
                r.framesInPause = r.samplesInPause["screen"] ?? -1
                // Every track that was recorded must be present, readable
                // and empty inside the pause; missing/unreadable (-1) fails.
                var expected: Set<String> = ["screen", "systemAudio", "cursor"]
                if withWebcam { expected.formUnion(["webcam", "mic"]) }
                r.pass = r.pass && r.pauses == 1 && r.projectCuts == 1 && r.silenceFailures == 0
                    // Stopped while paused, the picture ends at the pause but
                    // the mic keeps writing silence until Stop — only a
                    // resumed pause can be compared end to end.
                    && (pauseStopAt != nil || r.audioEndVsPicture.values.allSatisfy { abs($0) < 1.0 })
                    && expected.isSubset(of: Set(r.samplesInPause.keys))
                    && r.samplesInPause.values.allSatisfy { $0 == 0 }
            }
            report.runs.append(r)
        }

        // Export the last good bundle through the real pipeline.
        if let bundle = lastBundle {
            do {
                let editor = try EditorState.load(bundleURL: bundle.url)
                let out = bundle.url.appendingPathComponent("selftest-export.mp4")
                let pipeline = ExportPipeline()
                let url = try await pipeline.run(.init(
                    project: editor.project, bundleURL: bundle.url,
                    outputURL: out, fps: 60, bitrate: 8_000_000, audioMode: .both
                ))
                let asset = AVURLAsset(url: url)
                let vids = (try? await asset.loadTracks(withMediaType: .video)) ?? []
                report.exportDurationSec = (try? await asset.load(.duration).seconds) ?? 0
                report.exportOk = !vids.isEmpty
                    && FileManager.default.fileExists(atPath: url.path)
                    && report.exportDurationSec > 0.5
            } catch {
                report.exportOk = false
                report.exportError = "\(error)"
            }
        }

        report.pass = report.runs.allSatisfy { $0.pass } && report.exportOk
    }

    private static func trackPlayable(_ url: URL, _ type: AVMediaType) async -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let asset = AVURLAsset(url: url)
        let tracks = (try? await asset.loadTracks(withMediaType: type)) ?? []
        guard !tracks.isEmpty else { return false }
        let dur = (try? await asset.load(.duration).seconds) ?? 0
        return dur > 1.0
    }

    /// Samples of every track that overlap the pause [start, end) (host
    /// time, 30 ms margin at each edge for frame/buffer granularity).
    /// -1 = the track could not be read; a missing expected track is not a
    /// pass. Keys: screen, systemAudio, webcam (if recorded), mic (if
    /// recorded), cursor.
    static func samplesInPause(bundle: ProjectBundle, meta: RecordingMetadata,
                               start: CMTime, end: CMTime) async -> [String: Int] {
        let a = start.seconds + 0.03, b = end.seconds - 0.03
        var out: [String: Int] = [:]
        let screen0 = meta.firstVideoPTS.cmTime.seconds
        out["screen"] = await count(bundle.screenURL, .video, a - screen0, b - screen0)
        // Audio keeps its timeline through a pause as silence (SilentAudio),
        // so for audio "nothing recorded" = no sound above silence there.
        out["systemAudio"] = await loudSamples(bundle.screenURL, a - screen0, b - screen0)
        if let w0 = meta.sources?[SourceID.webcam]?.firstVideoPTS.cmTime.seconds {
            out["webcam"] = await count(bundle.url.appendingPathComponent("webcam.mov"), .video, a - w0, b - w0)
        }
        if let m0 = meta.micFirstPTS?.cmTime.seconds {
            out["mic"] = await loudSamples(bundle.url.appendingPathComponent("mic.m4a"), a - m0, b - m0)
        }
        out["cursor"] = -1
        if let data = try? Data(contentsOf: bundle.cursorURL),
           let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let samples = raw["samples"] as? [[String: Any]] {
            func t(_ e: [String: Any]) -> Double? {
                guard let tt = e["t"] as? [String: Any], let v = tt["value"] as? NSNumber,
                      let ts = tt["timescale"] as? NSNumber, ts.doubleValue > 0 else { return nil }
                return v.doubleValue / ts.doubleValue
            }
            let all = samples + (raw["clicks"] as? [[String: Any]] ?? [])
            let times = all.map(t)
            out["cursor"] = times.contains(where: { $0 == nil }) ? -1 : times.compactMap { $0 }.filter { $0 > a && $0 < b }.count
        }
        return out
    }

    /// Decoded audio samples louder than silence (|x| > 0.001) in (a, b)
    /// file seconds; -1 if the track is missing or can't be read.
    static func loudSamples(_ url: URL, _ a: Double, _ b: Double) async -> Int {
        let asset = AVURLAsset(url: url)
        guard b > a, let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return -1 }
        reader.timeRange = CMTimeRange(start: CMTime(seconds: max(0, a), preferredTimescale: 48_000),
                                       end: CMTime(seconds: b, preferredTimescale: 48_000))
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false])
        reader.add(out)
        guard reader.startReading() else { return -1 }
        var loud = 0
        while let sb = out.copyNextSampleBuffer(), let bb = CMSampleBufferGetDataBuffer(sb) {
            let len = CMBlockBufferGetDataLength(bb)
            var f = [Float](repeating: 0, count: len / 4)
            CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: &f)
            loud += f.reduce(0) { $0 + (abs($1) > 0.001 ? 1 : 0) }
        }
        return reader.status == .completed ? loud : -1
    }

    /// Samples of the first `type` track overlapping (a, b) file seconds,
    /// sample by sample (one timing entry may cover a whole buffer).
    /// -1 if the track is missing or can't be read.
    static func count(_ url: URL, _ type: AVMediaType, _ a: Double, _ b: Double) async -> Int {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: type).first,
              let reader = try? AVAssetReader(asset: asset) else { return -1 }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(out)
        guard reader.startReading() else { return -1 }
        var n = 0
        while let sb = out.copyNextSampleBuffer() {
            let samples = CMSampleBufferGetNumSamples(sb)
            for i in 0..<samples {
                var ti = CMSampleTimingInfo()
                guard CMSampleBufferGetSampleTimingInfo(sb, at: i, timingInfoOut: &ti) == noErr else { return -1 }
                let t0 = ti.presentationTimeStamp.seconds
                // Video: a frame's stored duration runs to the next frame, so
                // the last frame before a pause "lasts" across it — judge
                // pictures by capture time. Audio: by its whole span.
                let t1 = type == .video ? t0 : t0 + (ti.duration.isValid ? ti.duration.seconds : 0)
                if type == .video ? (t0 > a && t0 < b) : (t1 > a && t0 < b) { n += 1 }
            }
        }
        return reader.status == .completed ? n : -1
    }

    /// Video samples of `url` (file time) between a and b seconds.
    static func framesBetween(_ url: URL, _ a: Double, _ b: Double) async -> Int {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let reader = try? AVAssetReader(asset: asset) else { return -1 }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(out)
        reader.startReading()
        var n = 0
        while let sb = out.copyNextSampleBuffer() {
            let t = CMSampleBufferGetPresentationTimeStamp(sb).seconds
            if t > a && t < b && CMSampleBufferGetNumSamples(sb) > 0 { n += 1 }
        }
        return n
    }

    private static func recordingsDir() throws -> URL {
        let fm = FileManager.default
        let base = try fm.url(for: .moviesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("BaseStudio/SelfTest", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static func write(_ report: Report) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(report) {
            try? data.write(to: URL(fileURLWithPath: reportPath))
        }
    }

    /// A static screen sends a frame only every few seconds. Write such a
    /// segment with the recorder's settings (frame every 2 s of media time),
    /// abandon the writer at 50 s the way a dead encoder does (no finish), and
    /// measure how much is still readable. Goal: lose at most ~3 s.
    static func fragmentProbe(timeCapped: Bool, withAudio: Bool = false, releaseWriter: Bool = false) async -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bs-frag-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let w = 1512, h = 982
        let readable: Double = await {
            var holder: AVAssetWriter? = try? AVAssetWriter(outputURL: url, fileType: .mov)
            if holder == nil { return -1 }
            unowned let writer = holder!
            writer.movieFragmentInterval = ScreenRecorder.fragmentInterval
            let input = AVAssetWriterInput(mediaType: .video,
                outputSettings: ScreenRecorder.screenVideoSettings(width: w, height: h, fps: 60, timeCappedKeyframes: timeCapped))
            input.expectsMediaDataInRealTime = true
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ])
            writer.add(input)
            var audioIn: AVAssetWriterInput?
            if withAudio {
                let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 2,
                    AVSampleRateKey: 48_000, AVEncoderBitRateKey: 192_000])
                ai.expectsMediaDataInRealTime = true
                writer.add(ai); audioIn = ai
            }
            guard writer.startWriting() else { return -2 }
            writer.startSession(atSourceTime: .zero)
            for i in 0...25 {   // frames at 0, 2, …, 50 s
                while !input.isReadyForMoreMediaData { try? await Task.sleep(nanoseconds: 2_000_000) }
                guard let pool = adaptor.pixelBufferPool else { return -3 }
                var pb: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
                guard let pb else { return -4 }
                CVPixelBufferLockBaseAddress(pb, [])
                if let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0) { memset(y, Int32(30 + i * 7), CVPixelBufferGetBytesPerRowOfPlane(pb, 0) * h) }
                if let uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1) { memset(uv, 128, CVPixelBufferGetBytesPerRowOfPlane(pb, 1) * h / 2) }
                CVPixelBufferUnlockBaseAddress(pb, [])
                guard adaptor.append(pb, withPresentationTime: CMTime(seconds: Double(i) * 2, preferredTimescale: 600)) else { return -5 }
                if let ai = audioIn, i < 25 {   // 2 s of silent audio per video frame
                    for c in 0..<94 {
                        let start = Double(i) * 2 + Double(c) * 1024 / 48_000
                        if let sb = silentAudio(at: start), ai.isReadyForMoreMediaData { ai.append(sb) }
                    }
                }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            // Abandoned here: no markAsFinished / finishWriting, like a writer whose encoder died.
            if releaseWriter { holder = nil }   // the recorder drops its only reference on rollover
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let asset = AVURLAsset(url: url)
            guard let t = try? await asset.loadTracks(withMediaType: .video).first else { return 0 }
            let segs = (try? await t.load(.segments)) ?? []
            return segs.filter { !$0.isEmpty }.map { $0.timeMapping.target.end.seconds }.max() ?? 0
        }()
        if readable < 0 { return "fail: setup \(readable)" }
        let lost = 50 - readable
        return String(format: "%@: readable to %.1f s of 50 s (lost %.1f s)", lost <= 3 ? "ok" : "fail", readable, lost)
    }

    /// Same writer, but paced like a real take on the host clock: audio
    /// buffers every ~21 ms, a picture only every 1–3 s (static screen). The
    /// writer is dropped at `seconds` without finishing.
    static func realtimeFragmentProbe(seconds: Double, gap: Range<Double>? = nil, heartbeat: Bool = false) async -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bs-fragrt-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let w = 1512, h = 982
        var holder: AVAssetWriter? = try? AVAssetWriter(outputURL: url, fileType: .mov)
        guard holder != nil else { return "fail: writer init" }
        unowned let writer = holder!
        writer.movieFragmentInterval = ScreenRecorder.fragmentInterval
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: ScreenRecorder.screenVideoSettings(width: w, height: h, fps: 60))
        vIn.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        writer.add(vIn)
        let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 2, AVSampleRateKey: 48_000, AVEncoderBitRateKey: 192_000])
        aIn.expectsMediaDataInRealTime = true
        writer.add(aIn)
        guard writer.startWriting() else { return "fail: startWriting" }
        let clock = CMClockGetHostTimeClock()
        let t0 = CMClockGetTime(clock)
        writer.startSession(atSourceTime: t0)
        var audioSamples: Int64 = 0
        var nextFrameAt = 0.0
        var lastFrame: CVPixelBuffer?
        var lastFrameAt = 0.0
        var frames = 0
        var i = 0
        while true {
            let now = CMClockGetTime(clock)
            let elapsed = CMTimeSubtract(now, t0).seconds
            if elapsed >= seconds {
                if gap != nil, let pool = adaptor.pixelBufferPool {   // the frame that trips the failure
                    var pb: CVPixelBuffer?; CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
                    if let pb, vIn.isReadyForMoreMediaData { _ = adaptor.append(pb, withPresentationTime: now) }
                }
                break
            }
            // audio up to now
            while Double(audioSamples) / 48_000 <= elapsed {
                if let sb = silentAudio(at: t0.seconds + Double(audioSamples) / 48_000), aIn.isReadyForMoreMediaData { aIn.append(sb) }
                audioSamples += 1024
            }
            let inGap = gap?.contains(elapsed) ?? false
            if inGap && heartbeat, elapsed - lastFrameAt >= 1, vIn.isReadyForMoreMediaData, let last = lastFrame {
                if adaptor.append(last, withPresentationTime: now) { lastFrameAt = elapsed }
            }
            if !inGap, elapsed >= nextFrameAt, vIn.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool {
                var pb: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
                if let pb {
                    CVPixelBufferLockBaseAddress(pb, [])
                    if let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0) { memset(y, Int32(30 + (i * 37) % 200), CVPixelBufferGetBytesPerRowOfPlane(pb, 0) * h) }
                    if let uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1) { memset(uv, 128, CVPixelBufferGetBytesPerRowOfPlane(pb, 1) * h / 2) }
                    CVPixelBufferUnlockBaseAddress(pb, [])
                    if adaptor.append(pb, withPresentationTime: now) { frames += 1; lastFrame = pb; lastFrameAt = elapsed }
                }
                i += 1
                nextFrameAt = elapsed + (gap == nil ? Double.random(in: 1...3) : 1)
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let status = writer.status.rawValue
        holder = nil   // abandoned like a dead encoder: no finishWriting
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        let asset = AVURLAsset(url: url)
        func end(_ type: AVMediaType) async -> Double {
            guard let t = try? await asset.loadTracks(withMediaType: type).first else { return 0 }
            let segs = (try? await t.load(.segments)) ?? []
            return segs.filter { !$0.isEmpty }.map { $0.timeMapping.target.end.seconds }.max() ?? 0
        }
        let v = await end(.video), a = await end(.audio)
        // With a gap, judge by audio (the picture had nothing new to keep).
        let lost = gap != nil ? seconds - a : seconds - max(v, a)
        return String(format: "%@: %.0f s take, %d frames, writer status %d; readable video to %.1f s, audio to %.1f s (lost %.1f s)",
                      lost <= 3 ? "ok" : "fail", seconds, frames, status, v, a, lost)
    }

    static func silentAudio(at seconds: Double) -> CMSampleBuffer? {
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsFloat | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var fmt: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt)
        let n = 1024, bytes = n * 8
        var bb: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &bb)
        guard let bb, let fmt else { return nil }
        CMBlockBufferFillDataBytes(with: 0, blockBuffer: bb, offsetIntoDestination: 0, dataLength: bytes)
        var sb: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: bb, formatDescription: fmt,
            sampleCount: n, presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 48_000),
            packetDescriptions: nil, sampleBufferOut: &sb)
        return sb
    }

    /// Isolates "is the encoder/writer broken in this process?" from "are the
    /// SCK buffers bad?": 3 s of 1512x982 NV12 frames drawn on the CPU, same
    /// settings as the screen recorder, then finishWriting.
    static func syntheticWriterProbe() async -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bs-synth-\(UUID().uuidString).mov")
        let w = 1512, h = 982, fps = 60
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return "fail: writer init" }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(8_000_000, w * h * fps / 12),
                                              AVVideoMaxKeyFrameIntervalKey: fps * 2,
                                              AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel],
        ])
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ])
        writer.add(input)
        guard writer.startWriting() else { return "fail: startWriting \(String(describing: writer.error))" }
        writer.startSession(atSourceTime: .zero)
        var appended = 0
        for i in 0..<(fps * 3) {
            while !input.isReadyForMoreMediaData { try? await Task.sleep(nanoseconds: 2_000_000) }
            guard let pool = adaptor.pixelBufferPool else { return "fail: no pool, status=\(writer.status.rawValue) \(String(describing: writer.error))" }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let pb else { return "fail: no buffer" }
            CVPixelBufferLockBaseAddress(pb, [])
            if let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0) {
                memset(y, Int32(16 + (i * 3) % 200), CVPixelBufferGetBytesPerRowOfPlane(pb, 0) * h)
            }
            if let uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1) {
                memset(uv, 128, CVPixelBufferGetBytesPerRowOfPlane(pb, 1) * h / 2)
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            if !adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps))) {
                return "fail: append at frame \(i), status=\(writer.status.rawValue) \(String(describing: writer.error))"
            }
            appended += 1
        }
        input.markAsFinished()
        await writer.finishWriting()
        defer { try? FileManager.default.removeItem(at: url) }
        return writer.status == .completed ? "ok: \(appended) frames finalized" : "fail: finish status=\(writer.status.rawValue) \(String(describing: writer.error))"
    }

    struct Report: Codable {
        var runs: [RunResult] = []
        var exportOk = false
        var exportDurationSec: Double = 0
        var exportError: String?
        var error: String?
        var pass = false
        /// `--selftest-synthetic-writer`: same H.264 writer settings fed with
        /// CPU-made NV12 frames instead of ScreenCaptureKit buffers.
        var syntheticWriter: String?
        /// `--selftest-fragment-probe`: low-frame-rate segment abandoned at
        /// 50 s; how much of it is still readable, with and without the
        /// time-capped keyframe setting.
        var fragmentProbe: [String: String]?
    }

    struct RunResult: Codable {
        var index: Int
        var bundlePath = ""
        var pass = false
        var failureJson = false
        var metadata = false
        var screenTrack = false
        var screenDims = ""
        var screenDurationSec: Double = 0
        var recordSeconds: Double = 0
        var exportSec: Double = 0
        var pauses = 0
        var framesInPause = -1
        var cursorTour: [String] = []
        var cursorWorstPt: Double = -1
        var samplesInPause: [String: Int] = [:]
        var silenceFailures = -1
        var audioEndVsPicture: [String: Double] = [:]
        var projectCuts = -1
        var exportError: String?
        var webcamTrack = false
        var micTrack = false
        var openOk = false
        var openError: String?
    }
}
