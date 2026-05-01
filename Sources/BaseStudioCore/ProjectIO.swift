import Foundation

/// Reads / writes the EDL as `edl.json` inside a `.basestudio` bundle.
/// The PRD calls for human-readable EDLs (PRD §8) — JSON, not opaque blobs.
public enum ProjectIO {

    public static func edlURL(in bundle: ProjectBundle) -> URL {
        bundle.url.appendingPathComponent("edl.json")
    }

    public static func save(_ project: Project, to bundle: ProjectBundle) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(project)
        try data.write(to: edlURL(in: bundle), options: .atomic)
    }

    public static func load(from bundle: ProjectBundle) throws -> Project {
        let data = try Data(contentsOf: edlURL(in: bundle))
        return try JSONDecoder().decode(Project.self, from: data)
    }

    public static func hasEDL(_ bundle: ProjectBundle) -> Bool {
        FileManager.default.fileExists(atPath: edlURL(in: bundle).path)
    }
}
