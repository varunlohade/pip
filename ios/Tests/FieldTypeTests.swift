import XCTest
@testable import Pip

/// The field's type picks the layout, the keys beside space and whether autocorrect runs. Return waits for text when asked.
@MainActor
final class FieldTypeTests: XCTestCase {
    private var host: FakeHost!
    private var model: KeyboardModel!

    override func setUp() async throws {
        host = FakeHost()
        host.autocapitalization = .none
        model = KeyboardModel(deps: .fake(api: FakeAPI()))
        model.host = host
    }

    override func tearDown() async throws {
        model.keyboardDisappeared()
        model = nil
    }

    private var keys: [KeyCap] { KeyboardGeometry.keys(layout: model.layout, width: 390, globe: false, currency: "$", field: model.field) }
    private func tap(_ id: String) { model.activate(keys.first { $0.id == id || $0.kind == .char(id) }!) }

    func testTheKindFollowsKeyboardTypeAndContentType() {
        XCTAssertEqual(FieldKind(keyboardType: .numberPad, contentType: nil), .digits(.number))
        XCTAssertEqual(FieldKind(keyboardType: .asciiCapableNumberPad, contentType: nil), .digits(.number))
        XCTAssertEqual(FieldKind(keyboardType: .decimalPad, contentType: nil), .digits(.decimal))
        XCTAssertEqual(FieldKind(keyboardType: .phonePad, contentType: nil), .digits(.phone))
        XCTAssertEqual(FieldKind(keyboardType: .default, contentType: .oneTimeCode), .digits(.number))
        XCTAssertEqual(FieldKind(keyboardType: .numbersAndPunctuation, contentType: nil), .numbers)
        XCTAssertEqual(FieldKind(keyboardType: .emailAddress, contentType: nil), .email)
        XCTAssertEqual(FieldKind(keyboardType: .default, contentType: .emailAddress), .email)
        XCTAssertEqual(FieldKind(keyboardType: .URL, contentType: nil), .url)
        XCTAssertEqual(FieldKind(keyboardType: .default, contentType: nil), .text)
        XCTAssertEqual(FieldKind(keyboardType: .twitter, contentType: nil), .text)
    }

    func testNumberAndCodeFieldsGetTheDigitPad() {
        for (type, content) in [(UIKeyboardType.numberPad, nil), (.default, UITextContentType.oneTimeCode), (.decimalPad, nil)] {
            host.keyboardType = type
            host.textContentType = content
            model.keyboardAppeared()
            XCTAssertEqual(model.layout, .digits)
            let chars = keys.compactMap { if case .char(let c) = $0.kind { c } else { nil } }
            XCTAssertTrue(chars.allSatisfy { $0.allSatisfy { $0.isNumber || $0 == "." } }, "\(chars)")
            XCTAssertEqual(Set(chars).intersection(Set("0123456789".map(String.init))).count, 10)
        }
        host.keyboardType = .default
        host.textContentType = nil
        model.textChanged()
        XCTAssertEqual(model.layout, .letters, "a plain field gets the letters back")
    }

    func testACodeIsTypedExactlyAndGetsNoWordSlots() async {
        host.textContentType = .oneTimeCode
        model.keyboardAppeared()
        for d in "482916" { tap(String(d)) }
        XCTAssertEqual(host.text, "482916")
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.words, WordRow())
    }

    func testEmailAndLinkFieldsGetTheirKeysBesideSpaceAndNoAutocorrect() {
        host.keyboardType = .emailAddress
        model.keyboardAppeared()
        XCTAssertNotNil(keys.first { $0.id == "k.3.@" })
        XCTAssertNotNil(keys.first { $0.id == "k.3.." })
        let space = keys.first { $0.kind == .space }!, at = keys.first { $0.id == "k.3.@" }!
        XCTAssertLessThan(space.frame.maxX, at.frame.minX)
        for c in "teh" { tap(String(c)) }
        tap("space")
        XCTAssertEqual(host.text, "teh ")

        host.keyboardType = .URL
        model.textChanged()
        XCTAssertNotNil(keys.first { $0.id == "k.3.." })
        XCTAssertNotNil(keys.first { $0.id == "k.3./" })
        host.text = ""
        for c in "teh" { tap(String(c)) }
        tap(".")
        XCTAssertEqual(host.text, "teh.")
    }

    func testReturnWaitsForTextWhenTheFieldAsks() {
        host.enablesReturnKeyAutomatically = true
        model.keyboardAppeared()
        XCTAssertFalse(model.returnEnabled)
        tap("return")
        XCTAssertEqual(host.text, "")
        tap("h")
        XCTAssertTrue(model.returnEnabled)
        tap("return")
        XCTAssertEqual(host.text, "h\n")
    }

    func testReturnIsOnInAnEmptyFieldThatDoesNotAsk() {
        model.keyboardAppeared()
        XCTAssertTrue(model.returnEnabled)
        tap("return")
        XCTAssertEqual(host.text, "\n")
    }
}
