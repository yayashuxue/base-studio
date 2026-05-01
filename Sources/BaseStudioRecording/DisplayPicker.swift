import AppKit
import Foundation
import ScreenCaptureKit

public struct DisplayInfo: Identifiable, Hashable, Sendable {
    public let id: UInt32       // SCDisplay.displayID
    public let widthPx: Int
    public let heightPx: Int
    public let isMain: Bool
    public let label: String    // user-facing name

    public init(id: UInt32, widthPx: Int, heightPx: Int, isMain: Bool, label: String) {
        self.id = id
        self.widthPx = widthPx
        self.heightPx = heightPx
        self.isMain = isMain
        self.label = label
    }
}

@available(macOS 13.0, *)
public enum DisplayPicker {
    public static func availableDisplays() async throws -> [DisplayInfo] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        let mainID = (NSScreen.main?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                      as? NSNumber)?.uint32Value
        return content.displays.map { d in
            let nsScreen = NSScreen.screens.first { s in
                (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                    as? NSNumber)?.uint32Value == d.displayID
            }
            let label = nsScreen?.localizedName ?? "Display \(d.displayID)"
            return DisplayInfo(
                id: d.displayID,
                widthPx: d.width, heightPx: d.height,
                isMain: d.displayID == mainID,
                label: label
            )
        }
    }
}
