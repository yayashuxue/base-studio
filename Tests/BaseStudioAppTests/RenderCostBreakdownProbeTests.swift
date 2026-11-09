import AppKit
import AVFoundation
import CoreImage
import XCTest
@testable import BaseStudioApp
@testable import BaseStudioCore
@testable import BaseStudioRender

/// Manual probe (BS_EXISTING_BUNDLE): Renderer cost per frame at preview
/// size, with each node switched off in turn, to find the expensive one.
final class RenderCostBreakdownProbeTests: XCTestCase {
    @MainActor
    func testBreakdown() async throws {
        guard let path = ProcessInfo.processInfo.environment["BS_EXISTING_BUNDLE"] else { throw XCTSkip("manual") }
        NSApplication.shared.setActivationPolicy(.accessory)
        let editor = try EditorState.load(bundleURL: URL(fileURLWithPath: path))
        func frame(_ name: String) async throws -> CIImage {
            let g = AVAssetImageGenerator(asset: AVURLAsset(url: editor.bundleURL.appendingPathComponent(name)))
            return CIImage(cgImage: try await g.image(at: CMTime(seconds: 20, preferredTimescale: 600)).image)
        }
        let screen = try await frame("screen.mov"), cam = try await frame("webcam.mov")
        let ctx = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any])
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 960, 540, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        let segIn = editor.project.videoTrack.segments[0].sourceIn.cmTime
        func cost(_ project: Project) -> Double {
            var ms: [Double] = []
            for i in 0..<20 {
                let pts = CMTime(seconds: 20 + Double(i) / 30, preferredTimescale: 600)
                let t0 = CFAbsoluteTimeGetCurrent()
                let img = Renderer.render(.init(project: project, pts: pts, sourceTime: pts,
                    sidecarOffset: editor.primarySource.fileTime(at: segIn), primarySource: editor.primarySource,
                    primaryFrame: screen, sidecars: editor.sidecars, quality: .standard, ciContext: ctx,
                    backgroundImage: nil, frameProvider: { id, _ in id == SourceID.webcam ? cam : nil }))
                    .transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5))
                ctx.render(img, to: pb!)
                ms.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            }
            return ms.sorted()[10]
        }
        var none = editor.project; none.nodeGraph = NodeGraph(nodes: [])
        print(String(format: "RENDER no nodes (decode-free baseline): %.0f ms", cost(none)))
        print(String(format: "RENDER all nodes: %.0f ms", cost(editor.project)))
        for n in editor.project.nodeGraph.nodes where n.enabled {
            var p = editor.project
            for i in p.nodeGraph.nodes.indices where p.nodeGraph.nodes[i].instanceID == n.instanceID { p.nodeGraph.nodes[i].enabled = false }
            print(String(format: "RENDER without %@: %.0f ms", n.nodeType, cost(p)))
        }
    }
}
