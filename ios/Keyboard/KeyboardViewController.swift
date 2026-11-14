import Combine
import SwiftUI
import UIKit

/// The input view adopts UIInputViewAudioFeedback, so UIDevice.playInputClick follows the user's Keyboard Clicks setting.
final class ClickInputView: UIInputView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}

final class KeyboardViewController: UIInputViewController, TextHost {
    private var model = KeyboardModel()
    private var hosting: UIHostingController<KeyboardView>?
    private var heightConstraint: NSLayoutConstraint?
    private var bag: AnyCancellable?

    override func loadView() {
        let v = ClickInputView(frame: .zero, inputViewStyle: .keyboard)
        v.allowsSelfSizing = true
        inputView = v
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        SharedStore.dropSecretsFromAnEarlierInstall()
        let hosting = UIHostingController(rootView: KeyboardView(model: model))
        self.hosting = hosting
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        hosting.view.backgroundColor = .clear
        let height = hosting.view.heightAnchor.constraint(equalToConstant: Theme.SystemKeyboard.height)
        addChild(hosting)
        view.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            height,
        ])
        hosting.didMove(toParent: self)
        heightConstraint = height
        attach(model)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (vc: KeyboardViewController, _) in vc.updateAppearance() }
    }

    /// Wires a model to this controller and its view.
    private func attach(_ m: KeyboardModel) {
        model = m
        m.host = self
        hosting?.rootView = KeyboardView(model: m)
        // The visual panel and the calendar need more room than the keys; the input view follows the model's height.
        // @Published sends before the property changes, so the height comes from the new value.
        // The pay card takes the calendar's height.
        bag = m.$explainPanel.combineLatest(m.$calendar.map { $0 != nil }.removeDuplicates(), m.$payPanel.map { $0 != nil }.removeDuplicates())
            .sink { [weak self] panel, calendarOpen, payOpen in
                self?.heightConstraint?.constant = KeyboardModel.height(panel: panel, calendarOpen: calendarOpen || payOpen)
            }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // The app wiped the phone since the last appearance: throw the old model away and build a new one.
        if let fresh = model.replacementIfAccountChanged() { attach(fresh) }
        updateAppearance()
        model.keyboardAppeared()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        model.keyboardDisappeared()
    }

    /// A keyboard is killed near its memory limit, so on a warning it drops the caches that reload by themselves.
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        model.releaseCaches()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        updateAppearance()
        model.textChanged()
    }

    /// The field's keyboardAppearance wins; .default follows the system light/dark setting.
    private func updateAppearance() {
        switch textDocumentProxy.keyboardAppearance ?? .default {
        case .dark: model.isDark = true
        case .light: model.isDark = false
        default: model.isDark = traitCollection.userInterfaceStyle == .dark
        }
    }

    // MARK: TextHost

    var contextBeforeInput: String? { textDocumentProxy.documentContextBeforeInput }
    var needsGlobeKey: Bool { needsInputModeSwitchKey }
    var returnKeyType: UIReturnKeyType { textDocumentProxy.returnKeyType ?? .default }
    var autocapitalization: UITextAutocapitalizationType { textDocumentProxy.autocapitalizationType ?? .sentences }
    var enablesReturnKeyAutomatically: Bool { textDocumentProxy.enablesReturnKeyAutomatically ?? false }
    var contextAfterInput: String? { textDocumentProxy.documentContextAfterInput }
    var keyboardType: UIKeyboardType { textDocumentProxy.keyboardType ?? .default }
    var textContentType: UITextContentType? { textDocumentProxy.textContentType ?? nil }
    var autocorrection: UITextAutocorrectionType { textDocumentProxy.autocorrectionType ?? .default }
    func insert(_ text: String) { textDocumentProxy.insertText(text) }
    func deleteBackward() { textDocumentProxy.deleteBackward() }
    func adjustCursor(by offset: Int) { textDocumentProxy.adjustTextPosition(byCharacterOffset: offset) }
    func nextKeyboard() { advanceToNextInputMode() }
    func playClick() { UIDevice.current.playInputClick() }

    /// Keyboards have no API to open an app. This walks the responder chain to the host's UIApplication and calls its
    /// open(_:options:completionHandler:) by selector. If Apple closes that path, it returns false and the bar says
    /// "Open Pip to approve"; the app then finds the payment in the App Group when it opens.
    func open(_ url: URL) -> Bool {
        let sel = NSSelectorFromString("openURL:options:completionHandler:")
        var r: UIResponder? = self
        while let cur = r {
            if cur.isKind(of: NSClassFromString("UIApplication") ?? NSNull.self), cur.responds(to: sel), let imp = cur.method(for: sel) {
                typealias Open = @convention(c) (AnyObject, Selector, URL, [String: Any], ((Bool) -> Void)?) -> Void
                unsafeBitCast(imp, to: Open.self)(cur, sel, url, [:], nil)
                return true
            }
            r = cur.next
        }
        return false
    }
}
