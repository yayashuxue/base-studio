import XCTest
@testable import BaseStudioCore

/// A new take must never land in an existing bundle: a self-test re-run once
/// replaced the only copy of a 330 s recording.
final class ProjectBundleCreateTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bs-bundle-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testSameNameKeepsExistingTakeAndUsesNewBundle() throws {
        let first = try ProjectBundle.create(in: dir, name: "selftest-1")
        let payload = Data("330 s take".utf8)
        try payload.write(to: first.screenURL)
        try Data("{}".utf8).write(to: first.url.appendingPathComponent("edl.json"))

        let second = try ProjectBundle.create(in: dir, name: "selftest-1")
        let third = try ProjectBundle.create(in: dir, name: "selftest-1")

        XCTAssertEqual(first.url.lastPathComponent, "selftest-1.basestudio")
        XCTAssertEqual(second.url.lastPathComponent, "selftest-1-2.basestudio")
        XCTAssertEqual(third.url.lastPathComponent, "selftest-1-3.basestudio")
        // The earlier take is untouched…
        XCTAssertEqual(try Data(contentsOf: first.screenURL), payload)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.url.appendingPathComponent("edl.json").path))
        // …and the new bundles start empty (no inherited edl.json / failure.json).
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: second.url.path), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: third.url.path), [])
    }

    func testCreatesMissingParentDirectory() throws {
        let nested = dir.appendingPathComponent("a/b", isDirectory: true)
        let b = try ProjectBundle.create(in: nested, name: "take")
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.url.path, isDirectory: &isDir) && isDir.boolValue)
    }
}
