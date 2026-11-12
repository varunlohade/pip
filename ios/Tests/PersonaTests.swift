import XCTest
@testable import Pip

/// Many kinds of people take turns on one phone, through one keyboard process: meanings, explain, charts, send, notes,
/// then logout. After each logout the next person must see nothing of the last one. The server is a fake; no paid call.
@MainActor
final class PersonaTests: XCTestCase {
    struct Persona {
        let name: String
        var fullAccess = true
        let note: String
        let word: String
        let topic: String
        let chart: String
    }

    static let people: [Persona] = [
        Persona(name: "student", note: "Essay due friday, cite 3 sources", word: "what does tbh mean", topic: "explain the water cycle", chart: "bar chart: maths 80, physics 72"),
        Persona(name: "teacher", note: "Grade 7B quizzes before Monday", word: "what does iirc mean", topic: "explain fractions", chart: "pie chart: passed 24, failed 3"),
        Persona(name: "shop owner", note: "Supplier: 40 crates, pay on delivery", word: "what does eta mean", topic: "explain gross margin", chart: "bar chart: rent 1200, stock 3400"),
        Persona(name: "freelancer", note: "Invoice #112: 6h at $80", word: "what does asap mean", topic: "explain net 30 terms", chart: "bar chart: design 20, dev 35"),
        Persona(name: "non-native speaker", note: "Recoger a los niños a las 5 \u{00B7} \u{0928}\u{092E}\u{0938}\u{094D}\u{0924}\u{0947}", word: "what does ngl mean", topic: "explain compound interest", chart: "bar chart: alquiler 900, comida 300"),
        Persona(name: "emoji user", note: "\u{1F382}\u{1F389} party at 8 \u{1F57A}\u{1F3FD}\u{2764}\u{FE0F}\u{200D}\u{1F525}", word: "what does fr mean", topic: "explain black holes", chart: "bar chart: \u{1F355} 12, \u{1F354} 8"),
        Persona(name: "privacy-strict, no Full Access", fullAccess: false, note: "Nothing leaves my phone", word: "what does btw mean", topic: "explain vpn", chart: "bar chart: a 1, b 2"),
        Persona(name: "Apple-only", note: "Signed in with Apple only", word: "what does fomo mean", topic: "explain inflation", chart: "bar chart: q1 10, q2 14"),
        Persona(name: "email-only", note: "Signed in with email only", word: "what does imo mean", topic: "explain index funds", chart: "bar chart: rent 1000, fun 200"),
        Persona(name: "both", note: "Apple and email both work", word: "what does idk mean", topic: "explain interest rates", chart: "bar chart: x 3, y 4"),
    ]

    private var host: FakeHost!
    private var api: FakeAPI!
    private var clock: FakeClock!
    private var store: FakeStore!
    private var model: KeyboardModel!

    override func setUp() async throws {
        host = FakeHost()
        api = FakeAPI()
        clock = FakeClock()
        store = FakeStore()
        store.signedIn = false
        model = KeyboardModel(deps: .fake(api: api, store: store, clock: clock))
        model.host = host
    }

    private func set(_ text: String) {
        host.text = text
        model.textChanged()
    }

    private func until(_ what: String, _ cond: () -> Bool) async {
        for _ in 0..<500 where !cond() { await Task.yield() }
        XCTAssertTrue(cond(), "timed out waiting for \(what)")
    }

    /// What the app does on sign-in and on logout, as seen by the keyboard's store.
    private func signIn(_ p: Persona) {
        store.signedIn = true
        store.notes = [Note(text: p.note, trigger: ";n")]
        host.hasFullAccess = p.fullAccess
        api.explainReply = ExplainResponse(short: "\(p.name) answer", body: "line", visual_ok: false)
    }

    private func logOutAndWipe() {
        store.signedIn = false
        store.notes = []
        store.accountEpoch = UUID().uuidString
    }

    private func use(_ p: Persona) async {
        signIn(p)
        model.keyboardAppeared()
        XCTAssertEqual(model.paired, p.fullAccess, p.name)
        XCTAssertEqual(model.notes.map(\.text), p.fullAccess ? [p.note] : [], p.name)

        set(p.word)
        XCTAssertEqual(model.barItems.first?.id, "explain", "\(p.name): the meaning shows on the phone")

        let before = api.calls.count
        set(p.topic)
        if p.fullAccess {
            await until("\(p.name) sleeps") { clock.sleeping > 0 }
            clock.advance(KeyboardModel.explainDebounce.seconds)
            await until("\(p.name) explain") { model.explainCache.values.contains { $0.short == "\(p.name) answer" } }
        } else {
            for _ in 0..<50 { await Task.yield() }
            XCTAssertEqual(api.calls.count, before, "\(p.name): nothing goes to the server")
        }

        set(p.chart)
        model.perform(.explain)
        if case .visual? = model.explainPanel {} else { XCTFail("\(p.name): no chart") }
        model.closeExplain()
        if p.fullAccess { model.sharePrepared = (Data(p.name.utf8), nil) }
        model.keyboardDisappeared()
    }

    private func assertNothingOf(_ p: Persona, line: UInt = #line) {
        XCTAssertFalse(model.notes.contains { $0.text == p.note }, "\(p.name) note", line: line)
        XCTAssertFalse(model.explainCache.values.contains { $0.short.hasPrefix(p.name) }, "\(p.name) answer", line: line)
        XCTAssertNil(model.sharePrepared, "\(p.name) drawing", line: line)
        XCTAssertNil(model.explainOffer, line: line)
        XCTAssertNil(model.explainPanel, line: line)
        XCTAssertTrue(model.smart.isEmpty, line: line)
    }

    func testEachPersonaThenTheNextOnTheSamePhoneSeesNothingOfTheLast() async {
        var previous: Persona?
        for (i, p) in Self.people.enumerated() {
            await use(p)
            logOutAndWipe()
            model.keyboardAppeared()
            for _ in 0..<10 { await Task.yield() }
            assertNothingOf(p)
            if let previous { assertNothingOf(previous) }
            XCTAssertEqual(store.processWipes, i + 1, "\(p.name): the keyboard wiped its caches")
            previous = p
        }
    }

    /// Someone logs out and signs in as a different person without the keyboard ever closing in between.
    func testSwitchingPeopleWhileTheKeyboardStaysUp() async {
        let a = Self.people[0], b = Self.people[3]
        await use(a)
        // The keyboard stays on screen: no keyboardAppeared. Typing must notice the logout before anything else.
        signIn(a)
        model.keyboardAppeared()
        model.toggleNotes()
        XCTAssertEqual(model.notes.map(\.text), [a.note])
        logOutAndWipe()
        signIn(b)
        set("hello")
        assertNothingOf(a)
        model.toggleNotes()
        XCTAssertEqual(model.notes.map(\.text), [b.note], "the next person sees only their own notes")
        XCTAssertFalse(store.notes.contains { $0.text == a.note }, "nothing of the last person is written back")
    }
}
