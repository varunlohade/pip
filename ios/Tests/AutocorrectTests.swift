import XCTest
@testable import Pip

/// Autocorrect on space and punctuation: clear typos only.
final class AutocorrectTests: XCTestCase {
    /// A speller that knows only these misspellings and their guesses. Every other word is spelled right.
    private func speller(_ wrong: [String: [String]]) -> FixCheck.Speller {
        { word in wrong[word.lowercased()].map { .wrong(guesses: $0) } ?? .ok }
    }

    private func fix(_ before: String, names: [String] = [], kept: Set<String> = [], wrong: [String: [String]] = [:]) -> String? {
        FixCheck.autocorrect(before, names: names, kept: kept, spell: speller(wrong))?.fixed
    }

    func testClearTyposAreFixed() {
        XCTAssertEqual(fix("can you do teh"), "the")
        XCTAssertEqual(fix("I dont"), "don't")
        XCTAssertEqual(fix("see you im"), "I'm")
        XCTAssertEqual(fix("ok i"), "I")
        XCTAssertEqual(fix("so i'm"), "I'm")
        XCTAssertEqual(fix("see you tomorow", wrong: ["tomorow": ["tomorrow", "Tomorow"]]), "tomorrow")
        XCTAssertEqual(fix("is it availble", wrong: ["availble": ["available"]]), "available")
    }

    func testTheFixKeepsTheCapitalAndCapitalizesASentenceStart() {
        XCTAssertEqual(fix("Teh"), "The")
        XCTAssertEqual(fix("Done. teh"), "The")
        XCTAssertEqual(fix("thnks", wrong: ["thnks": ["thanks", "thinks"]]), "Thanks")
    }

    func testOnlyAnEverydayWordCloseByCounts() {
        // "arpit" is a name typed in lowercase: "armpit" is near but not an everyday word.
        XCTAssertNil(fix("ask arpit", wrong: ["arpit": ["armpit"]]))
        // A short word may be off by one letter only.
        XCTAssertNil(fix("a cst", wrong: ["cst": ["cut", "cast"]]).flatMap { $0 == "cut" ? nil : $0 })
        XCTAssertNil(fix("a cst", wrong: ["cst": ["just"]]))
        XCTAssertNil(fix("a zzq", wrong: ["zzq": []]))
    }

    func testNamesLinksAmountsAndChatWordsStayAsTyped() {
        XCTAssertNil(fix("invoice samm", names: ["Samm Lee"], wrong: ["samm": ["same"]]))
        XCTAssertNil(fix("thanks Bnak", wrong: ["bnak": ["bank"]]))
        XCTAssertNil(fix("go to www.teh"))
        XCTAssertNil(fix("mail sam@teh"))
        XCTAssertNil(fix("it is $45"))
        XCTAssertNil(fix("see #teh"))
        XCTAssertNil(fix("ok lol"))
        XCTAssertNil(fix("ok u"))
        XCTAssertNil(fix("it's teh,"))
    }

    func testAWordPutBackIsNotFixedAgain() {
        XCTAssertNil(fix("can you do teh", kept: ["teh"]))
    }

    func testAnotherLanguageIsLeftAlone() {
        XCTAssertNil(FixCheck.autocorrect("hola amigo, nos vemos mañana en la tienda despues", spell: speller(["despues": ["despise", "depose"]])))
    }

    func testTheRealSpellerFixesACommonTypo() {
        XCTAssertEqual(FixCheck.autocorrect("can you send the invoce")?.fixed, "invoice")
        XCTAssertNil(FixCheck.autocorrect("can you send the invoice"))
    }
}
