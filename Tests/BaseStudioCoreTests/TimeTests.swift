import CoreMedia
import XCTest
@testable import BaseStudioCore

final class TimeTests: XCTestCase {

    func testTimePointRoundTrip() {
        let t = CMTime(value: 12345, timescale: 600)
        let tp = TimePoint(t)
        XCTAssertEqual(tp.cmTime, t)
        XCTAssertEqual(tp.seconds, 12345.0 / 600.0, accuracy: 1e-9)
    }

    func testTimePointCodable() throws {
        let original = TimePoint(value: 999, timescale: 60_000)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TimePoint.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testHostClockMonotonic() {
        let a = HostClock.now()
        let b = HostClock.now()
        XCTAssertGreaterThanOrEqual(b.seconds, a.seconds)
    }
}
