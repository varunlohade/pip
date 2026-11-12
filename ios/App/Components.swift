import SwiftUI

/// B2 card: white, radius 22, the thin ring shadow, no border.
struct Card<Content: View>: View {
    var padding: CGFloat = Theme.Metric.cardPadding
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .ringCard()
    }
}

/// A 40 pt frosted circle with a line icon, as the profile button in the B2 mocks.
struct IconCircle: View {
    let systemImage: String
    var size: CGFloat = 40

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.4, weight: .regular))
            .foregroundStyle(Theme.Color.text1)
            .frame(width: size, height: size)
            .background(Circle().fill(.white.opacity(0.72)).background(.ultraThinMaterial, in: Circle()))
            .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1))
            .shadow(color: .black.opacity(0.06), radius: 1.5, y: 1)
    }
}

/// Pip's mark is the buddy itself.
struct MarkView: View {
    var size: CGFloat = 36

    var body: some View {
        Buddy(size: size)
    }
}

/// "Words", "From your chats": 17 pt semibold ink, flush with the cards.
struct SectionHeader: View {
    let title: String
    var count: Int? = nil

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            Text(title).font(Theme.Font.section).foregroundStyle(Theme.Color.text1)
            if let count {
                Text("\(count)").font(Theme.Font.count).monospacedDigit().foregroundStyle(Theme.Color.skyDeep)
                    .frame(minWidth: Theme.Space.l, minHeight: Theme.Space.l).padding(.horizontal, Theme.Space.xxs)
                    .background(Theme.Color.ice, in: Capsule())
            }
        }
        .padding(.horizontal, Theme.Metric.cardInset)
    }
}

struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(configuration.isPressed ? Theme.Motion.press : .easeOut(duration: 0.16), value: configuration.isPressed)
    }
}
