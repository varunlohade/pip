import SwiftUI
import UIKit

/// All colors, type, sizes and motion. Tokens follow design/claude/NOTES.md, v3 section.
enum Theme {
    /// Each token has a light and a dark value and follows the system setting.
    /// The dark values follow design/claude/NOTES.md, v3. The light values are Apple-like: near-white bed, grey cards, dark text.
    /// The brand green and amber go a few shades deeper in light so text on them stays readable (≥ 4.5:1).
    enum Color {
        static let bg = dynamic(light: 0xFAFAFB, dark: 0x0C0C0E)
        static let card = dynamic(light: 0xF0F0F2, dark: 0x131315)
        static let edge = dynamic(light: .black.withAlphaComponent(0.07), dark: .white.withAlphaComponent(0.06))
        static let chipEdge = dynamic(light: .black.withAlphaComponent(0.10), dark: .white.withAlphaComponent(0.09))
        static let button = dynamic(light: 0xE8E8EB, dark: 0x1C1C1F)
        static let surface = dynamic(light: 0xF3F3F5, dark: 0x141416)
        static let key = dynamic(light: 0xFFFFFF, dark: 0x2A2A2E)
        static let keyFn = dynamic(light: 0xD5D7DC, dark: 0x1B1B1E)
        static let keyboardBed = dynamic(light: 0xE2E4E7, dark: 0x0F0F11)
        static let hairline = dynamic(light: 0xDEDEE2, dark: 0x2A2A2E)
        static let text1 = dynamic(light: 0x111113, dark: 0xF2F2F4)
        static let text2 = dynamic(light: 0x55555D, dark: 0x9B9BA3)
        static let text3 = dynamic(light: 0x606068, dark: 0x5F5F67)
        static let cents = dynamic(light: 0x8C8C94, dark: 0x55555D)
        static let tick = dynamic(light: 0xD6D6DB, dark: 0x2E2E33)
        static let tickPayment = dynamic(light: 0x3A3A40, dark: 0xD9D9DE)
        static let paid = dynamic(light: 0x276E48, dark: 0x86BFA0)
        static let paidInk = dynamic(light: 0x24653F, dark: 0xB6E0C8)
        static let paidSheet = SwiftUI.Color(hex: 0xB4D2BD)
        static let paidChip = dynamic(light: 0xDDEFE3, dark: 0x1D2F25)
        static let paidChipEdge = dynamic(light: UIColor(red: 39 / 255, green: 110 / 255, blue: 72 / 255, alpha: 0.30),
                                          dark: UIColor(red: 160 / 255, green: 214 / 255, blue: 184 / 255, alpha: 0.22))
        static let paidChipText = dynamic(light: 0x1B3A29, dark: 0xE6F5EC)
        static let due = dynamic(light: 0x855913, dark: 0xD8A75E)
        static let paper = SwiftUI.Color(hex: 0xECEAE4)
        static let ink = SwiftUI.Color(hex: 0x1C1C1F)

        private static func dynamic(light: UInt32, dark: UInt32) -> SwiftUI.Color {
            dynamic(light: UIColor(hex: light), dark: UIColor(hex: dark))
        }
        private static func dynamic(light: UIColor, dark: UIColor) -> SwiftUI.Color {
            SwiftUI.Color(UIColor { $0.userInterfaceStyle == .dark ? dark : light })
        }
    }

    /// App type: Urbanist 400/500/600. Geist Mono only as printed type on paper.
    enum Font {
        static func urbanist(_ size: CGFloat, _ weight: Int = 500) -> SwiftUI.Font {
            .custom(weight >= 600 ? "Urbanist-SemiBold" : weight >= 500 ? "Urbanist-Medium" : "Urbanist-Regular", size: size)
        }
        static func paper(_ size: CGFloat) -> SwiftUI.Font { .custom("GeistMono-Medium", size: size) }

