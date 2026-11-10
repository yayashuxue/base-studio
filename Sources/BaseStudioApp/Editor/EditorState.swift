import AVFoundation
import BaseStudioCore
import BaseStudioRender
import CoreImage
import CoreMedia
import Foundation
import SwiftUI

/// Owns the loaded `Project`, the playhead, and source-frame access for the editor.
/// Mutating any param in `project` causes a render pass; mutating `playheadSec`
/// also causes a render pass.
@MainActor
final class EditorState: ObservableObject {

    @Published var project: Project {
        didSet {
            cachedTimeMap = nil
            cachedSourcesByID = nil
            previewAudio.stale = true
            // Reload disk-backed bg only when filename changes — otherwise
            // playhead scrubbing keeps re-decoding the PNG.
            if oldValue.backgroundImageRel != project.backgroundImageRel {
                loadBackgroundImage()
            }
        }
    }
    /// CIImage for `project.backgroundImageRel`, lazily loaded and reused
    /// across frames. nil when no upload is set or the file is missing.
    private var backgroundImageCache: CIImage?
    @Published var playheadSec: Double = 0
    @Published var isPlaying: Bool = false
    @Published var renderedImage: NSImage?
    @Published var renderFailureMessage: String?
    @Published var waveform: AudioWaveform.Samples?
    @Published var selectedRegionID: String?
    @Published var isTranscribing: Bool = false
    @Published var transcribeError: String?

    let bundleURL: URL
    let sidecars: SidecarStreams
    let primarySource: SourceClip
    let recordingMeta: RecordingMetadata
    private let ciContext: CIContext

    private var generators: [String: AVAssetImageGenerator] = [:]
    private var cachedFrame: (sourceID: String, pts: CMTime, image: CIImage)?
    // Per-project caches; invalidated by `project.didSet`. Read on the
    // per-frame render hot path.
    private var cachedTimeMap: TimeMap?
    private var cachedSourcesByID: [String: SourceClip]?
    /// We intentionally do NOT cancel a running render mid-flight:
    /// AVAssetImageGenerator decode work doesn't honour Task cancellation,
    /// so cancel-and-restart at 30fps throws away nearly-finished frames
    /// and starves playback. `scheduleRender` while busy flips
    /// `renderPending` and the running render re-schedules itself.
    private var renderInFlight = false
    private var renderPending = false
    /// The take's sound while previewing (same sources and TimeMap as
    /// export); its clock drives the playhead — see PreviewClock.
    private lazy var previewAudio: PlayerPreviewAudio = {
        let p = PlayerPreviewAudio { [weak self] in await self?.makePreviewAudioItem() }
        p.onItemFailed = { [weak self] _ in self?.playerDrawsPicture = false }
        return p
    }()
    private lazy var clock: PreviewClock = {
        let c = PreviewClock(output: previewAudio)
        c.onTick = { [weak self] sec, ended in
            guard let self else { return }
            if ended {
                self.isPlaying = false
                self.playheadSec = 0
                self.scheduleRender()
            } else {
                self.playheadSec = sec
                // While playing, the player draws the picture (PlayerLayerView);
                // rendering here too only competed with it for the CPU.
                if !self.playerDrawsPicture { self.scheduleRender() }
            }
        }
        return c
    }()
    private var saveDebounce: Timer?

    // Undo/redo stacks of Project snapshots (immutable Codable structs).
    private var undoStack: [Project] = []
    private var redoStack: [Project] = []
    private var undoCoalesceTimer: Timer?
    private static let undoLimit = 80

    @Published var canUndo: Bool = false
    @Published var canRedo: Bool = false

    init(
        project: Project,
        bundleURL: URL,
        sidecars: SidecarStreams,
        primary: SourceClip,
        recordingMeta: RecordingMetadata
    ) {
        self.project = project
        self.bundleURL = bundleURL
        self.sidecars = sidecars
        self.primarySource = primary
        self.recordingMeta = recordingMeta
        self.ciContext = CIContext(options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
        ])

