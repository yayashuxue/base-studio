import AppKit
import SwiftUI

/// Centralised design tokens for Base Studio's "Studio Console" aesthetic —
/// a warm-dark, instrumented look inspired by Teenage Engineering / Linear /
/// Screen Studio. The whole app should reach into this file (and only this
/// file) for colours, typography, radii, and motion. If a value isn't here,
/// add it — don't sprinkle one-off literals across views.
///
/// Principles:
///  - Warm dark, not pure black. The bg is `#0E0F12` → `#08090B`, never `Color.black`.
///  - One accent at a time. Recording-red is reserved for the recording state.
///  - Soft luminance edges. Surfaces have a 1pt top inner highlight so they
///    feel lit from above, not pasted on flat.
///  - Generous padding. 24pt section, 16pt control, 8pt micro.
///  - Restrained motion. 0.18s spring transitions; nothing bouncy.
enum BS {

    // MARK: - Color tokens

    enum Color {
        // Raw 24-bit hex constants — single source of truth so SwiftUI
        // `Color` and AppKit `NSColor` accessors below stay in sync. Only
        // additive members (no opacity tweaks) belong here; derived shades
        // live as separate `static let`s.
        private static let bgTopHex:      UInt32 = 0x0E0F12
        private static let bgBottomHex:   UInt32 = 0x08090B
        private static let surfaceHex:        UInt32 = 0x16181D
        private static let surfaceRaisedHex:  UInt32 = 0x1C1F26
        private static let surfaceLitHex:     UInt32 = 0x232730
        private static let textPrimaryHex:    UInt32 = 0xF5F5F7
        private static let textSecondaryHex:  UInt32 = 0x9C9DA1
        private static let textTertiaryHex:   UInt32 = 0x5A5C61
        private static let accentHex:         UInt32 = 0xF0A93B
        private static let accentMutedHex:    UInt32 = 0x8C6420
        private static let onAccentHex:       UInt32 = 0x1A1102
        private static let recordingRedHex:   UInt32 = 0xFF3B30
        private static let statusOkHex:       UInt32 = 0x6BCB77
        private static let meterSystemHex:    UInt32 = 0x4DA3FF

        // Backgrounds — warm-dark gradient stops.
        static let bgTop      = SwiftUI.Color(hex: bgTopHex)
        static let bgBottom   = SwiftUI.Color(hex: bgBottomHex)

        // Surfaces (cards / panels). Layered: surface < surfaceRaised < surfaceLit.
        static let surface       = SwiftUI.Color(hex: surfaceHex)
        static let surfaceRaised = SwiftUI.Color(hex: surfaceRaisedHex)
        static let surfaceLit    = SwiftUI.Color(hex: surfaceLitHex)

        // 1pt inner highlight applied to the top edge of surfaces — makes
        // them read as "lit from above" rather than "stamped on".
        static let topHighlight = SwiftUI.Color.white.opacity(0.06)
        static let hairline     = SwiftUI.Color.white.opacity(0.06)
        static let divider      = SwiftUI.Color.white.opacity(0.04)

        // Text. Three tiers — never use raw white.
        static let textPrimary   = SwiftUI.Color(hex: textPrimaryHex)
        static let textSecondary = SwiftUI.Color(hex: textSecondaryHex)
        static let textTertiary  = SwiftUI.Color(hex: textTertiaryHex)

        // Accent. ONE warm orange accent — used sparingly for primary action.
        static let accent        = SwiftUI.Color(hex: accentHex)
        static let accentMuted   = SwiftUI.Color(hex: accentMutedHex)
        /// Foreground colour for text/icons drawn on top of `accent` —
        /// warm near-black so amber stays legible without going pure black.
        static let onAccent      = SwiftUI.Color(hex: onAccentHex)

        // Recording red. Reserved for the recording state and stop affordance.
        static let recordingRed  = SwiftUI.Color(hex: recordingRedHex)
        static let recordingGlow = SwiftUI.Color(hex: recordingRedHex).opacity(0.35)

        // Status colours — used in indicator pills and meters.
        static let statusOk      = SwiftUI.Color(hex: statusOkHex)
        static let statusWarn    = SwiftUI.Color(hex: accentHex)
        static let statusError   = SwiftUI.Color(hex: recordingRedHex)

        // Audio meters.
        static let meterMic      = SwiftUI.Color(hex: statusOkHex)
        static let meterSystem   = SwiftUI.Color(hex: meterSystemHex)

