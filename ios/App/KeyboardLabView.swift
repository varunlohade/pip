import SwiftUI

/// Debug screen: the same KeyboardView and KeyboardModel as the extension, fed by a local string.
/// It proves the network path without the system keyboard switch.
struct KeyboardLabView: View {
    @StateObject private var lab = LabHost()
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Text(lab.text.isEmpty ? "Type with the keyboard below" : lab.text)
                    .font(Theme.Font.body)
                    .foregroundStyle(lab.text.isEmpty ? Theme.Color.text3 : Theme.Color.text1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Metric.margin)
                    .accessibilityIdentifier("lab.text")
            }
            if let ms = lab.model.lastLatencyMs {
                Text("keystroke → chip \(ms) ms").font(Theme.Font.label).foregroundStyle(Theme.Color.text3).padding(.bottom, Theme.Space.xs)
            }
            KeyboardView(model: lab.model)
                .background((lab.model.isDark ? Theme.SystemKeyboard.dark : Theme.SystemKeyboard.light).bed.ignoresSafeArea(edges: .bottom))
        }
        .background(Theme.Color.bg)
        .navigationTitle("Keyboard Lab")
        .onAppear { lab.model.isDark = colorScheme == .dark; lab.model.keyboardAppeared() }
        .onChange(of: colorScheme) { _, scheme in lab.model.isDark = scheme == .dark }
    }
}

@MainActor
final class LabHost: ObservableObject, TextHost {
    @Published var text = ""
    let model = KeyboardModel()
    private var bag: Any?

    init() {
        model.host = self
        bag = model.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    var contextBeforeInput: String? { text }
    /// DEBUG "-labOffline": no Full Access, so no network; used to test the keys without model calls.
    var hasFullAccess: Bool { !ProcessInfo.processInfo.arguments.contains("-labOffline") }
    var needsGlobeKey: Bool { false }
    var returnKeyType: UIReturnKeyType { .default }
    var autocapitalization: UITextAutocapitalizationType { .sentences }
    var enablesReturnKeyAutomatically: Bool { false }
    func playClick() {}
    func insert(_ s: String) { text += s }
    func deleteBackward() { if !text.isEmpty { text.removeLast() } }
    func nextKeyboard() {}
}
