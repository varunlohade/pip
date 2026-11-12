import XCTest
@testable import Pip

final class MathExprTests: XCTestCase {
    private func value(_ s: String, at x: Double, line: UInt = #line) -> Double? {
        let e = MathExpr.parse(s)
        XCTAssertNotNil(e, s, line: line)
        return e?.eval(x)
    }

    func testParsesAndEvaluates() {
        let cases: [(String, Double, Double)] = [
            ("x^2", 3, 9), ("x²", 3, 9), ("-x^2", 2, -4), ("2x + 1", 3, 7), ("2(x+1)", 1, 4), ("x/2 - 1", 4, 1),
            ("sin x", .pi / 2, 1), ("sinx", .pi / 2, 1), ("sin(x)", 0, 0), ("cos x", 0, 1), ("x sin x", .pi / 2, .pi / 2),
            ("2^-x", 1, 0.5), ("1/x", 4, 0.25), ("sqrt(x)", 9, 3), ("log(x)", 100, 2), ("ln x", M_E, 1), ("abs(x - 3)", 1, 2),
            ("3x^2 - 2x + 1", 2, 9), ("x**3", 2, 8), ("pi x", 1, .pi), ("e^x", 0, 1), ("sin x^2", 2, sin(4)),
        ]
        for (s, x, want) in cases {
            guard let got = value(s, at: x) else { continue }
            XCTAssertEqual(got, want, accuracy: 1e-9, "\(s) at \(x)")
        }
    }

    func testRejectsWhatItDoesNotUnderstand() {
        for s in ["twist", "paper", "x +", "((x)", "x)", "2 $ x", "import os", "x; rm", "", "sin", String(repeating: "(", count: 200) + "x" + String(repeating: ")", count: 200)] {
            XCTAssertNil(MathExpr.parse(s), s)
        }
        XCTAssertEqual(MathExpr.parse("3")?.usesX, false)
    }
}

final class ChartDetectTests: XCTestCase {
    func testFunctions() {
        for (text, x, y) in [("graph y = x^2", 3.0, 9.0), ("plot sin x", Double.pi / 2, 1.0), ("Plot y=2x+1", 1, 3), ("graph of x^3", 2, 8), ("draw f(x) = 1/x", 2, 0.5)] {
            guard case .function(let e, _)? = Chart.detect(text) else { XCTFail(text); continue }
            XCTAssertEqual(e.eval(x), y, accuracy: 1e-9, text)
        }
    }

    func testDataCharts() {
        XCTAssertEqual(Chart.detect("bar chart: rent 1200, food 400, fun 200"),
                       .data(.bar, title: nil, items: [.init(label: "rent", value: 1200), .init(label: "food", value: 400), .init(label: "fun", value: 200)]))
        XCTAssertEqual(Chart.detect("pie chart of my week: work 40 sleep 56 other 72"),
                       .data(.pie, title: "my week", items: [.init(label: "work", value: 40), .init(label: "sleep", value: 56), .init(label: "other", value: 72)]))
        XCTAssertEqual(Chart.detect("line chart 3, 5, 9, 4"),
                       .data(.line, title: nil, items: [.init(label: "1", value: 3), .init(label: "2", value: 5), .init(label: "3", value: 9), .init(label: "4", value: 4)]))
        XCTAssertEqual(Chart.detect("bar graph: rent $1,200 and food $400"),
                       .data(.bar, title: nil, items: [.init(label: "rent", value: 1200), .init(label: "food", value: 400)]))
    }

    func testUnclearChartsGoToTheServerAndChatIsNotAChart() {
        XCTAssertEqual(Chart.detect("bar chart of my spending"), .unclear("bar chart of my spending"))
        for text in ["plot twist", "i lost the plot", "graph paper", "draw me a cat", "explain log function", "what does btw mean", "lol ok", "the plot was good"] {
            XCTAssertNil(Chart.detect(text), text)
        }
    }
}

final class ChartSceneTests: XCTestCase {
    private func rects(_ s: DrawScene) -> [(x: Double, y: Double, w: Double, h: Double)] {
        s.steps.flatMap(\.shapes).compactMap { if case let .rect(x, y, w, h, _, _, _) = $0 { return (x, y, w, h) }; return nil }
    }

    private func texts(_ step: DrawScene.Step) -> [(x: Double, y: Double, text: String)] {
        step.shapes.compactMap { if case let .text(x, y, t, _, _) = $0 { return (x, y, t) }; return nil }
    }

    private func inside(_ s: DrawScene, line: UInt = #line) {
        for shape in s.steps.flatMap(\.shapes) {
            let pts: [(Double, Double)]
            switch shape {
            case let .text(x, y, t, _, _): pts = [(x, y), (x + ChartScene.textWidth(t), y)]
            case let .rect(x, y, w, h, _, _, _), let .ellipse(x, y, w, h, _, _): pts = [(x, y), (x + w, y + h)]
            case let .arrow(x1, y1, x2, y2, _): pts = [(x1, y1), (x2, y2)]
            case let .line(p, _): pts = p.map { ($0[0], $0[1]) }
            }
            for (x, y) in pts { XCTAssertTrue((0...DrawScene.width).contains(x) && (0...DrawScene.height).contains(y), "\(shape) leaves the board", line: line) }
        }
    }

