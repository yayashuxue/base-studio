import AppKit
import SwiftUI

/// Live canvas — shows the current rendered frame from `EditorState`. Re-renders
/// when project params or playhead change. The renderer is the same one used by
/// export (PRD §5a parity contract): what you see here is what you get on export.
struct EngineCanvasView: View {
    @ObservedObject var state: EditorState

    var body: some View {
        ZStack {
            Color.black
            if let img = state.renderedImage {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFit()
            } else if state.renderFailureMessage != nil {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.orange)
                    Text("Couldn't load preview")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(state.renderFailureMessage ?? "")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            } else {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.large).tint(.white)
                    Text("Loading preview…")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .onAppear { state.scheduleRender() }
    }
}

/// Scrubber + transport controls.
struct ScrubberView: View {
    @ObservedObject var state: EditorState

    var body: some View {
        HStack(spacing: 12) {
            Button(action: state.playPause) {
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 28)
            }
            .buttonStyle(.plain)
            .padding(8)
            .background(.white.opacity(0.08), in: Circle())

            Text(BS.Format.mmss(state.playheadSec))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { state.playheadSec },
                    set: { state.setPlayhead($0) }
                ),
                in: 0...max(0.1, state.timelineDurationSec)
            )

            Text(BS.Format.mmss(state.timelineDurationSec))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 56)
        }
    }
}
