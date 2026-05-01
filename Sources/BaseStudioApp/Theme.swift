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
public enum BS {

    // MARK: - Color tokens

    public enum Color {
        // Backgrounds — warm-dark gradient stops.
        public static let bgTop      = SwiftUI.Color(hex: 0x0E0F12)
        public static let bgBottom   = SwiftUI.Color(hex: 0x08090B)

        // Surfaces (cards / panels). Layered: surface < surfaceRaised < surfaceLit.
        public static let surface       = SwiftUI.Color(hex: 0x16181D)
        public static let surfaceRaised = SwiftUI.Color(hex: 0x1C1F26)
        public static let surfaceLit    = SwiftUI.Color(hex: 0x232730)

        // 1pt inner highlight applied to the top edge of surfaces — makes
        // them read as "lit from above" rather than "stamped on".
        public static let topHighlight = SwiftUI.Color.white.opacity(0.06)
        public static let hairline     = SwiftUI.Color.white.opacity(0.06)
        public static let divider      = SwiftUI.Color.white.opacity(0.04)

        // Text. Three tiers — never use raw white.
        public static let textPrimary   = SwiftUI.Color(hex: 0xF5F5F7)
        public static let textSecondary = SwiftUI.Color(hex: 0x9C9DA1)
        public static let textTertiary  = SwiftUI.Color(hex: 0x5A5C61)

        // Accent. ONE warm orange accent — used sparingly for primary action.
        public static let accent        = SwiftUI.Color(hex: 0xF0A93B)
        public static let accentMuted   = SwiftUI.Color(hex: 0x8C6420)

        // Recording red. Reserved for the recording state and stop affordance.
        public static let recordingRed  = SwiftUI.Color(hex: 0xFF3B30)
        public static let recordingGlow = SwiftUI.Color(hex: 0xFF3B30).opacity(0.35)

        // Status colours — used in indicator pills and meters.
        public static let statusOk      = SwiftUI.Color(hex: 0x6BCB77)
        public static let statusWarn    = SwiftUI.Color(hex: 0xF0A93B)
        public static let statusError   = SwiftUI.Color(hex: 0xFF3B30)

        // Audio meters.
        public static let meterMic      = SwiftUI.Color(hex: 0x6BCB77)
        public static let meterSystem   = SwiftUI.Color(hex: 0x4DA3FF)
    }

    // MARK: - Typography

    public enum Font {
        /// Big page-level titles (e.g. "Base Studio" on Home).
        public static let display = SwiftUI.Font.system(size: 30, weight: .semibold).leading(.tight)
        /// Smaller display — e.g. modal headers.
        public static let title   = SwiftUI.Font.system(size: 22, weight: .semibold)
        /// Section headers in the inspector — uppercase, tracked.
        public static let section = SwiftUI.Font.system(size: 11, weight: .semibold).leading(.tight)
        /// Default UI label text.
        public static let label   = SwiftUI.Font.system(size: 13, weight: .regular)
        /// Slightly bolder label for selected / active state.
        public static let labelStrong = SwiftUI.Font.system(size: 13, weight: .medium)
        /// Caption — secondary metadata.
        public static let caption = SwiftUI.Font.system(size: 11, weight: .regular)
        /// Monospaced numerics — timers, dimensions, bitrates, time codes.
        public static let mono    = SwiftUI.Font.system(size: 12, weight: .medium, design: .monospaced)
        public static let monoLg  = SwiftUI.Font.system(size: 16, weight: .semibold, design: .monospaced)
    }

    // MARK: - Spacing

    public enum Space {
        public static let micro:   CGFloat = 4
        public static let tight:   CGFloat = 8
        public static let snug:    CGFloat = 12
        public static let regular: CGFloat = 16
        public static let loose:   CGFloat = 20
        public static let section: CGFloat = 24
        public static let xl:      CGFloat = 32
    }

    // MARK: - Corner radii

    public enum Radius {
        public static let chip:   CGFloat = 6
        public static let pill:   CGFloat = 999
        public static let card:   CGFloat = 12
        public static let panel:  CGFloat = 16
        public static let dock:   CGFloat = 18
    }

    // MARK: - Animation curves

    public enum Motion {
        /// Standard spring for state transitions.
        public static let spring = SwiftUI.Animation.spring(response: 0.32, dampingFraction: 0.85)
        /// Snappier spring for hover / press.
        public static let snap   = SwiftUI.Animation.spring(response: 0.18, dampingFraction: 0.9)
        /// Eased fade for panels appearing / disappearing.
        public static let fade   = SwiftUI.Animation.easeOut(duration: 0.20)
        /// Recording-dot breathing pulse.
        public static let breath = SwiftUI.Animation.easeInOut(duration: 0.7).repeatForever(autoreverses: true)
    }

    // MARK: - Shadows

    public enum Shadow {
        /// Subtle low-key shadow for dock / floating panels.
        public static func panel<V: View>(_ view: V) -> some View {
            view.shadow(color: SwiftUI.Color.black.opacity(0.45), radius: 24, x: 0, y: 8)
        }
        /// Recording-red glow for the floating dock.
        public static func recordingGlow<V: View>(_ view: V) -> some View {
            view.shadow(color: BS.Color.recordingGlow, radius: 18, x: 0, y: 0)
        }
    }
}

// MARK: - Reusable view modifiers

public extension View {
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
                            .strokeBorder(
                                LinearGradient(
                                    colors: [BS.Color.topHighlight, .clear],
                                    startPoint: .top,
                                    endPoint: .center
                                ),
                                lineWidth: 1
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(BS.Color.hairline, lineWidth: 1)
                    )
            )
    }

    /// The app-wide warm-dark gradient backdrop.
    func bsBackground() -> some View {
        self.background(
            LinearGradient(
                colors: [BS.Color.bgTop, BS.Color.bgBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
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
}

// MARK: - Color hex initialiser

public extension SwiftUI.Color {
    /// Initialize from a 24-bit hex value. `Color(hex: 0x16181D)`.
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >>  8) & 0xFF) / 255.0
        let b = Double( hex        & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}
