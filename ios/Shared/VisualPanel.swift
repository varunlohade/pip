import SwiftUI
import WebKit
import os

/// The visual panel, in place of the keys: the tldraw page draws the scene step by step, then Replay, Draw, Copy image, Insert.
/// Plain current theme; restyle here.
struct VisualPanelView: View {
    @ObservedObject var model: KeyboardModel
    let state: VisualState
    let palette: Theme.SystemKeyboard.Palette
    typealias M = Theme.SystemKeyboard

    var body: some View {
        VStack(spacing: M.keyGap) {
            ZStack {
                VisualWebView(model: model, dark: model.isDark)
                    .clipShape(RoundedRectangle(cornerRadius: M.cornerRadius, style: .continuous))
                    .accessibilityIdentifier("visual.canvas")
                if let line = overlayLine {
                    Text(line).font(M.mode).foregroundStyle(palette.secondaryLabel).multilineTextAlignment(.center)
                        .padding(Theme.Space.s)
                        .accessibilityIdentifier("visual.status")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(palette.key, in: RoundedRectangle(cornerRadius: M.cornerRadius, style: .continuous))
            .overlay(alignment: .bottom) {
                if let note = state.note {
                    Text(note).font(M.predictionSmall.weight(.medium)).foregroundStyle(.white)
                        .padding(.horizontal, Theme.Space.s).padding(.vertical, 6)
                        .background(Color.black.opacity(0.75), in: Capsule())
                        .padding(.bottom, Theme.Space.xs)
                        .accessibilityIdentifier("visual.note")
                }
            }
            HStack(spacing: M.keyGap) {
                button("Replay", "arrow.counterclockwise", id: "visual.replay", enabled: drawn, action: model.replayVisual)
                button(state.drawing ? "Move" : "Draw", state.drawing ? "hand.draw" : "pencil.tip", id: "visual.draw", enabled: state.scene != nil, action: model.toggleVisualDraw)
                button("Copy image", "doc.on.doc", id: "visual.copy", enabled: drawn, action: model.exportVisual)
                button("Insert", "text.insert", id: "visual.insert", accent: true, enabled: true, action: model.insertExplain)
            }
        }
        .padding(.horizontal, M.sideInset)
        .padding(.vertical, 4)
    }

    private var drawn: Bool {
        switch state.status {
        case .drawing, .done: true
        default: false
        }
    }

    private var overlayLine: String? {
        switch state.status {
        case .loading: "Drawing \u{201C}\(state.subject)\u{201D}\u{2026}"
        case .failed(let s): s
        default: nil
        }
    }

    private func button(_ title: String, _ icon: String, id: String, accent: Bool = false, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon).font(M.icon)
                Text(title).font(M.predictionSmall).lineLimit(1).minimumScaleFactor(0.7)
            }
            .foregroundStyle(accent ? .white : palette.label)
            .frame(maxWidth: .infinity, minHeight: M.keyHeight, maxHeight: M.keyHeight)
            .background(accent ? palette.accent : palette.key, in: RoundedRectangle(cornerRadius: M.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(title)
        .accessibilityIdentifier(id)
    }
}

/// Hosts the bundled tldraw page (ios/Visual, built from visual/). A content rule blocks every http(s) load, so the page
/// can never reach a network; it talks to the keyboard only through the "pip" message handler.
struct VisualWebView: UIViewRepresentable {
    let model: KeyboardModel
    let dark: Bool

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(WeakHandler(context.coordinator), name: "pip")
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        #if DEBUG
        web.isInspectable = true
        #endif
        context.coordinator.web = web
        context.coordinator.dark = dark
        Coordinator.noNetwork { rules in
            if let rules { config.userContentController.add(rules) }
            guard let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Visual") else {
                context.coordinator.model?.visualFailed("page missing")
                return
            }
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        guard context.coordinator.dark != dark else { return }
        context.coordinator.dark = dark
        context.coordinator.js("pip.theme(\(dark))")
    }

    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "pip")
        web.stopLoading()
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, VisualPage {
        weak var model: KeyboardModel?
        weak var web: WKWebView?
        var dark = false
        private let log = Logger(subsystem: "com.orseliyas.pip", category: "visual")

        init(model: KeyboardModel) { self.model = model }

        private static var rules: WKContentRuleList?
        /// Compiled once per process: block every http and https load from the page.
        static func noNetwork(_ done: @escaping (WKContentRuleList?) -> Void) {
            if let rules { done(rules); return }
            let json = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "pip.visual.nonetwork", encodedContentRuleList: json) { list, _ in
                MainActor.assumeIsolated {
                    rules = list
                    done(list)
                }
            }
        }

        func js(_ code: String) { web?.evaluateJavaScript(code, completionHandler: nil) }

        func play(_ scene: Data) { js("pip.play(\(String(decoding: scene, as: UTF8.self)))") }
        func replay() { js("pip.replay()") }
        func setTool(draw: Bool) { js("pip.tool('\(draw ? "draw" : "hand")')") }
        func exportPNG() { js("pip.export()") }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String, let model else { return }
            switch type {
            case "ready":
                js("pip.theme(\(dark))")
                model.visualPageReady(self)
            case "step":
                model.visualStep(body["n"] as? Int ?? 1, of: body["m"] as? Int ?? 1)
            case "done":
                model.visualDone()
            case "png":
                guard let b64 = body["data"] as? String, let png = Data(base64Encoded: b64) else { return model.visualFailed("bad image") }
                log.notice("PIP_VISUAL png_bytes=\(png.count, privacy: .public)")
                model.visualExported(png)
            case "error":
                log.error("PIP_VISUAL page error \(body["message"] as? String ?? "", privacy: .public)")
                model.visualFailed(body["message"] as? String ?? "")
            default:
                break
            }
        }
    }

    /// WKUserContentController keeps its handler strongly; this keeps the coordinator weakly instead.
    final class WeakHandler: NSObject, WKScriptMessageHandler {
        weak var target: WKScriptMessageHandler?
        init(_ target: WKScriptMessageHandler) { self.target = target }
        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) { target?.userContentController(c, didReceive: m) }
    }
}
