import SwiftUI

/// The explain card, in place of the keys: the meaning or answer, an example, then Insert. Plain current theme; restyle here.
struct ExplainCardView: View {
    @ObservedObject var model: KeyboardModel
    let offer: ExplainOffer
    let palette: Theme.SystemKeyboard.Palette
    typealias M = Theme.SystemKeyboard

    var body: some View {
        VStack(spacing: M.keyGap) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                (Text("\u{201C}\(offer.subject)\u{201D}  ").foregroundColor(palette.accent) + Text(offer.line).foregroundColor(palette.label))
                    .font(M.mode.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("explain.line")
                ForEach(Array(details.enumerated()), id: \.offset) { _, line in
                    Text(line).font(M.predictionSmall).foregroundStyle(palette.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.s).padding(.vertical, Theme.Space.xs)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(palette.key, in: RoundedRectangle(cornerRadius: M.cornerRadius, style: .continuous))
            .accessibilityIdentifier("explain.card")

            HStack(spacing: M.keyGap) {
                button("Back", id: "explain.back", action: model.closeExplain)
                if showsVisual { button("Show visually", id: "explain.visual", action: model.showVisual) }
                button("Insert", id: "explain.insert", accent: true, action: model.insertExplain)
            }
        }
        .padding(.horizontal, M.sideInset)
        .padding(.vertical, 4)
    }

    private var details: [String] {
        switch offer {
        case .meaning(let m): ["\u{201C}\(m.example)\u{201D}"]
        case .answer(_, let r): r.body.components(separatedBy: "\n").filter { !$0.isEmpty }
        case .chart: []
        }
    }

    /// A drawing needs the server. A dictionary term gets none; an answer gets one when the server says it helps.
    private var showsVisual: Bool {
        if case .answer(_, let r) = offer { return r.visual_ok && model.paired }
        return false
    }

    private func button(_ title: String, id: String, accent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(M.mode).foregroundStyle(accent ? .white : palette.label)
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: M.keyHeight, maxHeight: M.keyHeight)
                .background(accent ? palette.accent : palette.key, in: RoundedRectangle(cornerRadius: M.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}
