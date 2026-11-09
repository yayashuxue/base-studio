/// Keeps Stop / Restart from running while a take is still starting.
/// The Stop button is on screen before `RecordingSession.start()` returns;
/// stopping then raced the start (stop on recorders not yet running, start
/// carrying on after the UI had failed). A request made while starting is
/// held and handed back once capture is up.
struct TakeStartGate {
    enum EndRequest: Equatable { case stop, restart }

    private(set) var started = false
    private(set) var pending: EndRequest?

    /// New take begins starting.
    mutating func reset() { started = false; pending = nil }

    /// true → run it now. false → held until `didStart()` (first request wins).
    mutating func request(_ r: EndRequest) -> Bool {
        if started { return true }
        if pending == nil { pending = r }
        return false
    }

    /// Capture is up; returns a request held while starting, to run now.
    mutating func didStart() -> EndRequest? {
        started = true
        defer { pending = nil }
        return pending
    }

    /// Start failed: nothing to stop; drop any held request.
    mutating func didFail() { started = false; pending = nil }
}
