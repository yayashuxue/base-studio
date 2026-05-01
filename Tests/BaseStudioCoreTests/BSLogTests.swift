import BaseStudioCore
import XCTest

final class BSLogTests: XCTestCase {

    func testLogDirectoryUnderLibraryLogs() {
        let dir = BSLog.logDirectoryURL.path
        // The file sink falls back to NSHomeDirectory()/Library if the system
        // can't resolve the user's library; both forms must end in Logs/BaseStudio.
        XCTAssertTrue(dir.hasSuffix("Library/Logs/BaseStudio"), "got \(dir)")
    }

    func testCurrentLogFilePathFormat() {
        let url = BSLog.currentLogFileURL
        XCTAssertEqual(url.deletingLastPathComponent().path, BSLog.logDirectoryURL.path)
        let name = url.lastPathComponent
        // Format: base-studio-YYYYMMDD.log — verify prefix + extension + date width.
        XCTAssertTrue(name.hasPrefix("base-studio-"))
        XCTAssertTrue(name.hasSuffix(".log"))
        let dateField = name
            .replacingOccurrences(of: "base-studio-", with: "")
            .replacingOccurrences(of: ".log", with: "")
        XCTAssertEqual(dateField.count, 8, "expected YYYYMMDD, got \(dateField)")
        XCTAssertNotNil(Int(dateField), "date field should be numeric: \(dateField)")
    }

    func testInfoWriteAppendsToCurrentLogFile() throws {
        let url = BSLog.currentLogFileURL
        let token = "test-token-\(UUID().uuidString.prefix(8))"
        BSLog.info("BSLog test: \(token)")

        // The sink writes asynchronously on a utility queue; give it a moment
        // and then verify our token landed in the file. We tolerate the file
        // not yet existing on a brand-new run by polling briefly.
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if let data = try? Data(contentsOf: url),
               let s = String(data: data, encoding: .utf8),
               s.contains(token) {
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTFail("Did not find token \(token) in \(url.path) within 2s")
    }
}
