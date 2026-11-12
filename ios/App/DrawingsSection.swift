import SwiftUI

/// Home's "Your drawings": visual explanations exported from the keyboard, newest first. Plain current theme; restyle here.
struct DrawingsSection: View {
    let drawings: [Drawing]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader(title: "Your drawings", count: drawings.count).padding(.leading, 8)
            ScrollView(.horizontal) {
                HStack(spacing: Theme.Space.s) {
                    ForEach(drawings) { d in
                        if let url = SharedStore.drawingURL(d), let image = UIImage(contentsOfFile: url.path) {
                            ShareLink(item: Image(uiImage: image), preview: SharePreview(d.title, image: Image(uiImage: image))) {
                                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                                    Image(uiImage: image).resizable().scaledToFit()
                                        .frame(width: 180, height: 112)
                                        .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    Text(d.title).font(Theme.Font.label).foregroundStyle(Theme.Color.text2).lineLimit(1)
                                }
                                .frame(width: 180)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("home.drawing")
                        }
                    }
                }
                .padding(.horizontal, Theme.Metric.cardInset + 8)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.top, Theme.Metric.sectionGap - Theme.Metric.cardGap)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.drawings")
    }
}
