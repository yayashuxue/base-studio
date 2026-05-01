import Foundation

/// Discovers `.basestudio` bundles in the user's Movies folder. Lightweight —
/// scans one directory, reads modification dates, returns a sorted list.
public enum RecordingsLibrary {

    public struct Entry: Identifiable, Hashable {
        public let id: URL
        public var bundle: ProjectBundle { ProjectBundle(url: id) }
        public let displayName: String
        public let modifiedAt: Date
        public let hasPolishedExport: Bool
    }

    public static let directoryName = "BaseStudio"

    public static func defaultDirectory() throws -> URL {
        let fm = FileManager.default
        let url = try fm.url(
            for: .moviesDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent(directoryName, isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static func list(in directory: URL? = nil) throws -> [Entry] {
        let dir = try directory ?? defaultDirectory()
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return items
            .filter { $0.pathExtension == "basestudio" }
            .compactMap { url in
                let attrs = (try? fm.attributesOfItem(atPath: url.path)) ?? [:]
                let date = (attrs[.modificationDate] as? Date) ?? Date.distantPast
                let polished = url.appendingPathComponent("polished.mp4")
                return Entry(
                    id: url,
                    displayName: url.deletingPathExtension().lastPathComponent,
                    modifiedAt: date,
                    hasPolishedExport: fm.fileExists(atPath: polished.path)
                )
            }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    public static func delete(_ entry: Entry) throws {
        try FileManager.default.removeItem(at: entry.id)
    }

    /// Rename the bundle by renaming its directory. Returns the new URL.
    /// Sanitizes the name (strips slashes, trims) and ensures uniqueness.
    public static func rename(_ entry: Entry, to newDisplayName: String) throws -> URL {
        let trimmed = newDisplayName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return entry.id }
        let parent = entry.id.deletingLastPathComponent()
        var candidate = parent.appendingPathComponent("\(trimmed).basestudio")
        var i = 2
        while FileManager.default.fileExists(atPath: candidate.path), candidate != entry.id {
            candidate = parent.appendingPathComponent("\(trimmed) (\(i)).basestudio")
            i += 1
        }
        if candidate == entry.id { return entry.id }
        try FileManager.default.moveItem(at: entry.id, to: candidate)
        return candidate
    }
}
