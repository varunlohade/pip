import CryptoKit
import SwiftUI
import XCTest
@testable import Pip

/// The payment PIN: sealing, wrong tries, the lock, reset, and the keyboard's PIN pad when Face ID fails.
final class PayPINTests: XCTestCase {
    private let signer = FakeSigner()

    func testSealOpenRoundTripAndAWrongPINFails() throws {
        let raw = signer.key.rawRepresentation
        let account = try XCTUnwrap(signer.accountID())
        let sealed = try XCTUnwrap(PayPIN.seal(raw, pin: "482915", account: account))
        XCTAssertEqual(sealed.salt.count, 16)
        XCTAssertGreaterThanOrEqual(sealed.rounds, 200_000)
        XCTAssertNil(sealed.box.range(of: raw), "the key never sits in the clear")
        let key = try XCTUnwrap(PayPIN.open(sealed, pin: "482915", account: account))
        XCTAssertEqual(key.publicKeyHex(), account)
        XCTAssertNil(PayPIN.open(sealed, pin: "482916", account: account))
        XCTAssertNil(PayPIN.open(sealed, pin: "482915", account: String(repeating: "0", count: 64)), "bound to its account")
        XCTAssertNil(PayPIN.seal(raw, pin: "12345", account: account), "6 digits only")
        XCTAssertNil(PayPIN.seal(raw, pin: "12a456", account: account))
    }

    func testTheStoreHoldsNoPIN() throws {
        let store = MemoryPINStore()
        let vault = signer.pinVault(store)
        XCTAssertTrue(vault.set(pin: "482915", raw: signer.key.rawRepresentation))
        for data in store.items.values {
            XCTAssertNil(data.range(of: Data("482915".utf8)), "no PIN in the Keychain")
            XCTAssertNil(data.range(of: signer.key.rawRepresentation), "no raw key in the Keychain")
        }
    }

    func testFiveWrongTriesLockAndFaceIDResetUnlocks() async throws {
        let vault = signer.pinVault()
        XCTAssertTrue(vault.set(pin: "482915", raw: signer.key.rawRepresentation))
        for left in (1...4).reversed() {
            guard case .wrong(let l) = await vault.unlock("000000") else { return XCTFail("not wrong") }
            XCTAssertEqual(l, left)
        }
        guard case .locked = await vault.unlock("000000") else { return XCTFail("not locked after 5") }
        XCTAssertTrue(vault.isLocked)
        guard case .locked = await vault.unlock("482915") else { return XCTFail("the right PIN must not open a locked vault") }
        vault.resetTries()
        guard case .ready(let key) = await vault.unlock("482915") else { return XCTFail("reset did not unlock") }
        XCTAssertEqual(key.publicKeyHex(), signer.accountID())
        XCTAssertEqual(vault.tries, 0, "a right PIN clears the count")
    }

    func testForgotPINSetsANewOneAndTheOldStops() async {
        let vault = signer.pinVault()
        XCTAssertTrue(vault.set(pin: "111111", raw: signer.key.rawRepresentation))
        XCTAssertTrue(vault.set(pin: "222222", raw: signer.key.rawRepresentation))
        guard case .wrong = await vault.unlock("111111") else { return XCTFail("old PIN still works") }
        guard case .ready = await vault.unlock("222222") else { return XCTFail("new PIN does not work") }
        XCTAssertFalse(vault.set(pin: "333333", raw: Curve25519.Signing.PrivateKey().rawRepresentation), "only this account's key")
    }

    func testKeyBytesAreZeroedAfterWipe() async throws {
        let vault = signer.pinVault()
        XCTAssertTrue(vault.set(pin: "482915", raw: signer.key.rawRepresentation))
        guard case .ready(let key) = await vault.unlock("482915") else { return XCTFail("no key") }
        let hash = Data(repeating: 7, count: 32)
        let sig = try XCTUnwrap(key.sign(hash))
        XCTAssertTrue(signer.key.publicKey.isValidSignature(sig, for: hash))
        XCTAssertFalse(key.isWiped)
        key.wipe()
        XCTAssertTrue(key.isWiped)
        XCTAssertNil(key.sign(hash), "a wiped key signs nothing")
    }
}

@MainActor
final class KeyboardPINTests: XCTestCase {
    private var host: FakeHost!
    private var api: FakeAPI!
    private var signer: FakeSigner!
    private var pinStore: MemoryPINStore!
    private var model: KeyboardModel!

    override func setUp() async throws {
        host = FakeHost()
        api = FakeAPI()
        signer = FakeSigner()
        pinStore = MemoryPINStore()
        api.account = signer.accountID()!
        let vault = signer.pinVault(pinStore)
        XCTAssertTrue(vault.set(pin: "482915", raw: signer.key.rawRepresentation))
        model = KeyboardModel(deps: .fake(api: api, signer: signer, pin: vault))
        model.host = host
        model.keyboardAppeared()
        host.text = "send 5 USDC to ana.near"
        model.textChanged()
        model.perform(.pay)
        await until("the card") { model.payPanel != nil }
    }

