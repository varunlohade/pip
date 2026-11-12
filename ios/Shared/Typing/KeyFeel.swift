import CoreGraphics
import UIKit

/// What kind of text the field wants, from its keyboardType and textContentType. It picks the layout and
/// whether autocorrect and word slots run.
enum FieldKind: Equatable {
    enum Pad: Equatable { case number, decimal, phone }
    case text, email, url, numbers
    case digits(Pad)

    init(keyboardType: UIKeyboardType, contentType: UITextContentType?) {
        if contentType == .oneTimeCode { self = .digits(.number); return }
        switch keyboardType {
        case .numberPad, .asciiCapableNumberPad: self = .digits(.number)
        case .decimalPad: self = .digits(.decimal)
        case .phonePad: self = .digits(.phone)
        case .numbersAndPunctuation, .namePhonePad: self = .numbers
        case .emailAddress: self = .email
        case .URL: self = .url
        default:
            if contentType == .emailAddress { self = .email }
            else if contentType == .URL { self = .url }
            else { self = .text }
        }
    }

    var layout: KeyLayout {
        switch self {
        case .digits: .digits
        case .numbers: .numbers
        default: .letters
        }
    }

    /// Space fixes typos only in plain text. Codes, emails and links stay exactly as typed.
    var autocorrects: Bool { self == .text || self == .numbers }
    /// The word slots show only in plain text.
    var wordSlots: Bool { self == .text }
    /// The two keys beside space: "@ ." for email, ". /" for a link.
    var spaceKeys: [String] {
        switch self {
        case .email: ["@", "."]
        case .url: [".", "/"]
        default: []
        }
    }
}

/// The letters a held key offers, lowercase. The model shows them with the shift state applied.
enum Accents {
    static let table: [String: [String]] = [
        "a": ["à", "á", "â", "ä", "æ", "ã", "å", "ā"],
        "e": ["è", "é", "ê", "ë", "ē", "ė", "ę"],
        "i": ["î", "ï", "í", "ī", "į", "ì"],
        "o": ["ô", "ö", "ò", "ó", "œ", "ø", "ō", "õ"],
        "u": ["û", "ü", "ù", "ú", "ū"],
        "n": ["ñ", "ń"],
        "c": ["ç", "ć", "č"],
        "s": ["ß", "ś", "š"],
        "y": ["ÿ"],
        "z": ["ž", "ź", "ż"],
        "l": ["ł"],
    ]

    static func options(_ letter: String) -> [String] { table[letter.lowercased()] ?? [] }
}

/// The accent popup over a held letter: one cell per accent, in keyboard coordinates.
struct AccentPopup: Equatable {
    let touch: ObjectIdentifier
    let keyID: String
    let options: [String]
    let cells: [CGRect]
    var selected: Int

    /// Cells in a row above the key, kept inside the keyboard's width and below its top edge.
    static func cells(key: CGRect, count: Int, width: CGFloat) -> [CGRect] {
        let w = key.width + 4, h = key.height + 4, pad: CGFloat = 4
        let total = CGFloat(count) * w + 2 * pad
        let x = min(max(key.minX - pad, 2), max(2, width - total - 2)) + pad
        let y = max(2, key.minY - h - 8)
        return (0..<count).map { CGRect(x: x + CGFloat($0) * w, y: y, width: w, height: h) }
    }

    /// The cell under the finger's x, or the nearest end.
    static func index(_ x: CGFloat, _ cells: [CGRect]) -> Int {
        guard let first = cells.first else { return 0 }
        return min(max(Int((x - first.minX) / first.width), 0), cells.count - 1)
    }
}

/// The three word slots: as typed, what space would put in, and the next best word; or next-word guesses after a space.
struct WordRow: Equatable {
    var slots: [Predictions.Slot] = []
    /// True while a word is half typed. Then the slots win over chips.
    var midWord = false

    struct Input: Sendable {
        let before: String
        let kept: Set<String>
        /// Each letter tap's likeliest keys in the word, or nil when some letter came another way.
        let taps: [[TouchDecoder.Candidate]]?
        let autocorrects: Bool
        let next: NextWord
    }

    /// Pure, so it runs off the main thread. Uses the spell checker and, when loaded, the language model.
    static func compute(_ i: Input, model: LanguageModel?) -> WordRow {
        guard let typed = Predictions.typedWord(i.before) else {
            return WordRow(slots: i.next.guesses(i.before).map { Predictions.Slot(title: $0, word: $0) }, midWord: false)
        }
        let lower = typed.lowercased()
        let decode: ((String) -> String?)? = model.map { m in { TouchDecoder.correctWord($0, taps: i.taps, model: m) } }
        let fix = i.autocorrects ? FixCheck.autocorrect(i.before, kept: i.kept, decode: decode)?.fixed : nil
        let completions = model?.completions(lower, limit: 3) ?? []
        return WordRow(slots: Predictions.slots(typed: typed, correction: fix, completions: completions, learned: i.kept), midWord: true)
    }
}

extension TouchDecoder.Candidate: @unchecked Sendable {}
extension NextWord: @unchecked Sendable {}

enum HapticStrength { case light, medium }

/// The key taps the phone plays. Tests pass a spy.
@MainActor
protocol KeyHaptics: AnyObject {
    func prepare()
    func tap(_ strength: HapticStrength)
}

/// UIKit's impact generators, kept prepared so the first tap after a pause is not late.
@MainActor
final class SystemHaptics: KeyHaptics {
    private let light = UIImpactFeedbackGenerator(style: .light)
    private let medium = UIImpactFeedbackGenerator(style: .medium)

    func prepare() { light.prepare(); medium.prepare() }

    func tap(_ strength: HapticStrength) {
        let g = strength == .light ? light : medium
        g.impactOccurred()
        g.prepare()
    }
}
