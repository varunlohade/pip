import SwiftUI

/// The first screen (B2-1): the sky, the wordmark, the buddy turning a typed plan into a calendar event, the headline and one sky button.
/// Positions follow the 390 x 844 mock and scale with the screen height.
struct OnboardingHero: View {
    let onAdd: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var answered = false

    var body: some View {
        GeometryReader { geo in
            let k = geo.size.height / 844
            ZStack(alignment: .top) {
                Theme.Color.bg
                SkyGradient().frame(height: 560 * k).frame(maxWidth: .infinity)
                Wordmark(size: 30).padding(.top, 70 * k)
                Buddy(size: 90).padding(.top, 170 * k)
                VStack(alignment: .leading, spacing: 12 * k) {
                    Text("dinner with Ana friday 7pm").foregroundColor(Theme.Color.text1)
                        .font(.system(size: 15))
                        .padding(.horizontal, 16).frame(height: 40)
                        .background(FrostFill())
                    Text("Add to calendar").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 18).frame(height: 40)
                        .background(SkyFill())
                        .padding(.leading, 112)
                        .scaleEffect(answered || reduceMotion ? 1 : 0.6, anchor: .topLeading)
                        .opacity(answered || reduceMotion ? 1 : 0)
                }
                .padding(.top, 300 * k)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 58)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Type dinner with Ana friday 7pm, and Pip offers: Add to calendar")
                VStack(spacing: 0) {
                    // "A helper / in your keyboard", broken where the mock breaks it.
                    Text(AppConfig.tagline.replacingOccurrences(of: " in your", with: "\nin your"))
                        .font(Theme.Font.display).tracking(Theme.Tracking.display).lineSpacing(0)
                        .foregroundStyle(Theme.Color.text1).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(AppConfig.tagline)
                        .accessibilityIdentifier("hero.title")
                    Text(AppConfig.taglineLine)
                        .font(.system(size: 16.5)).lineSpacing(4).foregroundStyle(Theme.Color.text2).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16)
                        .padding(.top, 14 * k)
                    Spacer(minLength: 16)
                    Button("Add \(AppConfig.displayName) to my keyboard", action: onAdd)
                        .buttonStyle(SkyPill())
                        .accessibilityIdentifier("hero.add")
                }
                .padding(.top, 540 * k)
                .padding(.horizontal, 28)
                .padding(.bottom, max(geo.safeAreaInsets.bottom, 20) + 34 * k)
            }
            .ignoresSafeArea()
        }
        .task {
            try? await Task.sleep(for: .milliseconds(600))
            withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) { answered = true }
        }
    }
}
