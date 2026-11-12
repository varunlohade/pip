import SwiftUI
import UIKit

/// All colors, type, sizes and motion. Direction B2: white ground, painted sky only on onboarding and the top of Home,
/// glowing sky-blue pills, frosted white second pills, white cards with a thin ring shadow. Light only: B2 has no dark version.
enum Theme {
    enum Color {
        // B2 palette (UMBRA.md, previous era): sky, ice, slate and mist greys on white.
        static let sky = SwiftUI.Color(hex: 0x00B3FF)
        static let skyDeep = SwiftUI.Color(hex: 0x0082F3)
        static let skyGlow = SwiftUI.Color(hex: 0x00B3FF).opacity(0x63 / 255)
        /// Text on a sky pill that is quieter than white: the "btw" in "btw → by the way".
        static let skyOnText = SwiftUI.Color(hex: 0xD6F2FF)
        static let ice = SwiftUI.Color(hex: 0xDEF6FF)
        static let iceSoft = SwiftUI.Color(hex: 0xEFF9FF)
        static let navy = SwiftUI.Color(hex: 0x04314D)

        static let bg = SwiftUI.Color.white
        static let card = SwiftUI.Color.white
        static let panel = SwiftUI.Color(hex: 0xFAFAFA)
        /// The ring around cards and frosted pills: a shadow line, not a border.
        static let ring = SwiftUI.Color.black.opacity(0x1A / 255)
        static let edge = ring
        static let chipEdge = ring
        static let button = iceSoft
        static let surface = panel
        static let hairline = SwiftUI.Color(hex: 0xE2E2E2)
        static let text1 = SwiftUI.Color(hex: 0x0B0C0F)
        static let text2 = SwiftUI.Color(hex: 0x5D6C7B)
        static let text3 = SwiftUI.Color(hex: 0x758696)
        /// Something done: "Added", "Saved", a finished step.
        static let success = SwiftUI.Color(hex: 0x1F8A55)
        static let successInk = SwiftUI.Color(hex: 0x1B6E46)
        static let successChip = SwiftUI.Color(hex: 0xDDF3E6)
        static let successEdge = SwiftUI.Color(hex: 0x1F8A55).opacity(0.3)
        /// Something to fix: an error line.
        static let warning = SwiftUI.Color(hex: 0xB0461A)
    }

    /// Inter is not bundled; SF Pro is the closest system face, with tight tracking for headings as in Inter Display.
    enum Font {
        static func ui(_ size: CGFloat, _ weight: SwiftUI.Font.Weight = .regular) -> SwiftUI.Font { .system(size: size, weight: weight) }
        static func mono(_ size: CGFloat) -> SwiftUI.Font { .system(size: size, weight: .medium, design: .monospaced) }

        static let appName = ui(24, .semibold)
        static let display = ui(38, .semibold)
        static let title = ui(32, .semibold)
        static let section = ui(17, .semibold)
        static let cardTitle = ui(17, .semibold)
        static let body = ui(16)
        static let bodyMedium = ui(16, .medium)
        static let label = ui(13)
        static let button = ui(17, .semibold)
        static let chip = ui(15)
        static let count = ui(13, .semibold)
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
        /// The keyboard while the visual explanation panel is open.
        static let visualHeight: CGFloat = 470

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
        /// Inter Display at 38 pt runs about -1.4 pt; 32 pt about -1.1 pt.
        static let display: CGFloat = -1.4
        static let title: CGFloat = -1.1
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
        static let radius: CGFloat = 22
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
