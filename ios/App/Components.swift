import SwiftUI

/// v3 card: #131315, R28, 1 px white 6% edge, no shadow.
struct Card<Content: View>: View {
    var padding: CGFloat = Theme.Metric.cardPadding
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Color.card, in: RoundedRectangle(cornerRadius: Theme.Metric.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Metric.radius, style: .continuous).strokeBorder(Theme.Color.edge, lineWidth: 1))
    }
}

/// 44 pt circle with a 1.5 px line icon.
struct IconCircle: View {
    let systemImage: String
    var size: CGFloat = Theme.Metric.iconButton

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.36, weight: .regular))
            .foregroundStyle(Theme.Color.text1)
            .frame(width: size, height: size)
            .background(Theme.Color.button, in: Circle())
            .overlay(Circle().strokeBorder(Theme.Color.edge, lineWidth: 1))
    }
}

struct MarkView: View {
    var size: CGFloat = 36

    var body: some View {
        Image("Mark")
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(Theme.Color.edge, lineWidth: 1))
            .accessibilityHidden(true)
    }
}

struct SectionHeader: View {
    let title: String
    var count: Int? = nil

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            Text(title).font(Theme.Font.section).foregroundStyle(Theme.Color.text2)
            if let count {
                Text("\(count)").font(Theme.Font.count).monospacedDigit().foregroundStyle(Theme.Color.text2)
                    .frame(minWidth: Theme.Space.l, minHeight: Theme.Space.l).padding(.horizontal, Theme.Space.xxs)
                    .background(Theme.Color.button, in: RoundedRectangle(cornerRadius: Theme.Space.s, style: .continuous))
            }
        }
        .padding(.horizontal, Theme.Metric.margin)
    }
}

struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(configuration.isPressed ? Theme.Motion.press : .easeOut(duration: 0.16), value: configuration.isPressed)
    }
}
