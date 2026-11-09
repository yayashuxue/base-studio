import XCTest
@testable import BaseStudioApp

/// Stop/Restart pressed while a take is starting must not run alongside
/// RecordingSession.start(); it runs once, after start returns.
final class TakeStartGateTests: XCTestCase {

    func testStopWhileStartingIsHeldThenRunsOnce() {
        var g = TakeStartGate()
        g.reset()
        XCTAssertFalse(g.request(.stop), "stop must wait while starting")
        XCTAssertFalse(g.request(.stop), "a second press is not queued twice")
        XCTAssertEqual(g.didStart(), .stop)
        XCTAssertNil(g.didStart(), "handed back exactly once")
        XCTAssertTrue(g.request(.stop), "after start, stop runs immediately")
    }

    func testFirstRequestWins() {
        var g = TakeStartGate()
        g.reset()
        _ = g.request(.restart)
        _ = g.request(.stop)
        XCTAssertEqual(g.didStart(), .restart)
    }

    func testFailedStartDropsTheRequest() {
        var g = TakeStartGate()
        g.reset()
        _ = g.request(.stop)
        g.didFail()
        XCTAssertNil(g.pending)
        XCTAssertFalse(g.started)
    }

    func testNoRequestStartsClean() {
        var g = TakeStartGate()
        g.reset()
        XCTAssertNil(g.didStart())
        XCTAssertTrue(g.request(.restart))
    }
}
