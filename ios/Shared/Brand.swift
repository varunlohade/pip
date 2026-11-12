import SwiftUI

// Pip's B2 look, shared by the app and the keyboard: the buddy, the wordmark, sky and frosted pills, ring cards and the cloud sky.
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

/// The glowing sky-blue pill for the one main action: background #00B3FF, glow 0 .7px 30px #00B3FF63, inner white glow.
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
            .overlay(Capsule().strokeBorder(.white.opacity(0.6), lineWidth: 3).blur(radius: 4).clipShape(Capsule()))
            .shadow(color: Theme.Color.skyGlow, radius: 15, y: 0.7)
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

/// The painted sky with soft cumulus clouds that fades to white. Onboarding and the top of Home only.
struct CloudSky: View {
    /// Each cloud: x, y and width in points, and opacity, as in the mocks.
    var clouds: [(x: CGFloat, y: CGFloat, w: CGFloat, o: Double)]

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(stops: [
                .init(color: Color(hex: 0x8FD3FF), location: 0),
                .init(color: Color(hex: 0xB9E4FF), location: 0.40),
                .init(color: Color(hex: 0xE3F5FF), location: 0.72),
                .init(color: .white, location: 1),
            ], startPoint: .top, endPoint: .bottom)
            ForEach(Array(clouds.enumerated()), id: \.offset) { _, c in
                CloudPuff(width: c.w).opacity(c.o).offset(x: c.x, y: c.y)
            }
        }
        .clipped()
        // The clouds melt into the white page instead of ending at the edge of the sky.
        .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.8), .init(color: .clear, location: 1)],
                             startPoint: .top, endPoint: .bottom))
        .accessibilityHidden(true)
    }

    static let onboarding: [(x: CGFloat, y: CGFloat, w: CGFloat, o: Double)] =
        [(250, 96, 130, 0.9), (-40, 128, 120, 0.8), (-70, 330, 240, 1), (220, 300, 230, 1), (70, 380, 260, 1), (-60, 440, 300, 1), (180, 450, 320, 1)]
    static let home: [(x: CGFloat, y: CGFloat, w: CGFloat, o: Double)] =
        [(240, 40, 120, 0.75), (-60, 170, 220, 1), (130, 190, 240, 1), (280, 150, 180, 1), (-20, 240, 260, 1), (200, 250, 280, 1)]
}

/// One cumulus: five round puffs over a flat base, white fading to ice, with a soft blue shadow.
struct CloudPuff: View {
    let width: CGFloat

    var body: some View {
        let parts: [(x: CGFloat, y: CGFloat, r: CGFloat)] = [(0, 0.5, 0.36), (0.16, 0.22, 0.48), (0.42, 0.02, 0.56), (0.68, 0.26, 0.44), (0.84, 0.5, 0.32)]
        let puff = RadialGradient(colors: [.white, .white, Color(hex: 0xE2F2FD)], center: UnitPoint(x: 0.45, y: 0.3), startRadius: 0, endRadius: width * 0.3)
        ZStack(alignment: .topLeading) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, p in
                Circle().fill(puff).frame(width: p.r * width, height: p.r * width).offset(x: p.x * width, y: p.y * width * 0.6)
            }
            RoundedRectangle(cornerRadius: 0.1 * width)
                .fill(LinearGradient(colors: [.white, Color(hex: 0xE4F3FD)], startPoint: .top, endPoint: .bottom))
                .frame(width: width * 0.86, height: 0.2 * width).offset(x: 0.08 * width, y: 0.42 * width)
        }
        .frame(width: width, height: width * 0.62, alignment: .topLeading)
        .blur(radius: 1.2)
        .shadow(color: Color(red: 60 / 255, green: 140 / 255, blue: 200 / 255).opacity(0.18), radius: 5, y: 6)
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
