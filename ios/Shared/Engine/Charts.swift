import Foundation

/// The drawing the visual page plays: the same JSON as POST /v1/explain/visual. Built on the phone for charts.
struct DrawScene: Encodable, Equatable {
    static let width: Double = 800, height: Double = 500

    enum Shape: Equatable {
        case text(x: Double, y: Double, text: String, size: String = "s", color: String = "black")
        case rect(x: Double, y: Double, w: Double, h: Double, color: String, fill: String = "none", label: String? = nil)
        case ellipse(x: Double, y: Double, w: Double, h: Double, color: String, fill: String = "none")
        case arrow(x1: Double, y1: Double, x2: Double, y2: Double, color: String = "grey")
        case line(points: [[Double]], color: String)
        /// A closed, filled shape, such as a pie slice. The page closes it.
        case polygon(points: [[Double]], color: String, fill: String = "solid")
    }

    struct Step: Equatable { let say: String; let shapes: [Shape] }

    let title: String
    let steps: [Step]

    func json() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }

    private enum Keys: String, CodingKey { case title, canvas, steps, say, shapes, w, h }
    private struct AnyKey: CodingKey {
        let stringValue: String
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(title, forKey: .title)
        try c.encode(["w": Self.width, "h": Self.height], forKey: .canvas)
        var steps = c.nestedUnkeyedContainer(forKey: .steps)
        for s in self.steps {
            var step = steps.nestedContainer(keyedBy: Keys.self)
            try step.encode(s.say, forKey: .say)
            var shapes = step.nestedUnkeyedContainer(forKey: .shapes)
            for shape in s.shapes {
                var o = shapes.nestedContainer(keyedBy: AnyKey.self)
                func put(_ k: String, _ v: some Encodable) throws { try o.encode(v, forKey: AnyKey(k)) }
                let r = { (v: Double) in (v * 10).rounded() / 10 }
                switch shape {
                case let .text(x, y, text, size, color):
                    try put("type", "text"); try put("x", r(x)); try put("y", r(y)); try put("text", text); try put("size", size); try put("color", color)
                case let .rect(x, y, w, h, color, fill, label):
                    try put("type", "rect"); try put("x", r(x)); try put("y", r(y)); try put("w", r(w)); try put("h", r(h)); try put("color", color); try put("fill", fill)
                    if let label { try put("label", label) }
                case let .ellipse(x, y, w, h, color, fill):
                    try put("type", "ellipse"); try put("x", r(x)); try put("y", r(y)); try put("w", r(w)); try put("h", r(h)); try put("color", color); try put("fill", fill)
                case let .arrow(x1, y1, x2, y2, color):
                    try put("type", "arrow"); try put("x1", r(x1)); try put("y1", r(y1)); try put("x2", r(x2)); try put("y2", r(y2)); try put("color", color)
                case let .line(points, color):
                    try put("type", "line"); try put("points", points.map { $0.map(r) }); try put("color", color)
                case let .polygon(points, color, fill):
                    try put("type", "polygon"); try put("points", points.map { $0.map(r) }); try put("color", color); try put("fill", fill)
                }
            }
        }
    }
}

/// "graph y = x^2", "plot sin x", "bar chart: rent 1200, food 400", "pie chart of my week: work 40 sleep 56 other 72",
/// "line chart 3, 5, 9, 4". Read on the phone; only a chart with no readable data goes to the server.
enum Chart {
    enum Kind: String, Equatable { case bar, pie, line }

    enum Request: Equatable {
        case function(MathExpr, text: String)
        case data(Kind, title: String?, items: [Item])
        /// A chart word but no data the phone can read: the server draws it from the sentence.
        case unclear(String)
    }

    struct Item: Equatable { let label: String; let value: Double }

    static let maxItems = 12

