import XCTest
@testable import Pip

/// Voice and drawing stay in step. Every test uses FakeSpeaker, so no sound is ever made.
@MainActor
final class NarrationSyncTests: XCTestCase {
    private var speaker: FakeSpeaker!
    private var clock: FakeClock!
    private var advances = 0
    private var sync: NarrationSync!

    override func setUp() async throws {
        speaker = FakeSpeaker()
        clock = FakeClock()
        advances = 0
        sync = NarrationSync(speaker: speaker, maxWait: .seconds(8), sleep: { [clock] d in try await clock!.sleep(d) }) { [unowned self] in self.advances += 1 }
    }

    func testAStepGoesOnOnlyWhenItsLineIsSaidAndItsShapesAreDrawn() {
        sync.stepStarted(1, say: "Start with a graph.")
        XCTAssertEqual(speaker.said, ["Start with a graph."])
        sync.stepDrawn(1)
        XCTAssertEqual(advances, 0, "the voice is still speaking")
        speaker.finish()
        XCTAssertEqual(advances, 1)

        sync.stepStarted(2, say: "Draw the curve.")
        speaker.finish()
        XCTAssertEqual(advances, 1, "the drawing is still going")
        sync.stepDrawn(2)
        XCTAssertEqual(advances, 2)
    }

    func testASlowVoiceIsCutAtTheMaxWait() async {
        sync.stepStarted(1, say: "A very long sentence that takes a while.")
        sync.stepDrawn(1)
        for _ in 0..<50 where clock.sleeping == 0 { await Task.yield() }
        XCTAssertEqual(clock.sleeps, [.seconds(8)])
        clock.advance(8)
        for _ in 0..<50 where advances == 0 { await Task.yield() }
        XCTAssertEqual(advances, 1)
        XCTAssertEqual(speaker.stops, 1, "the line is cut so the next one can start")
    }

    func testAStepWithNoLineWaitsOnlyForTheDrawing() {
        sync.stepStarted(1, say: nil)
        XCTAssertEqual(speaker.said, [])
        sync.stepDrawn(1)
        XCTAssertEqual(advances, 1)
    }

    func testTheOldLineEndingDoesNotMoveTheNewStep() {
        sync.stepStarted(1, say: "One.")
        // Starting step 2 ends line one; that late completion belongs to step 1 and must not count for step 2.
        sync.stepStarted(2, say: "Two.")
        sync.stepDrawn(2)
        XCTAssertEqual(advances, 0, "step 2's line is still speaking")
        sync.stepDrawn(1)
        XCTAssertEqual(advances, 0)
        speaker.finish()
        XCTAssertEqual(advances, 1)
    }

    func testStopIsQuietAtOnceAndLetsThePageGo() {
        sync.stepStarted(1, say: "One.")
        sync.stop()
        XCTAssertEqual(speaker.stops, 1)
        XCTAssertEqual(advances, 1)
        sync.stepStarted(2, say: "Two.")
        XCTAssertEqual(speaker.said, ["One."], "nothing is said after stop")
        sync.stop()
        XCTAssertEqual(speaker.stops, 1)
    }
}

@MainActor
final class VoiceModelTests: XCTestCase {
    final class Page: VisualPage {
        var replays = 0, nexts = 0
        var voice: [Bool] = []
        func play(_ scene: Data) {}
        func replay() { replays += 1 }
        func setTool(_ tool: VisualState.Tool) {}
        func undo() {}
        func redo() {}
        func exportPNG() {}
        func setVoice(_ on: Bool) { voice.append(on) }
        func next() { nexts += 1 }
    }

    func testOnlyATapStartsTheVoiceAndASecondTapStopsIt() {
        let host = FakeHost(), speaker = FakeSpeaker()
        let model = KeyboardModel(deps: .fake(api: FakeAPI(), speaker: speaker))
        model.host = host
        model.keyboardAppeared()
        host.text = "graph y = x^2"
        model.textChanged()
        model.perform(.explain)
        let page = Page()
        model.visualPageReady(page)
        model.visualStep(1, of: 3, say: "Axes.")
        XCTAssertEqual(speaker.said, [], "drawing alone never speaks")
        model.visualDone()

        model.toggleVoice()
        XCTAssertEqual(page.voice, [true])
        XCTAssertEqual(page.replays, 1)
        model.visualStep(1, of: 3, say: "Axes.")
        XCTAssertEqual(speaker.said, ["Axes."])
        model.visualStepDrawn(1)
        speaker.finish()
        XCTAssertEqual(page.nexts, 1)

        model.toggleVoice()
        XCTAssertEqual(page.voice, [true, false])
        XCTAssertEqual(speaker.stops, 1)
        guard case .visual(let v)? = model.explainPanel else { return XCTFail("panel closed") }
        XCTAssertFalse(v.voice)
        model.visualStep(2, of: 3, say: "Curve.")
        XCTAssertEqual(speaker.said, ["Axes."])
    }

    func testClosingThePanelStopsTheVoice() {
        let host = FakeHost(), speaker = FakeSpeaker()
        let model = KeyboardModel(deps: .fake(api: FakeAPI(), speaker: speaker))
        model.host = host
        model.keyboardAppeared()
        host.text = "graph y = x^2"
        model.textChanged()
        model.perform(.explain)
        model.visualPageReady(Page())
        model.visualStep(1, of: 3, say: "Axes.")
        model.visualDone()
        model.toggleVoice()
        model.visualStep(1, of: 3, say: "Axes.")
        model.closeExplain()
        XCTAssertEqual(speaker.stops, 1)
    }
}
