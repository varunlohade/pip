import SwiftUI
import WebKit

/// Home's floating "Ask Pip, or paste text to fix" bar. A word the dictionary knows answers on the phone; a question goes to
/// /v1/explain; anything else is a message to fix (/v1/write/fix). The answer shows in a card above the bar, with Copy.
struct AskBar: View {
    @State private var text = ""
    @State private var answer: Answer?
    @State private var busy = false
    @FocusState private var focused: Bool

    struct Answer: Equatable {
        let title: String
        let body: String
        /// What Copy puts on the pasteboard.
        let copy: String
    }

    var body: some View {
        VStack(spacing: Theme.Space.xs) {
            if let a = answer {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(a.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.Color.text1)
                        Spacer()
                        Button { answer = nil } label: { Image(systemName: "xmark").foregroundStyle(Theme.Color.text3) }
                            .accessibilityLabel("Close")
                    }
                    Text(a.body).font(.system(size: 15)).foregroundStyle(Theme.Color.text2).fixedSize(horizontal: false, vertical: true)
                    Button("Copy") { UIPasteboard.general.string = a.copy }.buttonStyle(IcePill(height: 32))
                }
                .padding(14)
                .ringCard(radius: 20)
                .accessibilityIdentifier("ask.answer")
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            HStack(spacing: 10) {
                Buddy(size: 26)
                TextField("", text: $text, prompt: Text("Ask Pip, or paste text to fix").foregroundStyle(Theme.Color.text3), axis: .vertical)
                    .lineLimit(1...4)
                    .font(.system(size: 16)).foregroundStyle(Theme.Color.text1)
                    .focused($focused)
                    .submitLabel(.send)
                    .onSubmit(ask)
                    .accessibilityIdentifier("ask.field")
                if busy {
                    ProgressView().tint(Theme.Color.sky)
                } else if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button(action: ask) { Image(systemName: "arrow.up").font(.system(size: 15, weight: .bold)).foregroundStyle(.white).frame(width: 32, height: 32).background(SkyFill()) }
                        .accessibilityLabel("Ask")
                        .accessibilityIdentifier("ask.send")
                }
            }
            .padding(.leading, 12).padding(.trailing, 10)
            .frame(minHeight: 56)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous).fill(.white.opacity(0.8))
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(Theme.Color.ring, lineWidth: 0.5))
                    .shadow(color: Color(red: 0, green: 60 / 255, blue: 100 / 255).opacity(0.3), radius: 15, y: 10)
            )
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: answer)
    }

    private func ask() {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !busy else { return }
        focused = false
        // "btw" on its own, or "what does btw mean": the dictionary answers with no network.
        let ask = Explain.detect(q)
        if let term = ask?.kind == .term ? ask?.subject : (q.split(separator: " ").count <= 3 ? q.lowercased() : nil),
           let m = ExplainDictionary.shared.lookup(term) {
            answer = Answer(title: "\u{201C}\(m.term)\u{201D} \(m.meaning)", body: "\u{201C}\(m.example)\u{201D}", copy: m.meaning)
            return
        }
        busy = true
        Task {
            defer { busy = false }
            do {
                if let ask {
                    let r = try await APIClient.shared().explain(ask.question)
                    answer = Answer(title: r.short, body: r.body, copy: r.short)
                } else {
                    let r = try await APIClient.shared().fix(q)
                    answer = r.text == q ? Answer(title: "Looks good \u{2713}", body: q, copy: q) : Answer(title: "Fixed", body: r.text, copy: r.text)
                }
            } catch {
                answer = Answer(title: "That did not work", body: plainLine(error), copy: q)
            }
        }
    }
}

/// Replays a saved drawing in the app: the same bundled drawing page as the keyboard, with the network blocked.
struct ReplaySheet: View {
    let drawing: Drawing

    var body: some View {
        VStack(spacing: Theme.Space.s) {
            Capsule().fill(Theme.Color.hairline).frame(width: 36, height: 5).padding(.top, 8)
            Text(drawing.title).font(Theme.Font.section).foregroundStyle(Theme.Color.text1)
            ReplayWebView(scene: SharedStore.drawingSceneURL(drawing).flatMap { try? Data(contentsOf: $0) })
                .ringCard(radius: 20)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .padding(.horizontal, Theme.Metric.cardInset)
                .padding(.bottom, Theme.Space.m)
                .accessibilityIdentifier("replay.canvas")
        }
        .presentationDetents([.medium, .large])
        .background(Theme.Color.bg)
    }
}

struct ReplayWebView: UIViewRepresentable {
    let scene: Data?

    func makeCoordinator() -> Coordinator { Coordinator(scene: scene) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(VisualWebView.WeakHandler(context.coordinator), name: "pip")
        // Nothing is cached or kept on disk: each open loads the bundled page as shipped.
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .clear
        context.coordinator.web = web
        VisualWebView.Coordinator.noNetwork { rules in
            if let rules { config.userContentController.add(rules) }
            guard let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Visual") else { return }
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler {
        let scene: Data?
        weak var web: WKWebView?
        init(scene: Data?) { self.scene = scene }

        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
            guard let body = m.body as? [String: Any] else { return }
            if body["type"] as? String == "ready", let scene {
                web?.evaluateJavaScript("pip.play(\(String(decoding: scene, as: UTF8.self)))")
            }
        }
    }
}