    static func detect(_ text: String) -> Request? {
        let sentence = SmartDetect.lastSentence(text)
        guard !sentence.isEmpty, sentence.count <= Explain.maxQuestion else { return nil }
        let s = Explain.core(sentence)

        // "pie chart of my week: work 40 ..." has a title before the colon; "line chart 3, 5, 9" has the data straight after.
        let parts = s.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 2, let m = match(#"^(bar|pie|line)[ -]?(?:chart|graph)(?: (?:of|for) (.+))?$"#, parts[0]) {
            let items = parseItems(parts[1])
            if items.count >= 2 { return .data(Kind(rawValue: m[0])!, title: m[1].isEmpty ? nil : m[1], items: Array(items.prefix(maxItems))) }
            return .unclear(sentence)
        }
        if let m = match(#"^(bar|pie|line)[ -]?(?:chart|graph)\b\s*,?\s*(.*)$"#, s) {
            let items = parseItems(m[1])
            if items.count >= 2 { return .data(Kind(rawValue: m[0])!, title: nil, items: Array(items.prefix(maxItems))) }
            return .unclear(sentence)
        }
        if let m = match(#"^(?:graph|plot|draw|sketch)(?: the)?(?: (?:graph|plot|curve))?(?: of)?(?: the function)? (?:y\s*=\s*|f\s*\(\s*x\s*\)\s*=\s*)?(.+)$"#, s),
           let e = MathExpr.parse(m[0]), e.usesX {
            return .function(e, text: m[0].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// "rent 1200, food 400, fun 200", "work: 40 sleep=56", "$1,200 rent" is not read; "3, 5, 9, 4" gets labels 1, 2, 3, 4.
    static func parseItems(_ data: String) -> [Item] {
        let d = data.replacingOccurrences(of: #"(\d),(\d{3})\b"#, with: "$1$2", options: .regularExpression)
        var labeled: [Item] = []
        if let re = try? NSRegularExpression(pattern: #"([a-z][a-z '&/-]*?)\s*[:=]?\s*\$?(-?\d+(?:\.\d+)?)\s*%?"#) {
            for m in re.matches(in: d, range: NSRange(d.startIndex..., in: d)) {
                guard let l = Range(m.range(at: 1), in: d), let v = Range(m.range(at: 2), in: d), let value = Double(d[v]) else { continue }
                let label = d[l].trimmingCharacters(in: CharacterSet(charactersIn: " ,;-")).replacingOccurrences(of: #"^(?:and|&)\s+"#, with: "", options: .regularExpression)
                if !label.isEmpty { labeled.append(Item(label: label, value: value)) }
            }
        }
        if labeled.count >= 2 { return labeled }
        let numbers = d.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace }).compactMap { Double($0) }
        return numbers.enumerated().map { Item(label: String($0.offset + 1), value: $0.element) }
    }

    private static func match(_ pattern: String, _ s: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern), let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (1..<m.numberOfRanges).map { i in Range(m.range(at: i), in: s).map { String(s[$0]) } ?? "" }
    }
}

/// Builds the scene for a chart: axes and ticks first, then the data, then the labels, like a teacher at the board.
enum ChartScene {
    /// The plot box on the 800 x 500 board.
    static let left = 90.0, right = 760.0, top = 70.0, bottom = 410.0
    /// Pip's colours on the canvas (the page maps them to the sky family): sky, deep sky, pale sky, then slate.
    static let palette = ["blue", "violet", "light-blue", "grey"]
    /// Bars and lines are all sky; values sit in sky over them.
    static let main = "blue"
    /// Width of one character of size "s" text on the canvas, used to keep labels apart.
    static let charWidth = 10.0

    static func build(_ request: Chart.Request) -> DrawScene? {
        switch request {
        case .function(let e, let text): function(e, text: text)
        case .data(.bar, let title, let items): bar(items, title: title)
        case .data(.line, let title, let items): line(items, title: title)
        case .data(.pie, let title, let items): pie(items, title: title)
        case .unclear: nil
        }
    }

    /// A round step for the axis: 1, 2 or 5 times a power of ten, so there are about `count` ticks.
    static func niceStep(_ span: Double, count: Int = 5) -> Double {
        guard span > 0, span.isFinite else { return 1 }
        let raw = span / Double(count)
        let mag = pow(10, floor(log10(raw)))
        let f = raw / mag
        return (f <= 1 ? 1 : f <= 2 ? 2 : f <= 5 ? 5 : 10) * mag
    }

    static func format(_ v: Double) -> String {
        if abs(v - v.rounded()) < 1e-9 { return String(Int(v.rounded())) }
        return String(format: abs(v) < 10 ? "%.2g" : "%.1f", v).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }

    /// A label cut to fit `width`, so neighbours never overlap.
    static func fit(_ label: String, width: Double) -> String {
        let max = Int(width / charWidth)
        guard label.count > max else { return label }
        return max <= 1 ? String(label.prefix(1)) : String(label.prefix(max - 1)) + "\u{2026}"
    }

    static func textWidth(_ s: String) -> Double { Double(s.count) * charWidth }

    /// Axes with ticks for values from lo to hi; returns the shapes and the value-to-y mapping.
    static func valueAxes(lo: Double, hi: Double) -> (shapes: [DrawScene.Shape], y: (Double) -> Double, ticks: [Double]) {
        let step = niceStep(hi - lo)
        let lo = floor(lo / step) * step, hi = ceil(hi / step) * step
        let y = { (v: Double) in bottom - (v - lo) / (hi - lo) * (bottom - top) }
        var shapes: [DrawScene.Shape] = [
            .arrow(x1: left, y1: y(max(lo, min(0, hi))), x2: right + 20, y2: y(max(lo, min(0, hi))), color: "black"),
            .arrow(x1: left, y1: bottom + 6, x2: left, y2: top - 26, color: "black"),
        ]
        var ticks: [Double] = []
        var t = lo
        while t <= hi + step / 2 {
            ticks.append(t)
            shapes.append(.line(points: [[left - 6, y(t)], [left, y(t)]], color: "black"))
            let label = format(t)
            shapes.append(.text(x: left - 12 - textWidth(label), y: y(t) - 11, text: label, color: "grey"))
            t += step
        }
        return (shapes, y, ticks)
    }

    static func bar(_ items: [Chart.Item], title: String?) -> DrawScene {
        let hi = max(items.map(\.value).max() ?? 1, 0), lo = min(items.map(\.value).min() ?? 0, 0)
        let axes = valueAxes(lo: lo, hi: hi == lo ? lo + 1 : hi)
        let slot = (right - left) / Double(items.count)
        let w = slot * 0.6
        var bars: [DrawScene.Shape] = [], labels: [DrawScene.Shape] = []
        for (i, it) in items.enumerated() {
            let x = left + slot * Double(i) + (slot - w) / 2
            let y0 = axes.y(0), y1 = axes.y(it.value)
            bars.append(.rect(x: x, y: min(y0, y1), w: w, h: max(abs(y0 - y1), 1), color: main, fill: "solid"))
            let value = format(it.value)
            labels.append(.text(x: x + w / 2 - textWidth(value) / 2, y: min(y0, y1) - 26, text: value, color: main))
            let name = fit(it.label, width: slot - 6)
            labels.append(.text(x: left + slot * Double(i) + slot / 2 - textWidth(name) / 2, y: bottom + 12, text: name))
        }
        return DrawScene(title: title ?? "Bar chart", steps: [
            .init(say: "Axes from \(format(axes.ticks.first ?? 0)) to \(format(axes.ticks.last ?? 0)).", shapes: axes.shapes + titleShape(title)),
            .init(say: "One bar for each: the taller, the bigger.", shapes: bars),
            .init(say: "The values and their names.", shapes: labels),
        ])
    }

    static func line(_ items: [Chart.Item], title: String?) -> DrawScene {
        let values = items.map(\.value)
        let lo = min(values.min() ?? 0, 0), hi = values.max() ?? 1
        let axes = valueAxes(lo: lo, hi: hi == lo ? lo + 1 : hi)
        let slot = (right - left) / Double(items.count)
        let xs = items.indices.map { left + slot * (Double($0) + 0.5) }
        let points = zip(xs, items).map { [$0, axes.y($1.value)] }
        var marks: [DrawScene.Shape] = []
        for (i, it) in items.enumerated() {
            marks.append(.ellipse(x: xs[i] - 6, y: axes.y(it.value) - 6, w: 12, h: 12, color: "blue", fill: "solid"))
            let value = format(it.value)
            marks.append(.text(x: xs[i] - textWidth(value) / 2, y: axes.y(it.value) - 34, text: value, color: "blue"))
            let name = fit(it.label, width: slot - 6)
            marks.append(.text(x: xs[i] - textWidth(name) / 2, y: bottom + 12, text: name))
        }
        return DrawScene(title: title ?? "Line chart", steps: [
            .init(say: "Axes from \(format(axes.ticks.first ?? 0)) to \(format(axes.ticks.last ?? 0)).", shapes: axes.shapes + titleShape(title)),
            .init(say: "Join the values in order.", shapes: [.line(points: points, color: "blue")]),
            .init(say: "Each point and its value.", shapes: marks),
        ])
    }

    static func pie(_ items: [Chart.Item], title: String?) -> DrawScene {
        let positive = items.filter { $0.value > 0 }
        let total = positive.map(\.value).reduce(0, +)
        let cx = 250.0, cy = 260.0, r = 180.0
        var slices: [DrawScene.Shape] = [], legend: [DrawScene.Shape] = []
        var angle = -Double.pi / 2
        let rowGap = min(44.0, 340.0 / Double(max(positive.count, 1)))
        for (i, it) in positive.enumerated() {
            let sweep = it.value / total * 2 * .pi
            let n = max(2, Int(sweep / (2 * .pi) * 48))
            var pts: [[Double]] = [[cx, cy]]
            for k in 0...n {
                let a = angle + sweep * Double(k) / Double(n)
                pts.append([cx + r * cos(a), cy + r * sin(a)])
            }
            // Past four slices the colours repeat, half-filled, so neighbours still differ.
            let color = palette[i % palette.count]
            slices.append(.polygon(points: pts, color: color, fill: i < palette.count ? "solid" : "semi"))
            let pct = Int((it.value / total * 100).rounded())
            let y = 90 + rowGap * Double(i)
            legend.append(.rect(x: 480, y: y, w: 18, h: 18, color: color, fill: i < palette.count ? "solid" : "semi"))
            legend.append(.text(x: 510, y: y - 4, text: fit("\(it.label) \(format(it.value)) (\(pct)%)", width: 280), color: "black"))
            angle += sweep
        }
        return DrawScene(title: title ?? "Pie chart", steps: [
            .init(say: "The whole circle is \(format(total)), all of it.", shapes: [.ellipse(x: cx - r, y: cy - r, w: 2 * r, h: 2 * r, color: "grey")] + titleShape(title)),
            .init(say: "Each slice is its share of the circle.", shapes: slices),
            .init(say: "Which slice is which.", shapes: legend),
        ])
    }

    static func function(_ e: MathExpr, text: String) -> DrawScene? {
        // Most graphs read well on -10..10; one with nothing left of 0 (log, sqrt) gets 0..10.
        let negativeOK = (0..<20).contains { e.eval(-10 + Double($0) * 0.5).isFinite }
        let x0 = negativeOK ? -10.0 : 0.0, x1 = 10.0
        let n = 64
        let xs = (0..<n).map { x0 + (x1 - x0) * Double($0) / Double(n - 1) }
        let ys = xs.map { e.eval($0) }
        let finite = ys.filter(\.isFinite).sorted()
        guard finite.count >= 2 else { return nil }
        // The middle 90% of the values set the y range, so 1/x or tan x do not squash the rest.
        var lo = min(finite[finite.count / 20], 0), hi = max(finite[finite.count - 1 - finite.count / 20], 0)
        if hi - lo < 1e-9 { lo -= 1; hi += 1 }
        let xStep = niceStep(x1 - x0)
        let yStep = niceStep(hi - lo)
        lo = floor(lo / yStep) * yStep; hi = ceil(hi / yStep) * yStep
        let px = { (v: Double) in left + (v - x0) / (x1 - x0) * (right - left) }
        let py = { (v: Double) in bottom - (v - lo) / (hi - lo) * (bottom - top) }
        let zeroY = py(min(max(0, lo), hi)), zeroX = px(min(max(0, x0), x1))
        var axes: [DrawScene.Shape] = [
            .arrow(x1: left - 10, y1: zeroY, x2: right + 20, y2: zeroY, color: "black"),
            .arrow(x1: zeroX, y1: bottom + 10, x2: zeroX, y2: top - 26, color: "black"),
            .text(x: right + 22, y: zeroY - 14, text: "x", size: "m"),
            .text(x: zeroX + 10, y: top - 40, text: "y", size: "m"),
        ]
        var t = (x0 / xStep).rounded(.up) * xStep
        while t <= x1 + 1e-9 {
            if abs(t) > 1e-9 {
                axes.append(.line(points: [[px(t), zeroY - 5], [px(t), zeroY + 5]], color: "black"))
                let l = format(t)
                axes.append(.text(x: px(t) - textWidth(l) / 2, y: zeroY + 8, text: l, color: "grey"))
            }
            t += xStep
        }
        t = lo
        while t <= hi + 1e-9 {
            if abs(t) > 1e-9 {
                axes.append(.line(points: [[zeroX - 5, py(t)], [zeroX + 5, py(t)]], color: "black"))
                let l = format(t)
                axes.append(.text(x: zeroX - 12 - textWidth(l), y: py(t) - 11, text: l, color: "grey"))
            }
            t += yStep
        }
        var curves: [DrawScene.Shape] = []
        var seg: [[Double]] = []
        for (x, y) in zip(xs, ys) {
            if y.isFinite, y >= lo, y <= hi { seg.append([px(x), py(y)]) } else {
                if seg.count >= 2 { curves.append(.line(points: seg, color: "blue")) }
                seg = []
            }
        }
        if seg.count >= 2 { curves.append(.line(points: seg, color: "blue")) }
        var notes: [DrawScene.Shape] = [.text(x: left, y: 16, text: "y = \(text)", size: "m", color: "blue")]
        let y0 = e.eval(0)
        if y0.isFinite, y0 >= lo, y0 <= hi, x0 <= 0 {
            notes.append(.ellipse(x: px(0) - 7, y: py(y0) - 7, w: 14, h: 14, color: "blue", fill: "solid"))
            notes.append(.text(x: px(0) + 12, y: py(y0) + 4, text: "(0, \(format(y0)))", size: "m"))
        }
        return DrawScene(title: "y = \(text)", steps: [
            .init(say: "Axes: x from \(format(x0)) to \(format(x1)), y from \(format(lo)) to \(format(hi)).", shapes: axes),
            .init(say: "Work out y for each x and join the points.", shapes: curves),
            .init(say: notes.count > 1 ? "Where it crosses the y axis: x = 0." : "That is the graph of y = \(text).", shapes: notes),
        ])
    }

    private static func titleShape(_ title: String?) -> [DrawScene.Shape] {
        title.map { [.text(x: left, y: 16, text: fit($0, width: 600), size: "m")] } ?? []
    }
}
