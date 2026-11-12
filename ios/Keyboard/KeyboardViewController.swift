import SwiftUI
import UIKit

/// The input view adopts UIInputViewAudioFeedback, so UIDevice.playInputClick follows the user's Keyboard Clicks setting.
final class ClickInputView: UIInputView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}

final class KeyboardViewController: UIInputViewController, TextHost {
    private let model = KeyboardModel()

    override func loadView() {
        let v = ClickInputView(frame: .zero, inputViewStyle: .keyboard)
        v.allowsSelfSizing = true
        inputView = v
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        model.host = self
        let hosting = UIHostingController(rootView: KeyboardView(model: model))
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
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (vc: KeyboardViewController, _) in vc.updateAppearance() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateAppearance()
        model.keyboardAppeared()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        model.keyboardDisappeared()
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
    func insert(_ text: String) { textDocumentProxy.insertText(text) }
    func deleteBackward() { textDocumentProxy.deleteBackward() }
    func nextKeyboard() { advanceToNextInputMode() }
    func playClick() { UIDevice.current.playInputClick() }
}