        // AppKit bridges — same hex constants, returned as NSColor for use
        // in `RecordingPanel` / `MenuBarController` etc. Keep this list 1:1
        // with the SwiftUI tokens above so there is exactly one source of
        // truth for the palette.
        enum NS {
            static let recordingRed  = NSColor(hex: recordingRedHex)
            /// Slight hover lift over `recordingRed` — used by the floating
            /// dock's Stop button on mouse-enter.
            static let recordingHot  = NSColor(srgbRed: 1.00, green: 0.36, blue: 0.32, alpha: 1.0)
            static let recordingGlow = NSColor(hex: recordingRedHex, alpha: 0.40)
            static let textPrimary   = NSColor(hex: textPrimaryHex)
            static let meterMic      = NSColor(hex: statusOkHex)
            static let meterSystem   = NSColor(hex: meterSystemHex)
        }

        // Pre-computed gradients. SwiftUI re-allocates inline `LinearGradient`
        // values on every body re-eval; hoist common ones so views just
        // reference them.
        static let bgGradient = LinearGradient(
            colors: [bgTop, bgBottom],
            startPoint: .top, endPoint: .bottom
        )
        static let accentGradient = LinearGradient(
            colors: [accent, accent.opacity(0.78)],
            startPoint: .top, endPoint: .bottom
        )
        static let topHighlightGradient = LinearGradient(
            colors: [topHighlight, .clear],
            startPoint: .top, endPoint: .center
        )
    }

    // MARK: - Typography

    enum Font {
        /// Big page-level titles (e.g. "Base Studio" on Home).
        static let display = SwiftUI.Font.system(size: 30, weight: .semibold).leading(.tight)
        /// Smaller display — e.g. modal headers.
        static let title   = SwiftUI.Font.system(size: 22, weight: .semibold)
        /// Section headers in the inspector — uppercase, tracked.
        static let section = SwiftUI.Font.system(size: 11, weight: .semibold).leading(.tight)
        /// Small icon paired with a `bsSectionHeader` — the leading glyph
        /// before the uppercase title.
        static let sectionIcon = SwiftUI.Font.system(size: 10, weight: .semibold)
        /// Default UI label text.
        static let label   = SwiftUI.Font.system(size: 13, weight: .regular)
        /// Slightly bolder label for selected / active state.
        static let labelStrong = SwiftUI.Font.system(size: 13, weight: .medium)
        /// Caption — secondary metadata.
        static let caption = SwiftUI.Font.system(size: 11, weight: .regular)
        /// Monospaced numerics — timers, dimensions, bitrates, time codes.
        static let mono    = SwiftUI.Font.system(size: 12, weight: .medium, design: .monospaced)
        static let monoLg  = SwiftUI.Font.system(size: 16, weight: .semibold, design: .monospaced)
    }

    // MARK: - Spacing

    enum Space {
        static let micro:   CGFloat = 4
        /// Inner gap inside a chip — between an icon and its label, or between
        /// two segmented buttons. The "8 - 2" / "4 + 2" arithmetic that used
        /// to litter call sites collapses to this token.
        static let gap:     CGFloat = 6
        static let tight:   CGFloat = 8
        static let snug:    CGFloat = 12
        static let regular: CGFloat = 16
        static let loose:   CGFloat = 20
        static let section: CGFloat = 24
        static let xl:      CGFloat = 32
    }

    // MARK: - Corner radii

    enum Radius {
        static let chip:   CGFloat = 6
        static let pill:   CGFloat = 999
        static let card:   CGFloat = 12
        static let panel:  CGFloat = 16
        static let dock:   CGFloat = 18
    }

    // MARK: - Animation curves

    enum Motion {
        /// Standard spring for state transitions.
        static let spring = SwiftUI.Animation.spring(response: 0.32, dampingFraction: 0.85)
        /// Snappier spring for hover / press.
        static let snap   = SwiftUI.Animation.spring(response: 0.18, dampingFraction: 0.9)
        /// Eased fade for panels appearing / disappearing.
        static let fade   = SwiftUI.Animation.easeOut(duration: 0.20)
        /// Recording-dot breathing pulse.
        static let breath = SwiftUI.Animation.easeInOut(duration: 0.7).repeatForever(autoreverses: true)
    }

    // MARK: - Formatting