        for src in project.sources {
            let url = bundleURL.appendingPathComponent(src.relativeMediaPath)
            let asset = AVURLAsset(url: url)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            // ~33ms (one frame @ 30fps). Tight enough to catch host/file-time
            // mismatches (host-PTS ~10^6s is far outside any tolerance);
            // loose enough that playback doesn't reseek every 16ms.
            // NEVER set to `.positiveInfinity` — it silently clamps to the
            // last frame on mismatch and masks bugs (see camera-replay #2).
            gen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
            gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
            generators[src.id] = gen
        }

        // Async waveform load — prefer mic.m4a if present, else screen.mov.
        Task { [bundleURL] in
            let micURL = bundleURL.appendingPathComponent("mic.m4a")
            let screenURL = bundleURL.appendingPathComponent("screen.mov")
            let audioURL = FileManager.default.fileExists(atPath: micURL.path) ? micURL : screenURL
            if let samples = await AudioWaveform.extract(url: audioURL) {
                await MainActor.run { [weak self] in self?.waveform = samples }
            }
        }

        loadBackgroundImage()
    }

    private func loadBackgroundImage() {
        guard let name = project.backgroundImageRel else {
            backgroundImageCache = nil
            return
        }
        backgroundImageCache = BackgroundImageStore.loadCIImage(filename: name)
    }

    /// Import a user-picked image into the global background library and
    /// point this project at it. The original file is left untouched.
    func uploadBackgroundImage(from sourceURL: URL) throws {
        let stored = try BackgroundImageStore.importFile(sourceURL)
        pushUndoSnapshot()
        project.backgroundImageRel = stored
        scheduleAutoSave()
    }

    /// Clear the upload — `BackgroundCompose` falls back to the gradient preset.
    func clearBackgroundImage() {
        guard project.backgroundImageRel != nil else { return }
        pushUndoSnapshot()
        project.backgroundImageRel = nil
        scheduleAutoSave()
    }

    /// Switch to an already-uploaded image in the global library by name.
    /// Use `clearBackgroundImage()` to fall back to the gradient preset.
    func selectBackgroundImage(_ name: String) {
        guard project.backgroundImageRel != name else { return }
        pushUndoSnapshot()
        project.backgroundImageRel = name
        scheduleAutoSave()
    }

    // MARK: - region editing

    func addZoomRegion(timelineInSec: Double, timelineOutSec: Double) {
        pushUndoSnapshot()
        let inT = TimePoint(CMTime(seconds: max(0, timelineInSec), preferredTimescale: 600))
        let outT = TimePoint(CMTime(seconds: max(timelineInSec + 0.4, timelineOutSec), preferredTimescale: 600))
        let id = "r_\(Int(Date().timeIntervalSince1970 * 1000))"
        project.zoomRegions.append(ZoomRegion(
            id: id, timelineIn: inT, timelineOut: outT,
            scale: 1.45, followCursor: true, fixedCenter: nil,
            transitionSec: 0.35, auto: false
        ))
        selectedRegionID = id
        scheduleRender(); scheduleAutoSave()
    }

    func updateZoomRegion(_ id: String, _ mutate: (inout ZoomRegion) -> Void) {
        guard let i = project.zoomRegions.firstIndex(where: { $0.id == id }) else { return }
        pushUndoSnapshot()
        mutate(&project.zoomRegions[i])
        scheduleRender(); scheduleAutoSave()
    }

    func deleteZoomRegion(_ id: String) {
        pushUndoSnapshot()
        project.zoomRegions.removeAll { $0.id == id }
        if selectedRegionID == id { selectedRegionID = nil }
        scheduleRender(); scheduleAutoSave()
    }

    func setCanvas(_ canvas: CanvasSpec) {
        pushUndoSnapshot()
        project.canvas = canvas
        scheduleRender(); scheduleAutoSave()
    }

    /// Auto-transcribe the recording's mic.m4a (or screen.mov audio) and store
    /// the resulting captions in the project. Enables the CaptionOverlay node.
    func generateCaptions() {
        guard #available(macOS 13.0, *) else { return }
        guard !isTranscribing else { return }
        isTranscribing = true
        transcribeError = nil

        let micURL = bundleURL.appendingPathComponent("mic.m4a")
        let screenURL = bundleURL.appendingPathComponent("screen.mov")
        let audioURL = FileManager.default.fileExists(atPath: micURL.path) ? micURL : screenURL
        let originPTS = primarySource.firstPTS.cmTime

        Task { [weak self] in
            do {
                var captions = try await SpeechTranscriber.transcribe(audioURL: audioURL)
                // Speech timing is source-relative (starts at 0 in the file).
                // For mic.m4a it starts at 0 anyway. For screen.mov audio, audio
                // PTSes match host clock, so subtract first-frame PTS to land
                // on timeline-zero.
                if audioURL.lastPathComponent == "screen.mov" {
                    let originS = originPTS.seconds
                    captions = captions.map {
                        Caption(id: $0.id,
                                startSec: $0.startSec - originS,
                                endSec: $0.endSec - originS,
                                text: $0.text)
                    }
                }
                await MainActor.run {
                    guard let self else { return }
                    self.pushUndoSnapshot()
                    self.project.captions = captions
                    // Enable the caption node if present.
                    if let i = self.project.nodeGraph.nodes.firstIndex(
                        where: { $0.nodeType == CaptionOverlay.spec.id }
                    ) {
                        self.project.nodeGraph.nodes[i].enabled = true
                    }
                    self.isTranscribing = false
                    self.scheduleRender()
                    self.scheduleAutoSave()
                }
            } catch {
                await MainActor.run {
                    self?.transcribeError = error.localizedDescription
                    self?.isTranscribing = false
                }
            }
        }
    }

    var timeMap: TimeMap {
        if let cached = cachedTimeMap { return cached }
        let map = project.timeMap(primaryFirstPTS: primarySource.firstPTS.cmTime)
        cachedTimeMap = map
        return map
    }

    private var sourcesByID: [String: SourceClip] {
        if let cached = cachedSourcesByID { return cached }
        let map = project.sourcesByID
        cachedSourcesByID = map
        return map
    }

    var timelineDurationSec: Double {
        let d = timeMap.timelineDurationSec
        return d.isFinite && d > 0 ? d : 1
    }

    var playheadPTS: CMTime {
        CMTime(seconds: max(0, min(playheadSec, timelineDurationSec)),
               preferredTimescale: 600)
    }

    // MARK: - mutations

    func updateNodeBinding(instanceID: InstanceID, paramName: String, _ binding: ParamBinding) {
        if let i = project.nodeGraph.nodes.firstIndex(where: { $0.instanceID == instanceID }) {
            pushUndoSnapshot()
            project.nodeGraph.nodes[i].bindings[paramName] = binding
            scheduleRender()
            scheduleAutoSave()
        }
    }

    func setNodeEnabled(instanceID: InstanceID, _ enabled: Bool) {
        if let i = project.nodeGraph.nodes.firstIndex(where: { $0.instanceID == instanceID }) {
            pushUndoSnapshot()
            project.nodeGraph.nodes[i].enabled = enabled
            scheduleRender()
            scheduleAutoSave()
        }
    }

    /// Update the trim points on the (single, for v1) primary segment.
    func setTrim(inSec: Double, outSec: Double) {
        guard !project.videoTrack.segments.isEmpty else { return }
        pushUndoSnapshot()
        let originPTS = primarySource.firstPTS.cmTime
        let inPTS = CMTimeAdd(originPTS, CMTime(seconds: max(0, inSec), preferredTimescale: 600))
        let outPTS = CMTimeAdd(originPTS, CMTime(seconds: max(0, outSec), preferredTimescale: 600))
        project.videoTrack.segments[0].sourceIn = TimePoint(inPTS)
        project.videoTrack.segments[0].sourceOut = TimePoint(outPTS)
        let dur = CMTimeSubtract(outPTS, inPTS)
        project.timelineDuration = TimePoint(dur)
        if playheadSec > dur.seconds { playheadSec = max(0, dur.seconds) }
        scheduleRender()
        scheduleAutoSave()
    }

    var trimInSec: Double {
        guard let seg = project.videoTrack.segments.first else { return 0 }
        return primarySource.fileTime(at: seg.sourceIn.cmTime).seconds
    }
    var trimOutSec: Double {
        guard let seg = project.videoTrack.segments.first else { return 0 }
        return primarySource.fileTime(at: seg.sourceOut.cmTime).seconds
    }
    var sourceFullDurationSec: Double {
        let s = CMTimeSubtract(recordingMeta.lastVideoPTS.cmTime, recordingMeta.firstVideoPTS.cmTime)
        return max(0.1, s.seconds)
    }

    private func scheduleAutoSave() {
        saveDebounce?.invalidate()
        saveDebounce = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.saveNow() }
        }
    }
    func saveNow() {
        try? ProjectIO.save(project, to: ProjectBundle(url: bundleURL))
    }

    // MARK: - Undo / Redo

    /// Push the *current* project onto the undo stack before a mutation. Coalesces
    /// rapid edits (e.g. slider drags) into a single undo entry over 0.4s windows.
    private func pushUndoSnapshot() {
        // If a coalesce window is active, treat this as part of the same group.
        if undoCoalesceTimer != nil { return }
        undoStack.append(project)
        if undoStack.count > Self.undoLimit { undoStack.removeFirst() }
        redoStack.removeAll()
        canUndo = !undoStack.isEmpty
        canRedo = false

        undoCoalesceTimer?.invalidate()
        undoCoalesceTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.undoCoalesceTimer = nil }
        }
    }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(project)
        if redoStack.count > Self.undoLimit { redoStack.removeFirst() }
        project = prev
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
        scheduleRender(); scheduleAutoSave()
    }
    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(project)
        if undoStack.count > Self.undoLimit { undoStack.removeFirst() }
        project = next
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
        scheduleRender(); scheduleAutoSave()
    }

    func setPlayhead(_ sec: Double) {
        playheadSec = max(0, min(timelineDurationSec, sec))
        clock.seek(to: playheadSec)
        // Scrubbing: draw quick, small frames while the playhead moves and a
        // full-quality one once it rests (julie: dragging the bar lagged).
        if !isPlaying {
            stillScale = 0.4
            settleTimer?.invalidate()
            settleTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    // Playing again: the player draws; no full-size still.
                    guard let self, !self.isPlaying else { return }
                    self.stillScale = 1
                    self.scheduleRender()
                }
            }
        }
        scheduleRender()
    }

    /// Timeline time and scale of the still currently shown (tests, diagnostics).
    private(set) var renderedImagePTS: CMTime?
    private(set) var renderedImageScale: Double = 1
    /// Render scale for the still preview: < 1 while scrubbing.
    private var stillScale: Double = 1
    private var settleTimer: Timer?

    // MARK: - playback

    func playPause() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard !isPlaying else { return }
        isPlaying = true
        settleTimer?.invalidate()
        stillScale = 1
        // 24fps for editor preview: per-frame HEVC decode + pipeline still
        // routinely exceeds 33ms on 4K screen recordings. Export still runs
        // at 60fps; this is a UI-only knob (PreviewClock's interval).
        clock.play(from: playheadSec, duration: timelineDurationSec)
    }

    func pause() {
        isPlaying = false
        clock.pause()
        scheduleRender()   // full-quality still at the stop point
    }

    /// Which audio the preview plays — the export's Audio choice, so what
    /// you hear while editing is what the file will contain.
    var previewAudioMode: ExportPipeline.AudioMode = .both {
        didSet {
            guard previewAudioMode != oldValue else { return }
            previewAudio.stale = true
            if isPlaying { pause(); play() }   // rebuild with the new sources now
        }
    }

    /// The player that shows playback (picture and sound).
    var previewPlayer: AVPlayer { previewAudio.player }
    /// true when the current playback item renders the picture itself.
    @Published private(set) var playerDrawsPicture = false

    private func makePreviewAudioItem() async -> AVPlayerItem? {
        let sources = await AudioPlan.sources(project: project, bundleURL: bundleURL, meta: recordingMeta,
                                              mode: previewAudioMode)
        // Picture + sound through PreviewPlayback (off-main, hardware decode,
        // one clock). Falls back to sound only, with the old per-frame render.
        do {
            let ctx = PreviewPlayback.Context(project: project, timeMap: timeMap, primary: primarySource,
                                              sidecars: sidecars, backgroundImage: backgroundImageCache)
            let item = try await PreviewPlayback.makeItem(ctx, bundleURL: bundleURL, audio: sources)
            playerDrawsPicture = item.videoComposition != nil
            return item
        } catch {
            BSLog.warn("preview playback unavailable (\(error)); falling back to per-frame preview")
            playerDrawsPicture = false
        }
        do {
            guard let built = try await PreviewAudio.build(sources: sources, timeMap: timeMap) else { return nil }
            let item = AVPlayerItem(asset: built.composition)
            item.audioMix = built.audioMix
            item.audioTimePitchAlgorithm = .spectral
            return item
        } catch {
            BSLog.warn("preview audio unavailable (\(error)); playing picture only")
            return nil
        }
    }

    // MARK: - rendering

    func scheduleRender() {
        renderFailureMessage = nil
        if renderInFlight {
            renderPending = true
            return
        }
        runRender()
    }

    private func runRender() {
        renderInFlight = true
        renderPending = false
        let snapshot = project
        let pts = playheadPTS
        let scale = stillScale
        Task { [weak self] in
            guard let self else { return }
            let image = await self.renderInternal(project: snapshot, at: pts, scale: scale)
            await MainActor.run {
                self.renderedImage = image
                self.renderedImagePTS = image == nil ? nil : pts
                self.renderedImageScale = scale
                self.renderInFlight = false
                if self.renderPending {
                    self.runRender()
                }
            }
        }
    }

    func renderInternal(project: Project, at pts: CMTime, scale: Double = 1) async -> NSImage? {
        guard let primaryImg = await sourceFrameAsync(primarySource.id, timelinePTS: pts) else {
            return nil
        }
        // sidecarOffset = trim shift; sidecars are normalized to first-frame PTS so
        // the lookup at timeline pts is `pts + fileTime(segIn)`.
        let segIn = project.videoTrack.segments.first?.sourceIn.cmTime
            ?? primarySource.firstPTS.cmTime
        let sidecarOffset = primarySource.fileTime(at: segIn)

        var inputs = Renderer.Inputs(
            project: project,
            pts: pts,
            sourceTime: sourceTime(at: pts),
            sidecarOffset: sidecarOffset,
            primarySource: primarySource,
            primaryFrame: primaryImg,
            sidecars: sidecars,
            quality: .high,
            ciContext: ciContext,
            backgroundImage: backgroundImageCache,
            frameProvider: { [weak self] sourceID, t in
                guard let self else { return nil }
                return self.syncSourceFrame(sourceID, timelinePTS: t)
            }
        )
        inputs.renderScale = scale
        let output = Renderer.render(inputs)
        let cw = Int((Double(project.canvas.widthPx) * scale).rounded())
        let ch = Int((Double(project.canvas.heightPx) * scale).rounded())
        guard let cg = ciContext.createCGImage(
            output, from: CGRect(x: 0, y: 0, width: cw, height: ch)
        ) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cw, height: ch))
    }

    // MARK: - frame fetch

    /// Resolve the on-disk file-time at which to seek `source` for a given
    /// timeline PTS. Primary honors trim + speed-ramps; secondary sources
    /// (e.g. webcam) share the host clock and only get the host→file shift.
    /// Every source is read at the same host time, mapped through the
    /// TimeMap (trim, cuts, speed) — as export does. The webcam used to be
    /// read at first frame + timeline time, ignoring trim and cuts.
    func seekTime(forSource source: SourceClip, timelinePTS: CMTime) -> CMTime {
        source.fileTime(at: primarySourcePTS(at: timelinePTS))
    }

    /// Source time (seconds since trim-in) shown at timeline `pts`; cursor
    /// streams and zoom regions are read at this time.
    func sourceTime(at pts: CMTime) -> CMTime {
        CMTime(seconds: timeMap.sourceSec(at: pts.seconds), preferredTimescale: 6000)
    }

    /// Resolve the seek target for `sourceID` and return a cache hit if we
    /// already have its frame. nil = unknown source/generator (caller bails).
    private func resolveSeek(_ sourceID: String, timelinePTS: CMTime)
        -> (seekTime: CMTime, gen: AVAssetImageGenerator, cached: CIImage?)?
    {
        guard let src = sourcesByID[sourceID],
              let gen = generators[sourceID] else { return nil }
        let seekTime = seekTime(forSource: src, timelinePTS: timelinePTS)
        if let cached = cachedFrame,
           cached.sourceID == sourceID,
           abs(CMTimeGetSeconds(CMTimeSubtract(cached.pts, seekTime))) < 1.0 / 60.0 {
            return (seekTime, gen, cached.image)
        }
        return (seekTime, gen, nil)
    }

    private func sourceFrameAsync(_ sourceID: String, timelinePTS: CMTime) async -> CIImage? {
        guard let r = resolveSeek(sourceID, timelinePTS: timelinePTS) else { return nil }
        if let hit = r.cached { return hit }
        do {
            let result = try await r.gen.image(at: r.seekTime)
            let img = CIImage(cgImage: result.image)
            cachedFrame = (sourceID, r.seekTime, img)
            return img
        } catch {
            BSLog.error("image gen failed for \(sourceID) at fileTime=\(r.seekTime.seconds): \(error.localizedDescription)")
            await MainActor.run { [weak self] in
                self?.renderFailureMessage = "Couldn't read frame from \(sourceID).mov — recording may be corrupt. \(error.localizedDescription)"
            }
            return nil
        }
    }

    /// Source PTS for the primary clip at a given timeline t — honors speed-ramp slices.
    private func primarySourcePTS(at timelinePTS: CMTime) -> CMTime {
        let map = timeMap
        return map.sourcePTS(
            at: timelinePTS.seconds,
            firstPTS: primarySource.firstPTS.cmTime
        )
    }

    // Synchronous wrapper for the renderer's frameProvider closure (which is sync).
    private func syncSourceFrame(_ sourceID: String, timelinePTS: CMTime) -> CIImage? {
        guard let r = resolveSeek(sourceID, timelinePTS: timelinePTS) else { return nil }
        if let hit = r.cached { return hit }
        do {
            var actualTime = CMTime.zero
            let cg = try r.gen.copyCGImage(at: r.seekTime, actualTime: &actualTime)
            let img = CIImage(cgImage: cg)
            cachedFrame = (sourceID, r.seekTime, img)
            return img
        } catch {
            return nil
        }
    }
}

