import BaseStudioCore
import CoreMedia
import SwiftUI

/// Timeline strip beneath the canvas. Layers, top to bottom:
///   - Audio waveform (orange)
///   - Click event dots (blue)
///   - Trim handles (yellow) at start/end
///   - Zoom region bars (purple, draggable; resize from edges; click to select)
///   - Playhead (white)
///
/// Empty-area drag → create new zoom region.
struct TimelineView: View {
    @ObservedObject var state: EditorState

    @State private var dragOrigin: (region: String, edge: Edge?, start: Double, end: Double)?
    @State private var creating: (startSec: Double, endSec: Double)?

    enum Edge { case leading, trailing, body }

    var body: some View {
        GeometryReader { geo in
            let totalDur = state.sourceFullDurationSec
            let inSec = state.trimInSec
            let outSec = state.trimOutSec
            let w = geo.size.width
            let h = geo.size.height
            let inX = w * CGFloat(inSec / max(totalDur, 0.0001))
            let outX = w * CGFloat(outSec / max(totalDur, 0.0001))
            let trimmedSpan = max(0.001, outSec - inSec)
            let playSourceSec = inSec + state.playheadSec
            let playX = w * CGFloat(playSourceSec / max(totalDur, 0.0001))

            ZStack(alignment: .topLeading) {
                // Track background.
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.06))
                    .frame(width: w, height: h)

                // Audio waveform (in source-time space).
                if let wf = state.waveform {
                    waveformPath(wf: wf, width: w, height: h, totalDur: totalDur)
                        .fill(Color.orange.opacity(0.55))
                }

                // Trim shading.
                if inX > 0 {
                    Rectangle().fill(Color.black.opacity(0.55))
                        .frame(width: inX, height: h)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                if outX < w {
                    Rectangle().fill(Color.black.opacity(0.55))
                        .frame(width: max(0, w - outX), height: h)
                        .offset(x: outX, y: 0)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                // Zoom regions (timeline-time space; offset by trim).
                ForEach(state.project.zoomRegions) { region in
                    regionBar(region: region, w: w, trimInSec: inSec,
                              trimmedSpan: trimmedSpan, totalDur: totalDur, h: h)
                }

                // Click dots.
                ForEach(clickXs(width: w, totalDur: totalDur), id: \.self) { x in
                    Circle().fill(Color.blue.opacity(0.85))
                        .frame(width: 5, height: 5)
                        .offset(x: x - 2.5, y: h - 9)
                }

                // Trim handles.
                handle(color: .yellow)
                    .offset(x: inX - 6, y: 2)
                    .gesture(dragTrimHandle(.in, width: w, totalDur: totalDur))
                handle(color: .yellow)
                    .offset(x: outX - 6, y: 2)
                    .gesture(dragTrimHandle(.out, width: w, totalDur: totalDur))

                // Playhead.
                Rectangle().fill(Color.white)
                    .frame(width: 2, height: h + 4)
                    .offset(x: playX - 1, y: -2)
                    .shadow(color: .black.opacity(0.4), radius: 1)
                    .gesture(dragPlayhead(width: w, totalDur: totalDur))

                // In-progress new region.
                if let c = creating {
                    let cInX = w * CGFloat((inSec + c.startSec) / max(totalDur, 0.0001))
                    let cOutX = w * CGFloat((inSec + c.endSec) / max(totalDur, 0.0001))
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.purple, lineWidth: 2)
                        .frame(width: max(2, cOutX - cInX), height: h - 4)
                        .offset(x: min(cInX, cOutX), y: 2)
                }
            }
            .frame(width: w, height: h)
            .contentShape(Rectangle())
            .gesture(emptyAreaCreateDrag(w: w, totalDur: totalDur, trimInSec: inSec))
            .onTapGesture { state.selectedRegionID = nil }
        }
        .frame(height: 56)
    }

    // MARK: - components

    private enum HandleKind { case `in`, out }

    private func handle(color: Color) -> some View {
        Capsule().fill(color)
            .frame(width: 12, height: 50)
            .overlay(Capsule().stroke(Color.black.opacity(0.5), lineWidth: 1))
    }

    private func regionBar(
        region: ZoomRegion, w: CGFloat, trimInSec: Double,
        trimmedSpan: Double, totalDur: Double, h: CGFloat
    ) -> some View {
        let regionInS = trimInSec + region.timelineIn.seconds
        let regionOutS = trimInSec + region.timelineOut.seconds
        let inX = w * CGFloat(regionInS / max(totalDur, 0.0001))
        let outX = w * CGFloat(regionOutS / max(totalDur, 0.0001))
        let isSelected = state.selectedRegionID == region.id
        let body = max(2, outX - inX)

        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.purple.opacity(region.auto ? 0.45 : 0.65))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(isSelected ? Color.white : Color.purple.opacity(0.9),
                                lineWidth: isSelected ? 2 : 1)
                )
                .frame(width: body, height: h - 18)
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 9))
                Text(String(format: "%.1f×%@", region.scale, region.auto ? " · Auto" : ""))
                    .font(.system(size: 10, weight: .medium))
            }
            .padding(.horizontal, 6)
            .foregroundStyle(.white)
        }
        .offset(x: inX, y: 8)
        .gesture(regionGesture(region: region, w: w, totalDur: totalDur))
        .onTapGesture {
            state.selectedRegionID = region.id
        }
        .contextMenu {
            Button("Delete", role: .destructive) {
                state.deleteZoomRegion(region.id)
            }
        }
    }

    // MARK: - waveform path

    private func waveformPath(
        wf: AudioWaveform.Samples, width: CGFloat, height: CGFloat, totalDur: Double
    ) -> Path {
        var path = Path()
        guard wf.peaks.count > 1, totalDur > 0 else { return path }
        let trackHeight = height - 12
        let mid = 6 + trackHeight / 2

        // We sample one peak per pixel.
        let count = Int(width)
        guard count > 1 else { return path }
        let secPerPx = totalDur / Double(count)

        path.move(to: CGPoint(x: 0, y: mid))
        for px in 0..<count {
            let s = Double(px) * secPerPx
            let bin = Int(s * wf.binsPerSecond)
            let peak = (bin >= 0 && bin < wf.peaks.count) ? wf.peaks[bin] : 0
            let h = CGFloat(peak) * (trackHeight / 2)
            path.move(to: CGPoint(x: CGFloat(px), y: mid - h))
            path.addLine(to: CGPoint(x: CGFloat(px), y: mid + h))
        }
        return path
    }

    // MARK: - clicks

    private func clickXs(width: CGFloat, totalDur: Double) -> [CGFloat] {
        guard totalDur > 0,
              let clicks = state.sidecars.clickEvents["clicks"]
        else { return [] }
        return clicks.filter { $0.phase == "down" }.map { ev in
            width * CGFloat(max(0, min(totalDur, ev.pts.seconds)) / totalDur)
        }
    }

    // MARK: - gestures

    private func dragTrimHandle(_ kind: HandleKind, width: CGFloat, totalDur: Double) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                let frac = max(0, min(1, v.location.x / width))
                let sourceSec = Double(frac) * totalDur
                switch kind {
                case .in:
                    let newIn = max(0, min(state.trimOutSec - 0.1, sourceSec))
                    state.setTrim(inSec: newIn, outSec: state.trimOutSec)
                case .out:
                    let newOut = max(state.trimInSec + 0.1, min(totalDur, sourceSec))
                    state.setTrim(inSec: state.trimInSec, outSec: newOut)
                }
            }
    }

    private func dragPlayhead(width: CGFloat, totalDur: Double) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                let frac = max(0, min(1, v.location.x / width))
                let sourceSec = Double(frac) * totalDur
                state.setPlayhead(max(0, sourceSec - state.trimInSec))
            }
    }

    private func regionGesture(region: ZoomRegion, w: CGFloat, totalDur: Double) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { v in
                if dragOrigin == nil {
                    let inS = region.timelineIn.seconds
                    let outS = region.timelineOut.seconds
                    let regWidth = w * CGFloat((outS - inS) / max(totalDur, 0.0001))
                    let edge: Edge
                    let lx = v.startLocation.x
                    let regOriginX = w * CGFloat((state.trimInSec + inS) / max(totalDur, 0.0001))
                    let local = lx - regOriginX
                    if local < 8 { edge = .leading }
                    else if local > regWidth - 8 { edge = .trailing }
                    else { edge = .body }
                    dragOrigin = (region.id, edge, inS, outS)
                    state.selectedRegionID = region.id
                }
                guard let origin = dragOrigin else { return }
                let dxSec = Double(v.translation.width) / Double(w) * totalDur
                state.updateZoomRegion(origin.region) { r in
                    switch origin.edge ?? .body {
                    case .leading:
                        var newIn = max(0, min(origin.end - 0.2, origin.start + dxSec))
                        newIn = snapToClick(newIn, totalDur: totalDur)
                        r.timelineIn = TimePoint(CMTime(seconds: newIn, preferredTimescale: 600))
                    case .trailing:
                        var newOut = max(origin.start + 0.2, origin.end + dxSec)
                        newOut = snapToClick(newOut, totalDur: totalDur)
                        r.timelineOut = TimePoint(CMTime(seconds: newOut, preferredTimescale: 600))
                    case .body:
                        var newIn = max(0, origin.start + dxSec)
                        newIn = snapToClick(newIn, totalDur: totalDur)
                        let len = origin.end - origin.start
                        r.timelineIn = TimePoint(CMTime(seconds: newIn, preferredTimescale: 600))
                        r.timelineOut = TimePoint(CMTime(seconds: newIn + len, preferredTimescale: 600))
                    }
                    r.auto = false
                }
            }
            .onEnded { _ in dragOrigin = nil }
    }

    /// Snap a timeline-relative seconds value to the nearest click event if within
    /// ~0.15s. Source-time clicks live in `state.sidecars.clickEvents["clicks"]`
    /// in the same timeline-relative space (they were normalized at sidecar load).
    private func snapToClick(_ s: Double, totalDur: Double) -> Double {
        guard let clicks = state.sidecars.clickEvents["clicks"] else { return s }
        let snapWindow: Double = 0.15
        var best: (delta: Double, target: Double)? = nil
        for c in clicks where c.phase == "down" {
            let d = abs(c.pts.seconds - s)
            if d < snapWindow, best == nil || d < best!.delta {
                best = (d, c.pts.seconds)
            }
        }
        return best?.target ?? s
    }

    private func emptyAreaCreateDrag(w: CGFloat, totalDur: Double, trimInSec: Double) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { v in
                // Only when the drag started in empty area (no region under finger).
                let startFrac = max(0, min(1, v.startLocation.x / w))
                let startSourceSec = Double(startFrac) * totalDur
                if hitTestRegion(at: startSourceSec, trimInSec: trimInSec) != nil { return }
                let curFrac = max(0, min(1, v.location.x / w))
                let curSourceSec = Double(curFrac) * totalDur
                let lo = min(startSourceSec, curSourceSec)
                let hi = max(startSourceSec, curSourceSec)
                creating = (startSec: max(0, lo - trimInSec), endSec: max(0.4, hi - trimInSec))
            }
            .onEnded { _ in
                if let c = creating, (c.endSec - c.startSec) > 0.2 {
                    let snappedStart = snapToClick(c.startSec, totalDur: totalDur)
                    let snappedEnd = snapToClick(c.endSec, totalDur: totalDur)
                    state.addZoomRegion(
                        timelineInSec: snappedStart,
                        timelineOutSec: max(snappedStart + 0.4, snappedEnd)
                    )
                }
                creating = nil
            }
    }

    private func hitTestRegion(at sourceSec: Double, trimInSec: Double) -> ZoomRegion? {
        let timelineSec = sourceSec - trimInSec
        return state.project.zoomRegions.first {
            timelineSec >= $0.timelineIn.seconds && timelineSec <= $0.timelineOut.seconds
        }
    }
}