    /// Real time: the PIN check runs PBKDF2 off the main actor.
    private func until(_ what: String, _ cond: () -> Bool) async {
        for _ in 0..<500 where !cond() { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(cond(), "timed out waiting for \(what)")
    }

    private func type(_ pin: String) { for d in pin { model.typePINDigit(String(d)) } }

    func testThePadShowsWhenFaceIDFailsAndTheRightPINSends() async throws {
        signer.answer = .unavailable
        model.approvePayInKeyboard()
        await until("the pad") { model.payPanel?.pin != nil }
        XCTAssertEqual(model.payPanel?.note, PayFallback.usePIN, "the card says why")
        XCTAssertEqual(api.calls.filter { $0 == "unsigned" }.count, 0)
        type("48291")
        model.deletePINDigit()
        XCTAssertEqual(model.payPanel?.pin, "4829")
        type("15")
        await until("sent") { model.payPanel?.phase == .sent }
        let s = try XCTUnwrap(api.submitted.first)
        XCTAssertTrue(signer.key.publicKey.isValidSignature(s.signature, for: s.hash), "the PIN's key signed the checked tx")
    }

    func testAfterAFailureTheNextApproveGoesStraightToThePad() async {
        signer.answer = .unavailable
        model.approvePayInKeyboard()
        await until("the pad") { model.payPanel?.pin != nil }
        let asks = signer.asks
        model.closePayPanel()
        host.text = "send 5 USDC to ana.testnet"
        model.textChanged()
        model.perform(.pay)
        await until("the card") { model.payPanel != nil }
        model.approvePayInKeyboard()
        XCTAssertEqual(model.payPanel?.pin, "", "the pad, no second Face ID try")
        XCTAssertEqual(signer.asks, asks)
    }

    func testFiveWrongPINsLockAndOfferTheApp() async {
        signer.answer = .unavailable
        model.approvePayInKeyboard()
        await until("the pad") { model.payPanel?.pin != nil }
        for n in 1...4 {
            type("000000")
            await until("wrong \(n)") { model.payPanel?.checkingPIN == false && model.payPanel?.pin == "" && model.payPanel?.note?.hasPrefix("Wrong PIN") == true }
            XCTAssertEqual(model.payPanel?.note, "Wrong PIN. \(5 - n) \(5 - n == 1 ? "try" : "tries") left.")
        }
        type("000000")
        await until("locked") { model.payPanel?.note == PayFallback.locked }
        XCTAssertNil(model.payPanel?.pin)
        XCTAssertEqual(model.payPanel?.offerApp, true)
        XCTAssertEqual(api.submitted.count, 0)
        XCTAssertEqual(String(decoding: pinStore.items[.tries] ?? Data(), as: UTF8.self), "5", "tries live in the Keychain store")
    }

    func testNoPINAndNoFaceIDOffersTheApp() async {
        signer.pinVault(pinStore).remove()
        signer.answer = .unavailable
        model.approvePayInKeyboard()
        await until("the note") { model.payPanel?.note != nil }
        XCTAssertNil(model.payPanel?.pin)
        XCTAssertEqual(model.payPanel?.note, PayFallback.useApp)
        XCTAssertEqual(model.payPanel?.offerApp, true)
    }
}

/// Every keyboard pay color has a light and a dark value with readable contrast, and the pay views use no hard black.
final class PayContrastTests: XCTestCase {
    private func rgb(_ c: Color, dark: Bool) -> (Double, Double, Double) {
        let ui = UIColor(c).resolvedColor(with: UITraitCollection(userInterfaceStyle: dark ? .dark : .light))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b))
    }

    private func luminance(_ c: (Double, Double, Double)) -> Double {
        func f(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * f(c.0) + 0.7152 * f(c.1) + 0.0722 * f(c.2)
    }

    private func contrast(_ a: Color, on b: Color, dark: Bool) -> Double {
        let la = luminance(rgb(a, dark: dark)), lb = luminance(rgb(b, dark: dark))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    func testKeyboardTextIsReadableInLightAndDark() {
        typealias K = Theme.Color.Keyboard
        let bed = (light: Theme.SystemKeyboard.light.bed, dark: Theme.SystemKeyboard.dark.bed)
        for dark in [false, true] {
            let ground = dark ? bed.dark : bed.light
            for (name, ink, min) in [("ink1", K.ink1, 7.0), ("ink2", K.ink2, 4.5), ("warning", K.warning, 4.5), ("link", K.link, 3.0)] {
                XCTAssertGreaterThanOrEqual(contrast(ink, on: K.card, dark: dark), min, "\(name) on card, dark=\(dark)")
                XCTAssertGreaterThanOrEqual(contrast(ink, on: ground, dark: dark), min, "\(name) on the keyboard bed, dark=\(dark)")
            }
            XCTAssertGreaterThanOrEqual(contrast(K.successInk, on: K.successChip, dark: dark), 4.5, "Sent chip, dark=\(dark)")
        }
    }

    func testPayViewsUseNoHardBlack() throws {
        let src = try String(contentsOfFile: #filePath.replacingOccurrences(of: "Tests/PayPINTests.swift", with: "Shared/PayViews.swift"), encoding: .utf8)
        for bad in ["Color.black", ".black)", ".black,", ".foregroundStyle(.black", "foregroundColor(.black"] {
            XCTAssertFalse(src.contains(bad), "PayViews.swift uses \(bad)")
        }
        // The keyboard sections use the light-and-dark tokens only.
        let keyboard = src.components(separatedBy: "// MARK: keyboard").dropFirst().map { $0.components(separatedBy: "// MARK: app").first ?? "" }
        XCTAssertEqual(keyboard.count, 2)
        for part in keyboard {
            for light in ["Theme.Color.text1", "Theme.Color.text2", "Theme.Color.text3", "Theme.Color.warning", ".fill(.white)"] {
                XCTAssertFalse(part.contains(light), "keyboard pay view uses light-only \(light)")
            }
        }
    }
}
