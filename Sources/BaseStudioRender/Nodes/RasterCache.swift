import CoreImage
import Foundation

/// Rasterizes images that don't change from frame to frame (backgrounds,
/// drop shadows, masks) once and reuses the pixels. A CIImage graph is
/// re-evaluated on every render — a 48 px Gaussian shadow over the whole
/// canvas cost ~60 ms a frame and made preview playback crawl.
enum RasterCache {
    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var images: [String: CIImage] = [:]
        var order: [String] = []
    }
    private static let box = Box()
    private static let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
        .cacheIntermediates: false,
    ])
    private static let limit = 24

    /// The rasterized `make()` for `key` (made once; small LRU).
    static func image(_ key: String, _ make: () -> CIImage) -> CIImage {
        box.lock.lock()
        if let hit = box.images[key] { box.lock.unlock(); return hit }
        box.lock.unlock()
        let source = make()
        let extent = source.extent
        guard extent.width.isFinite, extent.height.isFinite, extent.width > 0, extent.height > 0,
              let cg = context.createCGImage(source, from: extent,
                                             format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        else { return source }
        let img = CIImage(cgImage: cg).transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
        box.lock.lock()
        box.images[key] = img
        box.order.append(key)
        if box.order.count > limit { box.images.removeValue(forKey: box.order.removeFirst()) }
        box.lock.unlock()
        return img
    }
}
