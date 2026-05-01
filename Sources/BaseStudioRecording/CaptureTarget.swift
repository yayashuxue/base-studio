import AppKit
import Foundation
import ScreenCaptureKit

/// What ScreenCaptureKit should record. A display (full or excluding our own
/// windows), or a single application window pinned to its current frame.
public enum CaptureTarget: Hashable, Sendable {
    case display(UInt32)              // SCDisplay.displayID
    case window(UInt32)               // SCWindow.windowID
}

public struct WindowInfo: Identifiable, Hashable, Sendable {
    public let id: UInt32             // SCWindow.windowID
    public let appName: String
    public let title: String
    public let widthPx: Int
    public let heightPx: Int

    public var label: String {
        title.isEmpty ? appName : "\(appName) — \(title)"
    }
}

public struct CaptureCatalog: Sendable {
    public let displays: [DisplayInfo]
    public let windows: [WindowInfo]

    public init(displays: [DisplayInfo] = [], windows: [WindowInfo] = []) {
        self.displays = displays
        self.windows = windows
    }
}

@available(macOS 13.0, *)
public enum CapturePicker {
    /// Returns the list of recordable displays + visible windows. Filters out
    /// tiny/system windows and our own app's windows so the picker stays tidy.
    public static func availableTargets() async throws -> CaptureCatalog {
        // false = include desktop wallpaper windows (otherwise SCK throws -3801 on capture).
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        let mainID = (NSScreen.main?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                      as? NSNumber)?.uint32Value
        let displays: [DisplayInfo] = content.displays.map { d in
            let nsScreen = NSScreen.screens.first { s in
                (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                    as? NSNumber)?.uint32Value == d.displayID
            }
            let label = nsScreen?.localizedName ?? "Display \(d.displayID)"
            return DisplayInfo(
                id: d.displayID, widthPx: d.width, heightPx: d.height,
                isMain: d.displayID == mainID, label: label
            )
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let windows: [WindowInfo] = content.windows
            .filter { w in
                guard let app = w.owningApplication else { return false }
                if app.processID == ownPID { return false }
                if w.frame.width < 200 || w.frame.height < 150 { return false }
                let appName = app.applicationName
                if appName == "Window Server" || appName == "WindowManager" { return false }
                return true
            }
            .map { w in
                WindowInfo(
                    id: w.windowID,
                    appName: w.owningApplication?.applicationName ?? "Unknown",
                    title: w.title ?? "",
                    widthPx: Int(w.frame.width),
                    heightPx: Int(w.frame.height)
                )
            }

        return CaptureCatalog(displays: displays, windows: windows)
    }
}