    func testBarHeightsMatchTheValuesAndTheTallestReachesTheTop() throws {
        let items: [Chart.Item] = [.init(label: "rent", value: 1200), .init(label: "food", value: 400), .init(label: "fun", value: 200)]
        let s = ChartScene.bar(items, title: nil)
        let bars = rects(s)
        XCTAssertEqual(bars.count, 3)
        for (b, it) in zip(bars, items) { XCTAssertEqual(b.h / it.value, bars[0].h / 1200, accuracy: 1e-9) }
        // The scale comes from the axis: the top tick sits at the top of the plot, and 1200 sits at 1200 / topTick of it.
        let topTick = try XCTUnwrap(texts(s.steps[0]).compactMap { Double($0.text) }.max())
        XCTAssertEqual(topTick, 1500)
        XCTAssertEqual(bars[0].y, ChartScene.bottom - 1200 / topTick * (ChartScene.bottom - ChartScene.top), accuracy: 1e-9)
        XCTAssertEqual(bars[0].y + bars[0].h, ChartScene.bottom, accuracy: 1e-9, "bars stand on 0")
        let labels = texts(s.steps[2]).map(\.text)
        XCTAssertEqual(labels, ["1200", "rent", "400", "food", "200", "fun"])
        XCTAssertEqual(s.steps.count, 3)
        inside(s)
    }

    func testEightLongLabelsNeverOverlap() {
        let items = (1...8).map { Chart.Item(label: "a very long category name \($0)", value: Double($0 * 13)) }
        for s in [ChartScene.bar(items, title: "Spending"), ChartScene.line(items, title: nil)] {
            let names = texts(s.steps[2]).filter { $0.y > ChartScene.bottom }.sorted { $0.x < $1.x }
            XCTAssertEqual(names.count, 8)
            for (a, b) in zip(names, names.dropFirst()) {
                XCTAssertLessThanOrEqual(a.x + ChartScene.textWidth(a.text), b.x, "\(a.text) overlaps \(b.text)")
            }
            inside(s)
        }
    }

    func testPieSlicesShareTheCircleAndTheLegendRowsAreApart() {
        let items: [Chart.Item] = [.init(label: "work", value: 40), .init(label: "sleep", value: 56), .init(label: "other", value: 72)]
        let s = ChartScene.pie(items, title: "my week")
        let slices = s.steps[1].shapes.compactMap { if case let .line(p, _) = $0 { return p }; return nil }
        XCTAssertEqual(slices.count, 3)
        // Each slice's sweep matches its share of 168.
        for (p, it) in zip(slices, items) {
            let a0 = atan2(p[1][1] - 260, p[1][0] - 250), a1 = atan2(p[p.count - 2][1] - 260, p[p.count - 2][0] - 250)
            var sweep = a1 - a0
            if sweep < 0 { sweep += 2 * .pi }
            XCTAssertEqual(sweep / (2 * .pi), it.value / 168, accuracy: 1e-6, it.label)
        }
        let legend = texts(s.steps[2])
        XCTAssertEqual(legend.map(\.text), ["work 40 (24%)", "sleep 56 (33%)", "other 72 (43%)"])
        let eight = ChartScene.pie((1...8).map { .init(label: "item \($0)", value: Double($0)) }, title: nil)
        let rows = texts(eight.steps[2]).map(\.y)
        for (a, b) in zip(rows, rows.dropFirst()) { XCTAssertGreaterThanOrEqual(b - a, 30) }
        inside(s)
        inside(eight)
    }

    func testFunctionGraphFollowsTheCurveAndStaysOnTheBoard() throws {
        let e = try XCTUnwrap(MathExpr.parse("x^2"))
        let s = try XCTUnwrap(ChartScene.function(e, text: "x^2"))
        let curve = s.steps[1].shapes.compactMap { if case let .line(p, _) = $0 { return p }; return nil }.flatMap { $0 }
        XCTAssertGreaterThan(curve.count, 20)
        // The lowest point of x^2 sits at x = 0, in the middle of -10..10.
        let lowest = try XCTUnwrap(curve.max { $0[1] < $1[1] })
        XCTAssertEqual(lowest[0], (ChartScene.left + ChartScene.right) / 2, accuracy: (ChartScene.right - ChartScene.left) / 60)
        inside(s)
        // log has nothing left of 0, so its graph runs 0..10; 1/x and tan x stay on the board.
        for f in ["log(x)", "1/x", "tan x", "sqrt(x)", "e^x"] {
            let g = try XCTUnwrap(ChartScene.function(XCTUnwrap(MathExpr.parse(f)), text: f), f)
            inside(g)
        }
        XCTAssertTrue(ChartScene.function(MathExpr.parse("log(x)")!, text: "log(x)")!.steps[0].say.contains("x from 0 to 10"))
    }

    func testSceneJSONHasTheShapeTypesThePageReads() throws {
        let s = ChartScene.bar([.init(label: "a", value: 1), .init(label: "b", value: 2)], title: nil)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: s.json()) as? [String: Any])
        XCTAssertEqual((obj["canvas"] as? [String: Double])?["w"], 800)
        let steps = try XCTUnwrap(obj["steps"] as? [[String: Any]])
        let types = Set(steps.flatMap { ($0["shapes"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String } })
        XCTAssertEqual(types, ["arrow", "line", "text", "rect"])
    }
}
