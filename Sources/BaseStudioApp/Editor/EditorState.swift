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

    @Published var project: Project
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
    private var renderTask: Task<Void, Never>?
    private var playTimer: Timer?
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
            gen.requestedTimeToleranceBefore = .positiveInfinity
            gen.requestedTimeToleranceAfter = .positiveInfinity
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
        project.timeMap(primaryFirstPTS: primarySource.firstPTS.cmTime)
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
        return max(0, CMTimeGetSeconds(CMTimeSubtract(seg.sourceIn.cmTime, primarySource.firstPTS.cmTime)))
    }
    var trimOutSec: Double {
        guard let seg = project.videoTrack.segments.first else { return 0 }
        return max(0, CMTimeGetSeconds(CMTimeSubtract(seg.sourceOut.cmTime, primarySource.firstPTS.cmTime)))
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
        scheduleRender()
    }

    // MARK: - playback

    func playPause() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard !isPlaying else { return }
        isPlaying = true
        playTimer?.invalidate()
        let interval: TimeInterval = 1.0 / 30.0
        playTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.playheadSec += interval
                if self.playheadSec >= self.timelineDurationSec {
                    self.pause()
                    self.playheadSec = 0
                }
                self.scheduleRender()
            }
        }
    }

    func pause() {
        isPlaying = false
        playTimer?.invalidate()
        playTimer = nil
    }

    // MARK: - rendering

    func scheduleRender() {
        renderTask?.cancel()
        renderFailureMessage = nil
        let snapshot = project
        let pts = playheadPTS
        renderTask = Task { [weak self] in
            guard let self else { return }
            let image = await self.render(project: snapshot, at: pts)
            if Task.isCancelled { return }
            await MainActor.run { self.renderedImage = image }
        }
    }

    private nonisolated func render(project: Project, at pts: CMTime) async -> NSImage? {
        await renderInternal(project: project, at: pts)
    }

    private func renderInternal(project: Project, at pts: CMTime) async -> NSImage? {
        guard let primaryImg = await sourceFrameAsync(primarySource.id, timelinePTS: pts) else {
            return nil
        }
        // Trim offset: timeline 0 maps to segment.sourceIn in source time. Sidecars
        // are normalized to first-frame PTS, so the sidecar lookup time at timeline
        // pts is `pts + (sourceIn - firstPTS)`.
        let firstPTS = primarySource.firstPTS.cmTime
        let segIn = project.videoTrack.segments.first?.sourceIn.cmTime ?? firstPTS
        let sidecarOffset = CMTimeSubtract(segIn, firstPTS)

        let inputs = Renderer.Inputs(
            project: project,
            pts: pts,
            sidecarOffset: sidecarOffset,
            primarySource: primarySource,
            primaryFrame: primaryImg,
            sidecars: sidecars,
            quality: .high,
            ciContext: ciContext,
            frameProvider: { [weak self] sourceID, t in
                guard let self else { return nil }
                return self.syncSourceFrame(sourceID, timelinePTS: t)
            }
        )
        let output = Renderer.render(inputs)
        let cw = project.canvas.widthPx
        let ch = project.canvas.heightPx
        guard let cg = ciContext.createCGImage(
            output, from: CGRect(x: 0, y: 0, width: cw, height: ch)
        ) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cw, height: ch))
    }

    // MARK: - frame fetch

    private func sourceFrameAsync(_ sourceID: String, timelinePTS: CMTime) async -> CIImage? {
        let sourcePTS: CMTime
        if sourceID == primarySource.id {
            sourcePTS = primarySourcePTS(at: timelinePTS)
        } else {
            sourcePTS = CMTimeAdd(timelinePTS, sourceOrigin(sourceID))
        }
        if let cached = cachedFrame,
           cached.sourceID == sourceID,
           abs(CMTimeGetSeconds(CMTimeSubtract(cached.pts, sourcePTS))) < 1.0 / 60.0 {
            return cached.image
        }
        guard let gen = generators[sourceID] else { return nil }
        do {
            let result = try await gen.image(at: sourcePTS)
            let img = CIImage(cgImage: result.image)
            cachedFrame = (sourceID, sourcePTS, img)
            return img
        } catch {
            NSLog("BaseStudio: image gen failed for \(sourceID) at pts=\(sourcePTS.seconds): \(error.localizedDescription)")
            await MainActor.run { [weak self] in
                self?.renderFailureMessage = "Couldn't read frame from \(sourceID).mov — recording may be corrupt. \(error.localizedDescription)"
            }
            return nil
        }
    }

    private func sourceOrigin(_ sourceID: String) -> CMTime {
        // For the primary source, honor the segment's trim sourceIn.
        if sourceID == primarySource.id,
           let seg = project.videoTrack.segments.first {
            return seg.sourceIn.cmTime
        }
        // Other sources (webcam) keep the original first-frame PTS.
        return primarySource.firstPTS.cmTime
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
        let sourcePTS: CMTime
        if sourceID == primarySource.id {
            sourcePTS = primarySourcePTS(at: timelinePTS)
        } else {
            sourcePTS = CMTimeAdd(timelinePTS, sourceOrigin(sourceID))
        }
        if let cached = cachedFrame,
           cached.sourceID == sourceID,
           abs(CMTimeGetSeconds(CMTimeSubtract(cached.pts, sourcePTS))) < 1.0 / 60.0 {
            return cached.image
        }
        guard let gen = generators[sourceID] else { return nil }
        do {
            var actualTime = CMTime.zero
            let cg = try gen.copyCGImage(at: sourcePTS, actualTime: &actualTime)
            let img = CIImage(cgImage: cg)
            cachedFrame = (sourceID, sourcePTS, img)
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
        guard let primary = project.sources.first(where: { $0.id == "screen" })
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
