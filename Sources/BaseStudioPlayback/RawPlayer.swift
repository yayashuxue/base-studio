import AVFoundation
import AVKit
import BaseStudioCore
import SwiftUI

/// Generic URL-driven AVPlayer view. Used in M0/M2 for raw screen playback and
/// post-export polished-mp4 playback. Replaced in M3 by the engine-backed player.
public struct URLPlayerView: NSViewRepresentable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.player = AVPlayer(url: url)
        return view
    }

    public func updateNSView(_ nsView: AVPlayerView, context: Context) {
        let current = (nsView.player?.currentItem?.asset as? AVURLAsset)?.url
        if current != url {
            nsView.player = AVPlayer(url: url)
        }
    }
}

@available(*, deprecated, renamed: "URLPlayerView")
public struct RawPlayerView: NSViewRepresentable {
    public let bundle: ProjectBundle
    public init(bundle: ProjectBundle) { self.bundle = bundle }
    public func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = AVPlayer(url: bundle.screenURL)
        return view
    }
    public func updateNSView(_ nsView: AVPlayerView, context: Context) {}
}
