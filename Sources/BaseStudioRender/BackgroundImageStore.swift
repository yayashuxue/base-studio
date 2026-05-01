import CoreImage
import Foundation

/// Global library of user-uploaded background images.
///
/// Files live at `~/Library/Application Support/BaseStudio/Backgrounds/`
/// — shared across recordings so an upload made for one project shows up
/// as a tile on every other project.
///
/// Project EDL stores only the bare filename (`Project.backgroundImageRel`),
/// not an absolute path. Moving a recording bundle does not break the
/// reference; deleting from the library does (BackgroundCompose then falls
/// back to the gradient preset, no crash).
public enum BackgroundImageStore {

    /// Allowed extensions for user uploads. Mirrors what `CIImage(contentsOf:)`
    /// can decode without a custom format hint.
    public static let allowedExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "webp"]

    public static var directoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("BaseStudio/Backgrounds", isDirectory: true)
    }

    /// Ensure the directory exists. Idempotent.
    public static func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: directoryURL, withIntermediateDirectories: true
        )
    }

    /// Filenames currently in the library, sorted alphabetically.
    public static func list() -> [String] {
        try? ensureDirectory()
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls
            .filter { allowedExtensions.contains($0.pathExtension.lowercased()) }
            .map { $0.lastPathComponent }
            .sorted()
    }

    /// Resolve a stored filename back to its on-disk URL, or nil if missing.
    public static func url(for filename: String) -> URL? {
        let url = directoryURL.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Copy a user-picked file into the library. Returns the stored filename
    /// (which may differ from the source if a name collision occurred). The
    /// original file is left untouched.
    @discardableResult
    public static func importFile(_ source: URL) throws -> String {
        try ensureDirectory()
        let ext = source.pathExtension.lowercased()
        guard allowedExtensions.contains(ext) else {
            throw NSError(domain: "BackgroundImageStore", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Unsupported background type .\(ext) — pick a PNG, JPG, HEIC, or WebP."
            ])
        }
        let baseName = source.deletingPathExtension().lastPathComponent
        var candidate = "\(baseName).\(ext)"
        var n = 1
        while FileManager.default.fileExists(atPath: directoryURL.appendingPathComponent(candidate).path) {
            n += 1
            candidate = "\(baseName)-\(n).\(ext)"
        }
        try FileManager.default.copyItem(
            at: source,
            to: directoryURL.appendingPathComponent(candidate)
        )
        return candidate
    }

    /// Load an image as a `CIImage`. Tracks color space so the renderer's
    /// sRGB working space treats it correctly.
    public static func loadCIImage(filename: String) -> CIImage? {
        guard let url = url(for: filename) else { return nil }
        return CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
    }
}