        static let appName = urbanist(24, 600)
        static let hero = urbanist(44, 400).monospacedDigit()
        static let heroSmall = urbanist(24, 400).monospacedDigit()
        static let title = urbanist(24, 600)
        static let cardTitle = urbanist(16, 600)
        static let body = urbanist(16, 500)
        static let section = urbanist(15, 500)
        static let label = urbanist(13, 500)
        static let axis = urbanist(11.5, 500)
        static let count = urbanist(13, 600)
    }

    /// The keyboard copies the iOS 26 system keyboard (measured on the iPhone 17 Pro simulator, 402 pt wide).
    /// Our own look comes later; for now it is a replica, light and dark.
    enum SystemKeyboard {
        struct Palette {
            let bed: SwiftUI.Color, key: SwiftUI.Color, keyPressed: SwiftUI.Color, label: SwiftUI.Color
            let divider: SwiftUI.Color, secondaryLabel: SwiftUI.Color, accent: SwiftUI.Color
        }
        static let light = Palette(bed: SwiftUI.Color(hex: 0xE2E4E7), key: .white, keyPressed: SwiftUI.Color(hex: 0xB9BDC6),
                                   label: .black, divider: SwiftUI.Color(hex: 0xD0D2D7), secondaryLabel: SwiftUI.Color(hex: 0x6E6E73),
                                   accent: SwiftUI.Color(hex: 0x0088FF))
        static let dark = Palette(bed: SwiftUI.Color(hex: 0x171717), key: SwiftUI.Color(hex: 0x3D3D3D), keyPressed: SwiftUI.Color(hex: 0x6A6A6A),
                                  label: .white, divider: SwiftUI.Color(hex: 0x323234), secondaryLabel: SwiftUI.Color(hex: 0x98989D),
                                  accent: SwiftUI.Color(hex: 0x0091FF))

        static let sideInset: CGFloat = 6.5
        static let keyGap: CGFloat = 6
        static let barHeight: CGFloat = 51.33
        static let cornerRadius: CGFloat = 8.5
        static let dividerHeight: CGFloat = 24

        /// Sizes that change with the phone width. Measured against Apple's keyboard in the same text field
        /// (iOS 26.4 simulator, 2026-11-11) at 375, 393, 402 and 440 pt; values between are interpolated.
        struct Sizes {
            let keyHeight: CGFloat, rowGap: CGFloat, bottomInset: CGFloat
            let wideKey: CGFloat      // shift, delete, #+=
            let modeKey: CGFloat      // 123 / ABC, globe
            let returnKey: CGFloat
        }
        static func sizes(for width: CGFloat) -> Sizes {
            func at(_ points: [(CGFloat, CGFloat)]) -> CGFloat {
                guard let first = points.first, let last = points.last else { return 0 }
                if width <= first.0 { return first.1 }
                if width >= last.0 { return last.1 }
                let i = points.firstIndex { $0.0 >= width }!
                let (w0, v0) = points[i - 1], (w1, v1) = points[i]
                return v0 + (v1 - v0) * (width - w0) / (w1 - w0)
            }
            return Sizes(keyHeight: at([(375, 42), (393, 43), (402, 43), (440, 45)]),
                         rowGap: at([(375, 12), (393, 11)]),
                         bottomInset: at([(375, 4.33), (393, 3.33), (402, 3.33), (440, 5)]),
                         wideKey: at([(375, 41.83), (393, 44.16), (402, 45.5), (440, 50.16)]),
                         modeKey: at([(375, 39.83), (402, 43.5), (440, 48.16)]),
                         returnKey: at([(375, 85.83), (402, 93.2), (440, 102.5)]))
        }
        /// This phone, in portrait. The keyboard is always as wide as the screen.
        static let current = sizes(for: UIScreen.main.bounds.width)
        static var keyHeight: CGFloat { current.keyHeight }
        static var rowGap: CGFloat { current.rowGap }
        static var bottomInset: CGFloat { current.bottomInset }
        static var height: CGFloat { barHeight + 4 * keyHeight + 3 * rowGap + bottomInset }

