import Foundation
import os

/// File-backed logger for Base Studio.
///
/// Why not just `NSLog` / `os_log`?
/// - Console.app lines vanish across reboots and are awkward to grep when
///   another agent (or future-you) is debugging a recording that happened
///   yesterday. A plain text file under `~/Library/Logs/BaseStudio/` is the
///   one place agents can `cat` / `grep` without privileges.
/// - `os.Logger` still gets every line (so live debugging via `log stream`
///   keeps working), but the file is the source of truth for postmortems.
///
/// Format: `2026-04-30T22:30:54.123Z INFO RecordingSession.swift:98 message`.
/// One log file per day; appended, never truncated.
public enum BSLog {

    public enum Level: String {
        case info = "INFO"
        case warn = "WARN"
        case error = "ERROR"
    }

    public static func info(_ message: @autoclosure () -> String,
                            file: String = #fileID, line: Int = #line) {
        log(.info, message(), file: file, line: line)
    }

    public static func warn(_ message: @autoclosure () -> String,
                            file: String = #fileID, line: Int = #line) {
        log(.warn, message(), file: file, line: line)
    }

    public static func error(_ message: @autoclosure () -> String,
                             file: String = #fileID, line: Int = #line) {
        log(.error, message(), file: file, line: line)
    }

    /// Path to today's log file. Useful for surfacing "open log" in the UI.
    public static var currentLogFileURL: URL {
        sink.currentFileURL()
    }

    /// Directory containing all rotated log files.
    public static var logDirectoryURL: URL {
        sink.directoryURL
    }

    // MARK: - Internals

    private static let sink = FileSink()
    private static let osLog = Logger(subsystem: "com.basestudio.dev", category: "app")

    private static func log(_ level: Level, _ message: String,
                            file: String, line: Int) {
        let shortFile = (file as NSString).lastPathComponent
        let timestamp = ISO8601DateFormatter.shared.string(from: Date())
        let formatted = "\(timestamp) \(level.rawValue) \(shortFile):\(line) \(message)"

        switch level {
        case .info:  osLog.info("\(message, privacy: .public)")
        case .warn:  osLog.warning("\(message, privacy: .public)")
        case .error: osLog.error("\(message, privacy: .public)")
        }
        sink.write(formatted)
    }
}

// MARK: - File sink

private final class FileSink {
    let directoryURL: URL
    private let queue = DispatchQueue(label: "com.basestudio.logger", qos: .utility)
    private var openDay: String = ""
    private var handle: FileHandle?

    init() {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        directoryURL = library.appendingPathComponent("Logs/BaseStudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    func currentFileURL() -> URL {
        directoryURL.appendingPathComponent("base-studio-\(today()).log")
    }

    func write(_ line: String) {
        queue.async { [weak self] in
            guard let self else { return }
            let day = self.today()
            if day != self.openDay {
                self.handle?.closeFile()
                let url = self.directoryURL.appendingPathComponent("base-studio-\(day).log")
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                self.handle = try? FileHandle(forWritingTo: url)
                _ = try? self.handle?.seekToEnd()
                self.openDay = day
            }
            if let data = (line + "\n").data(using: .utf8) {
                try? self.handle?.write(contentsOf: data)
            }
        }
    }

    private func today() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: Date())
    }
}

private extension ISO8601DateFormatter {
    static let shared: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
