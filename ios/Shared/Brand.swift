import SwiftUI

// Pip's B2 look, shared by the app and the keyboard: the buddy, the wordmark, sky and frosted pills, ring cards and the sky gradient.
// Values come from the B2 mocks (pip-design/src/pip.html, style E).

/// Pip's buddy: a sky-blue teardrop whose tip is a pen nib, with two white eyes. Drawn as a vector, never a bitmap.
struct Buddy: View {
    var size: CGFloat = 30
    /// The tip's angle: -42 sits up and to the left, as on the bar; -135 points the tip back down a stroke, as on the canvas.
    var rotation: Double = -42
    var color: Color = Theme.Color.sky

    var body: some View {
        ZStack {
            BuddyShape().fill(color).rotationEffect(.degrees(rotation), anchor: UnitPoint(x: 16 / 32, y: 19 / 32))
            BuddyEyes().fill(.white)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The teardrop in a 32 x 32 box: a point at (16, 1.8) that flows into a circle of radius 12 around (16, 19).
struct BuddyShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 32
        let p = { (x: CGFloat, y: CGFloat) in CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        path.move(to: p(16, 1.8))
        path.addCurve(to: p(26.4, 13.3), control1: p(17.6, 7.2), control2: p(22.6, 9.4))
        // The long way round the bottom, from the right shoulder to the left one.
        let a0 = atan2(13.3 - 19, 26.4 - 16), a1 = atan2(13.3 - 19, 5.6 - 16) + 2 * .pi
        for i in 1...48 {
            let a = a0 + (a1 - a0) * Double(i) / 48
            path.addLine(to: p(16 + 12 * cos(a), 19 + 12 * sin(a)))
        }
        path.addCurve(to: p(16, 1.8), control1: p(9.4, 9.4), control2: p(14.4, 7.2))
        path.closeSubpath()
        return path
    }
}

struct BuddyEyes: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 32
        var path = Path()
        for cx in [13.0, 19.0] {
            path.addEllipse(in: CGRect(x: rect.minX + (cx - 1.55) * s, y: rect.minY + (19.6 - 2.25) * s, width: 3.1 * s, height: 4.5 * s))
        }
        return path
    }
}

/// The "pip" wordmark: a dotless i whose dot is the buddy.
struct Wordmark: View {
    var size: CGFloat = 30

    var body: some View {
        HStack(spacing: -size * 0.05) {
            Text("p")
            Text("\u{0131}").overlay(alignment: .top) {
                Buddy(size: size * 0.31, rotation: -30).offset(x: size * 0.015, y: size * 0.10)
            }
            Text("p")
        }
        .font(.system(size: size, weight: .semibold))
        .foregroundStyle(Theme.Color.text1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("pip")
    }
}

/// The sky-blue pill for the one main action: a flat #00B3FF fill, no glow.
struct SkyPill: ButtonStyle {
    var height: CGFloat = 54
    var font: Font = Theme.Font.button
    var fullWidth = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(font)
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, height * 0.4)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: height, maxHeight: height)
            .background(SkyFill())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// The sky pill's paint, for chips that are not buttons.
struct SkyFill: View {
    var body: some View {
        Capsule().fill(Theme.Color.sky)
    }
}

/// The white second pill: frosted on the sky, a ring on white.
struct FrostPill: ButtonStyle {
    var height: CGFloat = 54
    var font: Font = Theme.Font.button
    var fullWidth = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(font)
            .foregroundStyle(Theme.Color.text1)
            .lineLimit(1)
            .padding(.horizontal, height * 0.4)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: height, maxHeight: height)
            .background(FrostFill())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

struct FrostFill: View {
    var body: some View {
        Capsule().fill(.white.opacity(0.72))
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.Color.ring, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.06), radius: 1.5, y: 1)
    }
}

/// The ice chip: #DEF6FF with deep-sky text, for words and secondary actions.
struct IcePill: ButtonStyle {
    var height: CGFloat = 36

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Theme.Color.skyDeep)
            .padding(.horizontal, 16)
            .frame(height: height)
            .background(Theme.Color.ice, in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

extension View {
    /// A white card with the B2 ring shadow (0 0 0 1px #0000001a, 0 1px 3px #0000001a) and no border.
    func ringCard(radius: CGFloat = Theme.Metric.radius) -> some View {
        background(
            RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.Color.card)
                .shadow(color: .black.opacity(0.1), radius: 1.5, y: 1)
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.Color.ring, lineWidth: 0.5))
        )
    }
}

/// The painted sky that fades to the page. Onboarding and the top of Home only.
struct SkyGradient: View {
    var body: some View {
        LinearGradient(stops: [
            .init(color: Theme.Color.skyTop, location: 0),
            .init(color: Theme.Color.skyMid, location: 0.40),
            .init(color: Theme.Color.skyLow, location: 0.72),
            .init(color: Theme.Color.bg, location: 1),
        ], startPoint: .top, endPoint: .bottom)
        .accessibilityHidden(true)
    }
}

/// "Step 3 of 4": one short dash per step, sky for the steps drawn so far.
struct StepDashes: View {
    let current: Int
    let total: Int

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(1...max(total, 1), id: \.self) { i in
                    Capsule().fill(i <= current ? Theme.Color.sky : Color(hex: 0xB9C6D0)).frame(width: 22, height: 4)
                }
            }
            Text("Step \(current) of \(total)").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.Color.text2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current) of \(total)")
    }
}