extension EditorState {
    /// Build an EditorState from a recording bundle. Loads `edl.json` if present
    /// (so user edits persist across launches), otherwise builds a fresh polish preset.
    static func load(bundleURL: URL) throws -> EditorState {
        let bundle = ProjectBundle(url: bundleURL)
        let metaData = try Data(contentsOf: bundle.metadataURL)
        let meta = try JSONDecoder().decode(RecordingMetadata.self, from: metaData)
        let project: Project
        if ProjectIO.hasEDL(bundle) {
            project = try ProjectIO.load(from: bundle)
        } else {
            project = try PolishPreset.makeProject(bundle: bundle)
            try ProjectIO.save(project, to: bundle)
        }
        guard let primary = project.sources.first(where: { $0.id == SourceID.screen })
                ?? project.sources.first
        else { throw EditorLoadError.noPrimary }

        // Load sidecars (transformed cursor coords).
        var cursorMap: [String: [CursorPosSample]] = [:]
        var clickMap: [String: [ClickEventSample]] = [:]
        if let cursorRef = primary.sidecars.first(where: { $0.kind == .cursor }) {
            let url = bundleURL.appendingPathComponent(cursorRef.relativePath)
            let (cur, clicks) = try SidecarLoader.loadCursorJSON(at: url, meta: meta)
            cursorMap[cursorRef.streamID] = cur
            clickMap["clicks"] = clicks
        }
        let sidecars = SidecarStreams(cursorPositions: cursorMap, clickEvents: clickMap)

        return EditorState(
            project: project, bundleURL: bundleURL,
            sidecars: sidecars, primary: primary,
            recordingMeta: meta
        )
    }
}

enum EditorLoadError: Error { case noPrimary }
