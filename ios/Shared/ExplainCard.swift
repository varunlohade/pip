import SwiftUI

/// The explain card, in place of the keys (B2): a white ring card with the answer, an example or a few lines,
/// then Back, Show visually and the glowing Insert.
struct ExplainCardView: View {
    @ObservedObject var model: KeyboardModel
    let offer: ExplainOffer
    let palette: Theme.SystemKeyboard.Palette
    typealias M = Theme.SystemKeyboard

    var body: some View {
        VStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                (Text("\u{201C}\(offer.subject)\u{201D}  ").foregroundColor(Theme.Color.skyDeep) + Text(offer.line).foregroundColor(Theme.Color.text1))
                    .font(.system(size: 18, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("explain.line")
                ForEach(Array(details.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.system(size: 15)).foregroundStyle(Theme.Color.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .ringCard(radius: 20)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("explain.card")

            HStack(spacing: 10) {
                Button("Back", action: model.closeExplain).buttonStyle(FrostPill(height: 46, font: .system(size: 16, weight: .semibold)))
                    .accessibilityIdentifier("explain.back")
                if showsVisual {
                    Button("Show visually", action: model.showVisual).buttonStyle(FrostPill(height: 46, font: .system(size: 16, weight: .semibold)))
                        .accessibilityIdentifier("explain.visual")
                }
                Button("Insert", action: model.insertExplain).buttonStyle(SkyPill(height: 46, font: .system(size: 16, weight: .semibold)))
                    .accessibilityIdentifier("explain.insert")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private var details: [String] {
        switch offer {
        case .meaning(let m): ["\u{201C}\(m.example)\u{201D}"]
        case .answer(_, let r): r.body.components(separatedBy: "\n").filter { !$0.isEmpty }
        case .chart, .calc: []
        }
    }

    /// A drawing needs the server. A dictionary term gets none; an answer gets one when the server says it helps.
    private var showsVisual: Bool {
        if case .answer(_, let r) = offer { return r.visual_ok && model.paired }
        return false
    }
}
