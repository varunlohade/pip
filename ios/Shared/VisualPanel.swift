import SwiftUI
import WebKit
import os

/// The visual panel, in place of the keys (B2-4): a white ring canvas where the Excalidraw page draws the scene with the buddy
/// leading the pen; pen, eraser and undo on the canvas; the step dashes and what the step says; then Send and Insert.
struct VisualPanelView: View {
    @ObservedObject var model: KeyboardModel
    let state: VisualState
    let palette: Theme.SystemKeyboard.Palette
    typealias M = Theme.SystemKeyboard

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topTrailing) {
                VisualWebView(model: model, dark: false)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .accessibilityIdentifier("visual.canvas")
                if let line = overlayLine {
                    Text(line).font(.system(size: 15)).foregroundStyle(Theme.Color.text2).multilineTextAlignment(.center)
                        .padding(Theme.Space.s).frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("visual.status")
                }
                if state.scene != nil { tools.padding(8) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ringCard(radius: 20)
            .overlay(alignment: .bottom) {
                if let note = state.note {
                    Text(note).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                        .padding(.horizontal, Theme.Space.s).padding(.vertical, 6)
                        .background(Theme.Color.navy.opacity(0.85), in: Capsule())
                        .padding(.bottom, Theme.Space.xs)
                        .accessibilityIdentifier("visual.note")
                }
            }
            stepLine
            buttons
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    /// Pen, eraser and undo, top right on the canvas, as in the mock. The tool in use is a sky square.
    private var tools: some View {
        HStack(spacing: 2) {
            tool("pencil", .draw, id: "visual.draw", label: "Draw")
            tool("eraser", .eraser, id: "visual.eraser", label: "Erase")
            iconButton("arrow.uturn.backward", id: "visual.undo", label: "Undo", action: model.undoVisual)
            iconButton("arrow.uturn.forward", id: "visual.redo", label: "Redo", action: model.redoVisual)
            iconButton("arrow.counterclockwise", id: "visual.replay", label: "Replay", action: model.replayVisual)
            voiceButton
        }
        .padding(3)
        .background(.white, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 0.5).shadow(color: .black.opacity(0.08), radius: 3, y: 2)
    }

    private func tool(_ icon: String, _ t: VisualState.Tool, id: String, label: String) -> some View {
        let on = state.tool == t
        return Button { model.selectVisualTool(t) } label: {
            Image(systemName: icon).font(.system(size: 14, weight: .medium)).foregroundStyle(on ? .white : Color(hex: 0x3A3A3C))
                .frame(width: 30, height: 30)
                .background(on ? Theme.Color.skyDeep : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier(id)
    }

    /// "Play with voice" / "Stop voice": a speaker that turns sky while Pip talks. Nothing plays without this tap.
    private var voiceButton: some View {
        Button(action: model.toggleVoice) {
            Image(systemName: state.voice ? "speaker.wave.2.fill" : "speaker.wave.2").font(.system(size: 14, weight: .medium))
                .foregroundStyle(state.voice ? .white : Color(hex: 0x3A3A3C))
                .frame(width: 30, height: 30)
                .background(state.voice ? Theme.Color.skyDeep : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!drawn)
        .opacity(drawn ? 1 : 0.4)
        .accessibilityLabel(state.voice ? "Stop voice" : "Play with voice")
        .accessibilityIdentifier("visual.voice")
    }

    private func iconButton(_ icon: String, id: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 14, weight: .medium)).foregroundStyle(Color(hex: 0x3A3A3C)).frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .disabled(!drawn)
        .opacity(drawn ? 1 : 0.4)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    /// "Step 3 of 4" with its dashes, then what that step says.
    @ViewBuilder private var stepLine: some View {
        switch state.status {
        case .drawing(let n, let m):
            VStack(alignment: .leading, spacing: 6) {
                StepDashes(current: n, total: m)
                if let say = state.say { Text(say).font(.system(size: 15)).foregroundStyle(Theme.Color.text1).lineLimit(2) }
            }
            .padding(.horizontal, 4)
            .accessibilityIdentifier("visual.step")
        case .done(let m):
            VStack(alignment: .leading, spacing: 6) {
                StepDashes(current: m, total: m)
                if let say = state.say { Text(say).font(.system(size: 15)).foregroundStyle(Theme.Color.text1).lineLimit(2) }
            }
            .padding(.horizontal, 4)
        default:
            EmptyView()
        }
    }

    /// Send (frosted) and Insert (the glowing sky pill). Send opens the two ways to send.
    @ViewBuilder private var buttons: some View {
        HStack(spacing: 10) {
            if state.exporting {
                Button("Send as image") { model.sendVisual(.image) }.buttonStyle(FrostPill(height: 46, font: .system(size: 15, weight: .semibold)))
                    .accessibilityIdentifier("visual.send.image")
                Button("Send as link") { model.sendVisual(.link) }.buttonStyle(FrostPill(height: 46, font: .system(size: 15, weight: .semibold)))
                    .accessibilityIdentifier("visual.send.link")
                Button { model.toggleExport() } label: { Image(systemName: "xmark").font(.system(size: 14, weight: .semibold)) }
                    .buttonStyle(FrostPill(height: 46, fullWidth: false))
                    .accessibilityLabel("Back")
                    .accessibilityIdentifier("visual.export.back")
            } else {
                Button("Send", action: model.toggleExport).buttonStyle(FrostPill(height: 46, font: .system(size: 16, weight: .semibold)))
                    .disabled(!drawn || state.sending != nil).opacity(drawn ? 1 : 0.5)
                    .accessibilityIdentifier("visual.export")
                Button("Insert", action: model.insertExplain).buttonStyle(SkyPill(height: 46, font: .system(size: 16, weight: .semibold)))
                    .accessibilityIdentifier("visual.insert")
            }
        }
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
}

/// Hosts the bundled Excalidraw page (ios/Visual, built from visual/). A content rule blocks every http(s) load, so the page
/// can never reach a network; it talks to the keyboard only through the "pip" message handler.
struct VisualWebView: UIViewRepresentable {
    let model: KeyboardModel
    let dark: Bool

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(WeakHandler(context.coordinator), name: "pip")
        // Nothing is cached or kept on disk: each open loads the bundled page as shipped.
        config.websiteDataStore = .nonPersistent()
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
        func setTool(_ tool: VisualState.Tool) { js("pip.tool('\(tool.rawValue)')") }
        func undo() { js("pip.undo()") }
        func redo() { js("pip.redo()") }
        func setVoice(_ on: Bool) { js("pip.voice(\(on))") }
        func next() { js("pip.next()") }
        func exportPNG() { js("pip.export()") }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String, let model else { return }
            switch type {
            case "ready":
                js("pip.theme(\(dark))")
                model.visualPageReady(self)
            case "step":
                model.visualStep(body["n"] as? Int ?? 1, of: body["m"] as? Int ?? 1, say: body["say"] as? String)
            case "stepDrawn":
                model.visualStepDrawn(body["n"] as? Int ?? 0)
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