        static let letter = SwiftUI.Font.system(size: 22.5, weight: .regular)
        static let symbol = SwiftUI.Font.system(size: 22.5, weight: .regular)
        static let mode = SwiftUI.Font.system(size: 17, weight: .regular)
        static let smallMode = SwiftUI.Font.system(size: 13, weight: .regular)
        static let icon = SwiftUI.Font.system(size: 18, weight: .regular)
        static let callout = SwiftUI.Font.system(size: 40, weight: .regular)
        static let prediction = SwiftUI.Font.system(size: 17, weight: .regular)
        static let predictionSmall = SwiftUI.Font.system(size: 12, weight: .regular)
    }

    /// The keyboard extension ships no custom fonts, to stay light on memory.
    enum KeyboardFont {
        static let chipKey = SwiftUI.Font.system(size: 15, weight: .semibold)
        static let chipValue = SwiftUI.Font.system(size: 15, weight: .medium).monospacedDigit()
        static let chipText = SwiftUI.Font.system(size: 15, weight: .regular)
        static let hint = SwiftUI.Font.system(size: 10, weight: .medium)
        static let secondary = SwiftUI.Font.system(size: 13, weight: .medium).monospacedDigit()
        static let key = SwiftUI.Font.system(size: 22)
        static let keyFn = SwiftUI.Font.system(size: 15)
    }

    enum Tracking {
        static let appName: CGFloat = -0.4
        static let hero: CGFloat = -1.6
        static let heroSmall: CGFloat = -0.6
    }

    /// Spacing on a 4 pt grid. Use only these steps; one-off offsets only to line up art optically.
    enum Space {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let s: CGFloat = 12
        static let m: CGFloat = 16
        static let l: CGFloat = 24
        static let xl: CGFloat = 32
        static let xxl: CGFloat = 48
        static let xxxl: CGFloat = 64
    }

    enum Metric {
        static let radius: CGFloat = 28
        /// Side gutter for cards: 16 pt, 20 pt on phones 428 pt wide or more.
        static let cardInset: CGFloat = screenWidth >= 428 ? 20 : Space.m
        /// Text outside cards (titles, section headers, plain rows) sits one step in from the cards.
        static let margin: CGFloat = cardInset + Space.xs
        static let cardPadding: CGFloat = Space.m
        /// Gap between cards in a stack, and the extra gap above a new section.
        static let cardGap: CGFloat = Space.s
        static let sectionGap: CGFloat = Space.l
        static let iconButton: CGFloat = 44
        static let rowHeight: CGFloat = 56
        static let chipHeight: CGFloat = 44
        static let primaryButton: CGFloat = 56
        static let secondaryButton: CGFloat = 48
        static let keyRadius: CGFloat = 7
        static let keyHeight: CGFloat = 43
        static let keyGap: CGFloat = 6
        static let rowGap: CGFloat = 12
        static let barHeight: CGFloat = 52
        static var keyboardHeight: CGFloat { barHeight + 4 * keyHeight + 3 * rowGap + 16 }

        private static var screenWidth: CGFloat { UIScreen.main.bounds.width }
    }

    /// Springs from NOTES.md. All motion is interruptible springs on transform and opacity.
    enum Motion {
        static let chipAppear = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.12)
        static let chipStagger = 0.035
        static let chipFlip = Animation.spring(response: 0.62, dampingFraction: 0.74)
        static let press = Animation.easeOut(duration: 0.1)
        static let folderLift = Animation.spring(response: 0.55, dampingFraction: 0.80)
        static let glassSquash = Animation.spring(response: 0.50, dampingFraction: 0.70)
        static let papersFan = Animation.spring(response: 0.52, dampingFraction: 0.68)
        static let papersStagger = 0.045
        static let rowsIn = Animation.easeOut(duration: 0.35)
        static let ravenPath = Animation.timingCurve(0.77, 0, 0.175, 1, duration: 0.6)
        static let stamp = Animation.spring(response: 0.42, dampingFraction: 0.66)
        static let crossfade = Animation.easeOut(duration: 0.2)
        static let onboardingStep = Animation.spring(response: 0.42, dampingFraction: 0.82)
        static let onboardingCheckHold: Duration = .milliseconds(520)
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}
