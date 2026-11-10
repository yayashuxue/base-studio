import AppKit
import BaseStudioCore
import Foundation

/// Picks up a newer build staged beside the running app (dev builds:
/// `BS_OUT_DIR=build/staging scripts/build-app.sh debug`) and swaps to it —
/// so julie never has to quit and tell anyone. When the app is idle (not
/// recording or exporting) and has been in the background for a minute, it
/// restarts itself into the new build; while she's using it, it only offers
/// "Restart" (UpdateBanner) and never interrupts.
@MainActor
final class AppUpdater: ObservableObject {
    @Published private(set) var updateReady = false

    /// Return true only when restarting now loses nothing (no recording,
    /// countdown, finalizing or export in flight).
    var isIdle: () -> Bool = { false }

    private var timer: Timer?
    private var inactiveSince: Date?
    private var observers: [NSObjectProtocol] = []
    private let installedApp = Bundle.main.bundleURL
    private var stagedApp: URL {
        installedApp.deletingLastPathComponent().appendingPathComponent("staging/\(installedApp.lastPathComponent)")
    }
    private static let idleBackgroundSeconds: TimeInterval = 60

    func start() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.inactiveSince = Date() }
        })
        observers.append(nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.inactiveSince = nil }
        })
        if !NSApp.isActive { inactiveSince = Date() }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
        check()
    }

    static func buildID(of app: URL) -> String? {
        (NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any])?["BSBuildID"] as? String
    }

    private func check() {
        guard let staged = Self.buildID(of: stagedApp), staged != Self.buildID(of: installedApp),
              FileManager.default.isExecutableFile(atPath: stagedApp.appendingPathComponent("Contents/MacOS/BaseStudio").path)
        else { updateReady = false; return }
        updateReady = true
        if let since = inactiveSince, Date().timeIntervalSince(since) > Self.idleBackgroundSeconds, isIdle() {
            BSLog.info("update: idle in background — restarting into \(staged)")
            restartIntoUpdate(reopenInBackground: true)
        }
    }

    /// Quit, move the staged build into place, open it again. Done by a
    /// detached shell so the swap happens after this process has exited.
    func restartIntoUpdate(reopenInBackground: Bool = false) {
        guard isIdle() else { return }
        let pid = ProcessInfo.processInfo.processIdentifier
        let app = installedApp.path, staged = stagedApp.path
        let old = installedApp.deletingLastPathComponent().appendingPathComponent("staging/previous.app").path
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        rm -rf '\(old)'
        mv '\(app)' '\(old)' && mv '\(staged)' '\(app)' || mv '\(old)' '\(app)'
        open \(reopenInBackground ? "-g " : "")'\(app)'
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        do {
            try p.run()
            BSLog.info("update: swapping to the staged build after exit")
            NSApp.terminate(nil)
        } catch {
            BSLog.error("update: couldn't start the swap: \(error)")
        }
    }
}
