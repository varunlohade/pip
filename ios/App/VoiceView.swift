import SwiftUI
import UIKit

/// Settings → Voice: pick the voice Pip explains with, and how fast and high it speaks. A sample plays only on its button.
struct VoiceView: View {
    static let sampleLine = "Hi, I'm Pip. Let me draw that out for you."

    @State private var choice = VoiceChoice.load(SharedStore.defaults)
    @State private var speaker: SystemSpeaker?
    private let voices = VoiceInfo.installedEnglish.sorted { ($0.quality.rawValue, $0.name) > ($1.quality.rawValue, $1.name) }

    private var selectedID: String? {
        let lang = Locale.preferredLanguages.first(where: { $0.hasPrefix("en") }) ?? "en-US"
        return voices.first(where: { $0.id == choice.voiceID })?.id ?? VoiceChoice.best(voices, lang: lang)?.id
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metric.cardGap) {
                Text("Voice").font(Theme.Font.title).tracking(Theme.Tracking.title).foregroundStyle(Theme.Color.text1)
                Card {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        slider("Speed", value: $choice.rate, in: 0.42...0.62)
                        slider("Pitch", value: $choice.pitch, in: 0.85...1.3)
                        Button("Reset") { choice.rate = VoiceChoice.defaultRate; choice.pitch = VoiceChoice.defaultPitch }
                            .font(Theme.Font.label).accessibilityIdentifier("voice.reset")
                    }
                }
                VStack(spacing: 0) { ForEach(voices) { row($0) } }.ringCard()
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text("For the best voices, download Ava or Zoe (Premium) in iPhone Settings → Accessibility → Spoken Content → Voices")
                        .font(Theme.Font.label).foregroundStyle(Theme.Color.text2).fixedSize(horizontal: false, vertical: true)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .buttonStyle(FrostPill()).accessibilityIdentifier("voice.openSettings")
                }
            }
            .padding(Theme.Metric.cardInset)
        }
        .background(Theme.Color.bg.ignoresSafeArea())
        .onChange(of: choice) { _, c in c.save(SharedStore.defaults) }
        .onDisappear { speaker?.stop() }
    }

    private func slider(_ title: String, value: Binding<Float>, in range: ClosedRange<Float>) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            Text(title).font(Theme.Font.label).foregroundStyle(Theme.Color.text2)
            Slider(value: value, in: range).tint(Theme.Color.sky).accessibilityIdentifier("voice.\(title.lowercased())")
        }
    }

    private func row(_ v: VoiceInfo) -> some View {
        HStack(spacing: Theme.Space.s) {
            Button { choice.voiceID = v.id } label: {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: v.id == selectedID ? "checkmark.circle.fill" : "circle").foregroundStyle(Theme.Color.sky)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(v.baseName).font(Theme.Font.cardTitle).foregroundStyle(Theme.Color.text1)
                        Text("\(v.qualityBadge) · \(v.accent)").font(Theme.Font.label).foregroundStyle(Theme.Color.text2)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button("Play sample") {
                let s = speaker ?? SystemSpeaker()
                speaker = s
                var c = choice
                c.voiceID = v.id
                s.speak(Self.sampleLine, choice: c)
            }
            .font(Theme.Font.label).accessibilityIdentifier("voice.sample.\(v.baseName)")
        }
        .padding(.horizontal, Theme.Metric.cardInset).frame(minHeight: 56)
    }
}