    enum Format {
        /// `m:ss` elapsed time — used by every Stop/timer surface (recording
        /// dock, menu bar, scrubber). Single source of truth so the format
        /// stays consistent if it ever needs to grow an hours field.
        static func mmss(_ totalSec: Int) -> String {
            let s = max(0, totalSec)
            return String(format: "%d:%02d", s / 60, s % 60)
        }
        /// Convenience overload for `Double` seconds — clamps to non-negative
        /// before flooring.
        static func mmss(_ seconds: Double) -> String {
            mmss(Int(seconds))
        }
    }
}

// MARK: - Reusable view modifiers

extension View {
    /// Apply the standard Base Studio surface treatment: raised dark fill +
    /// 1pt top highlight + subtle hairline border. Use on every "card".
    func bsSurface(radius: CGFloat = BS.Radius.card, raised: Bool = false) -> some View {
        let fill = raised ? BS.Color.surfaceRaised : BS.Color.surface
        return self
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(fill)
                    .overlay(
                        // top highlight — 1px line at top edge, fading
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(BS.Color.topHighlightGradient, lineWidth: 1)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(BS.Color.hairline, lineWidth: 1)
                    )
            )
    }

    /// The app-wide warm-dark gradient backdrop.
    func bsBackground() -> some View {
        self.background(BS.Color.bgGradient.ignoresSafeArea())
    }

    /// Section header in the inspector. Use as the first child of each
    /// inspector section's VStack.
    func bsSectionHeader() -> some View {
        self
            .font(BS.Font.section)
            .tracking(1.2)
            .foregroundStyle(BS.Color.textTertiary)
            .textCase(.uppercase)
    }

    /// Capsule pill background — accent fill + ring when on, surface fill +
    /// hairline when off. Use on Buttons that act as binary toggles.
    func bsSelectablePill(isOn: Bool) -> some View {
        self
            .background(
                Capsule(style: .continuous)
                    .fill(isOn ? BS.Color.accent.opacity(0.18) : BS.Color.surface)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        isOn ? BS.Color.accent.opacity(0.55) : BS.Color.hairline,
                        lineWidth: 1
                    )
            )
    }

    /// Primary "go" button background — amber gradient + 1pt top highlight.
    /// Use on the Record / Export / Generate-Captions affordances. Pair with
    /// `.foregroundStyle(BS.Color.onAccent)` so text reads as warm near-black
    /// on amber.
    func bsAccentButton(radius: CGFloat = BS.Radius.chip) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(BS.Color.accentGradient)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(BS.Color.topHighlight, lineWidth: 1)
            )
    }

    /// Rounded-rect tile background — accent fill + ring when on, surface
    /// fill + hairline when off. Use for segmented canvas tiles, grid
    /// pickers, etc.
    func bsSelectableTile(isOn: Bool, radius: CGFloat = BS.Radius.chip) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(isOn ? BS.Color.accent.opacity(0.18) : BS.Color.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        isOn ? BS.Color.accent.opacity(0.55) : BS.Color.hairline,
                        lineWidth: 1
                    )
            )
    }
}

// MARK: - Shared shapes

/// 1pt rule painted in `BS.Color.hairline`. Use as a horizontal divider
/// (`BSHairline()`) or vertical (`BSHairline(axis: .vertical, length: 18)`).
struct BSHairline: View {
    enum Axis { case horizontal, vertical }
    var axis: Axis = .horizontal
    var length: CGFloat? = nil

    var body: some View {
        switch axis {
        case .horizontal:
            Rectangle().fill(BS.Color.hairline).frame(height: 1)
        case .vertical:
            Rectangle().fill(BS.Color.hairline).frame(width: 1, height: length)
        }
    }
}

// MARK: - Color hex initialiser

extension SwiftUI.Color {
    /// Initialize from a 24-bit hex value. `Color(hex: 0x16181D)`.
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >>  8) & 0xFF) / 255.0
        let b = Double( hex        & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}

extension NSColor {
    /// Mirror of `SwiftUI.Color(hex:)` for AppKit-side palette use. Same
    /// 24-bit hex layout, sRGB colour space.
    convenience init(hex: UInt32, alpha: CGFloat = 1.0) {
        let r = CGFloat((hex >> 16) & 0xFF) / 255.0
        let g = CGFloat((hex >>  8) & 0xFF) / 255.0
        let b = CGFloat( hex        & 0xFF) / 255.0
        self.init(srgbRed: r, green: g, blue: b, alpha: alpha)
    }
}
