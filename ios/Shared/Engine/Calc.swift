import Foundation

/// Sums and conversions read from the last sentence on the phone: "12*7", "tip 18% on 64", "split 120 4 ways", "5 km in miles",
/// "3pm PST in IST", "100 usd to inr". Pure and instant; only currency needs rates, which the caller hands in.
/// Quiet: the whole sentence must be the ask. Chat that only holds numbers ("call me at 5", "it was 20 bucks lol") is nil.
enum Calc {
    enum Ask: Equatable {
        case math(Double)
        case percentOf(pct: Double, of: Double)
        case percentOff(pct: Double, of: Double, symbol: String?)
        case tip(pct: Double, bill: Double, symbol: String?)
        case split(total: Double, ways: Int, symbol: String?)
        case units(Double, from: Unit, to: Unit)
        case time(hour: Int, minute: Int, from: Zone?, to: Zone)
        case timeNow(Zone)
        case currency(Double, from: String, to: String)

        var needsRates: Bool { if case .currency = self { return true }; return false }
    }

    /// What the chip shows and what a tap types in place of the ask.
    struct Answer: Equatable {
        /// The ask as typed, quoted on the chip.
        let trigger: String
        let title: String
        /// A quiet note, such as "as of 10:00 AM" for currency.
        var note: String? = nil
        /// Replaces the ask sentence in the field.
        let insert: String
    }

    struct Rates: Codable, Equatable {
        let base: String
        let date: String
        let fetched_at: Date
        /// Units of each currency for one `base`.
        let rates: [String: Double]
    }

    static let maxSentence = 80

    /// The ask in the last sentence, or nil for plain chat.
    static func read(_ text: String) -> (ask: Ask, trigger: String)? {
        let sentence = SmartDetect.lastSentence(text)
        guard !sentence.isEmpty, sentence.count <= maxSentence, sentence.contains(where: \.isNumber) || sentence.lowercased().contains("time") else { return nil }
        let trigger = sentence.replacingOccurrences(of: #"[\s?=]+$"#, with: "", options: .regularExpression)
        let s = normalize(sentence)
        guard !s.isEmpty else { return nil }
        // "9am in london" is an ask only as a question; as a statement it is a plan.
        let asked = sentence.hasSuffix("?") || sentence.lowercased().range(of: #"^(?:what(?:'s|’s| is|s)|convert) "#, options: .regularExpression) != nil
        let readers: [(String) -> Ask?] = [readTimeNow, { readTime($0, asked: asked) }, readTipSplit, readPercent, readConversion, readMath]
        for f in readers {
            if let a = f(s) { return (a, trigger) }
        }
        return nil
    }

    /// The answer for `text`, or nil. Currency without rates is nil; the caller fetches rates and asks again.
    static func detect(_ text: String, now: Date, zone: TimeZone = .current, rates: Rates?) -> Answer? {
        guard let (ask, trigger) = read(text) else { return nil }
        return answer(ask, trigger: trigger, now: now, zone: zone, rates: rates)
    }

    static func answer(_ ask: Ask, trigger: String, now: Date, zone: TimeZone, rates: Rates?) -> Answer? {
        switch ask {
        case .math(let v):
            let r = number(v)
            return Answer(trigger: trigger, title: "= \(r)", insert: "\(trigger) = \(r)")
        case .percentOf(let p, let of):
            let r = number(of * p / 100)
            return Answer(trigger: trigger, title: "= \(r)", insert: "\(trigger) = \(r)")
        case .percentOff(let p, let of, let sym):
            let off = of * p / 100
            let title = "\(money(of - off, sym)) (\(money(off, sym)) off)"
            return Answer(trigger: trigger, title: title, insert: title)
        case .tip(let p, let bill, let sym):
            let tip = (bill * p / 100 * 100).rounded() / 100
            return Answer(trigger: trigger, title: "\(money(tip, sym)) tip \u{00B7} \(money(bill + tip, sym)) total",
                          insert: "\(money(tip, sym)) tip, \(money(bill + tip, sym)) total")
        case .split(let total, let ways, let sym):
            let each = "\(money(total / Double(ways), sym)) each"
            return Answer(trigger: trigger, title: each, insert: each)
        case .units(let v, let from, let to):
            let r = from.convert(v, to: to)
            guard r.isFinite else { return nil }
            let title = "\(number(r, digits: 2)) \(to.symbol)"
            return Answer(trigger: trigger, title: title, insert: "\(number(v)) \(from.symbol) = \(title)")
        case .time(let h, let m, let from, let to):
            let src = from?.tz ?? zone
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = src
            guard let at = cal.date(bySettingHour: h, minute: m, second: 0, of: now) else { return nil }
            var title = "\(clock(at, to.tz)) \(to.label)"
            var dst = Calendar(identifier: .gregorian)
            dst.timeZone = to.tz
            let day = { (c: Calendar) -> Int in let d = c.dateComponents([.year, .month, .day], from: at); return (d.year ?? 0) * 10000 + (d.month ?? 0) * 100 + (d.day ?? 0) }
            let a = day(cal), b = day(dst)
            if a != b { title += b > a ? ", next day" : ", day before" }
            let fromText = "\(clock(at, src))\(from.map { " \($0.label)" } ?? "")"
            return Answer(trigger: trigger, title: title, insert: "\(fromText) = \(title)")
        case .timeNow(let z):
            let t = clock(now, z.tz)
            return Answer(trigger: trigger, title: "\(t) in \(z.label)", insert: "It's \(t) in \(z.label)")
        case .currency(let v, let from, let to):
            guard let rates, let a = rates.rates[from], let b = rates.rates[to], a > 0 else { return nil }
            let r = v / a * b
            let title = money(r, code: to)
            return Answer(trigger: trigger, title: title, note: "as of \(asOf(rates.fetched_at, now: now, zone: zone))",
                          insert: "\(money(v, code: from)) = \(title)")
        }
    }

    // MARK: readers

    /// Lowercase, "×" and "÷" as * and /, thousands commas gone, a lead-in such as "what's" or "calc" dropped, end marks dropped.
    static func normalize(_ sentence: String) -> String {
        var s = sentence.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{00D7}", with: "*").replacingOccurrences(of: "\u{00F7}", with: "/").replacingOccurrences(of: "\u{2212}", with: "-")
            .replacingOccurrences(of: "\u{201D}", with: "\"").replacingOccurrences(of: "\u{2033}", with: "\"")
        s = s.replacingOccurrences(of: #"(\d),(\d{3})(?!\d)"#, with: "$1$2", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[\s?=]+$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^(?:(?:hey|ok|okay|so|pip|quick q)\b[,:\s]*)*(?:what(?:'s| is|s)|how much is|calc(?:ulate)?|convert|whats)\s+"#, with: "", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    static let num = #"(\d+(?:\.\d+)?|\.\d+)"#
    static let sym = #"([$€£₹¥])?"#

    static func readTipSplit(_ s: String) -> Ask? {
        if let m = match(#"^(?:a )?tip (?:of )?\#(num) ?% (?:on|of|for) \#(sym) ?\#(num)$"#, s) ?? match(#"^\#(num) ?% tip (?:on|of|for) \#(sym) ?\#(num)$"#, s),
           let p = Double(m[0]), let bill = Double(m[2]), p > 0, p <= 100, bill > 0 {
            return .tip(pct: p, bill: bill, symbol: m[1].isEmpty ? nil : m[1])
        }
        let ways = #"(\d{1,3})"#
        for pattern in [
            #"^split \#(sym) ?\#(num) (?:in |into )?\#(ways) ways$"#,
            #"^split \#(sym) ?\#(num) (?:between|among|by|with|for) \#(ways)(?: people| ppl| of us| ways)?$"#,
            #"^\#(sym) ?\#(num) split (?:in |into )?\#(ways) ways$"#,
            #"^\#(sym) ?\#(num) split (?:between|among|by|with) \#(ways)(?: people| ppl| of us)?$"#,
        ] {
            if let m = match(pattern, s), let t = Double(m[1]), let n = Int(m[2]), t > 0, n >= 2, n <= 100 {
                return .split(total: t, ways: n, symbol: m[0].isEmpty ? nil : m[0])
            }
        }
        return nil
    }

    static func readPercent(_ s: String) -> Ask? {
        if let m = match(#"^\#(num) ?% of \#(num)$"#, s), let p = Double(m[0]), let v = Double(m[1]) { return .percentOf(pct: p, of: v) }
        if let m = match(#"^\#(num) ?% off \#(sym) ?\#(num)$"#, s), let p = Double(m[0]), let v = Double(m[2]), p <= 100 {
            return .percentOff(pct: p, of: v, symbol: m[1].isEmpty ? nil : m[1])
        }
        return nil
    }

    /// "5 km in miles", "72f to c", "how many ml in 3 cups", "5'10 in cm", "100 usd to inr", "$20 in euros".
    static func readConversion(_ s: String) -> Ask? {
        if let m = match(#"^(\d)'\s?(\d{1,2}(?:\.\d+)?)"?\s?(?:in|to|into) (cm|centimeters?|centimetres?|m|meters?|metres?)$"#, s),
           let ft = Double(m[0]), let inch = Double(m[1]), let to = Unit.find(m[2]) {
            return .units(ft * 12 + inch, from: Unit.find("in")!, to: to)
        }
        var amount: Double, fromWord: String, toWord: String, symbol = ""
        if let m = match(#"^how many ([a-z°'" ./]+?) (?:in|are in|is in) \#(sym) ?\#(num) ?([a-z°'" ./]*?)$"#, s), let v = Double(m[2]) {
            (amount, fromWord, toWord, symbol) = (v, m[3], m[0], m[1])
        } else if let m = match(#"^\#(sym) ?\#(num) ?(k(?![a-z]))? ?([a-z°'" ./]*?) (?:in|to|into|as|->|→) ([a-z°'" ./]+?)$"#, s), let v = Double(m[1]) {
            (amount, fromWord, toWord, symbol) = (v * (m[2].isEmpty ? 1 : 1000), m[3], m[4], m[0])
            // "5k in miles" is a run: kilometers, not thousands.
            if !m[2].isEmpty, fromWord.isEmpty, symbol.isEmpty { (amount, fromWord) = (v, "km") }
        } else {
            return nil
        }
        fromWord = fromWord.replacingOccurrences(of: #"^(?:degrees?|deg) "#, with: "", options: .regularExpression)
        toWord = toWord.replacingOccurrences(of: #"^(?:degrees?|deg) "#, with: "", options: .regularExpression)
        let fromCode = symbol.isEmpty ? Money.code(fromWord) : (fromWord.isEmpty ? Money.symbols[symbol] : nil)
        if let f = fromCode, let t = Money.code(toWord), f != t { return .currency(amount, from: f, to: t) }
        guard symbol.isEmpty, let f = Unit.find(fromWord), let t = Unit.find(toWord), f.kind == t.kind, f != t else { return nil }
        return .units(amount, from: f, to: t)
    }

    /// "3pm PST in IST", "15:30 utc to tokyo", "9am in london". A time needs am/pm or minutes, so "at 5 in la" stays chat.
    static func readTime(_ s: String, asked: Bool) -> Ask? {
        guard let m = match(#"^(\d{1,2})(?::(\d{2}))? ?(am|pm|a\.m\.|p\.m\.)?(?: ([a-z][a-z .]*?))? (?:in|to|into) ([a-z][a-z .]*?)(?: time)?$"#, s),
              var h = Int(m[0]), !(m[1].isEmpty && m[2].isEmpty) else { return nil }
        let min = Int(m[1]) ?? 0
        guard min < 60 else { return nil }
        if !m[2].isEmpty {
            guard (1...12).contains(h) else { return nil }
            h = h % 12 + (m[2].hasPrefix("p") ? 12 : 0)
        } else {
            guard h < 24 else { return nil }
        }
        let from: Zone?
        if m[3].isEmpty { guard asked else { return nil }; from = nil } else { guard let z = Zone.find(m[3]) else { return nil }; from = z }
        guard let to = Zone.find(m[4]) else { return nil }
        return .time(hour: h, minute: min, from: from, to: to)
    }

    static func readTimeNow(_ s: String) -> Ask? {
        guard let m = match(#"^(?:(?:what|whats|what's) )?(?:(?:is )?the )?(?:current |local )?time(?: is it)?(?: now)?(?: right now)? (?:in|at) ([a-z][a-z .]*?)(?: (?:right )?now)?$"#, s)
                ?? match(#"^time is it (?:in|at) ([a-z][a-z .]*?)$"#, s),
              let z = Zone.find(m[0]) else { return nil }
        return .timeNow(z)
    }

    /// "12*7", "1200/3", "(45+30)*1.18", "12x7". Needs a real operator between two numbers; ranges, dates, scores and
    /// phone numbers ("2-3", "11/13", "24/7", "555-1234", "+1 555 123 4567") are chat.
    static func readMath(_ s: String) -> Ask? {
        let e = s.replacingOccurrences(of: #"(?<=[\d)])\s*x\s*(?=[\d(])"#, with: "*", options: .regularExpression)
        guard e.range(of: #"^[\d.\s+\-*/^()]+$"#, options: .regularExpression) != nil,
              e.range(of: #"^\s*[(\d.-]"#, options: .regularExpression) != nil,
              let tokens = MathExpr.tokenize(e) else { return nil }
        let nums = tokens.filter { if case .num = $0 { return true }; return false }.count
        let ops = tokens.compactMap { t -> Character? in if case .op(let o) = t { return o }; return nil }
        guard nums >= 2, !ops.isEmpty else { return nil }
        // Two numbers side by side are a phone number or a list, never implicit multiplication here.
        for (a, b) in zip(tokens, tokens.dropFirst()) {
            if case .num = a, case .num = b { return nil }
            if case .close = a, case .num = b { return nil }
            if case .num = a, case .open = b { return nil }
        }
        let compact = !e.contains(" ")
        if compact, e.range(of: #"^\d{1,2}[-/]\d{1,2}$"#, options: .regularExpression) != nil { return nil }
        if e.range(of: #"\d[-/]\d+[-/]\d"#, options: .regularExpression) != nil, Set(ops).isSubset(of: ["-", "/"]) { return nil }
        if Set(ops) == ["-"], e.filter(\.isNumber).count >= 7 { return nil }
        guard let expr = MathExpr.parse(e), !expr.usesX else { return nil }
        let v = expr.eval(0)
        guard v.isFinite, abs(v) < 1e15 else { return nil }
        return .math(v)
    }

    // MARK: format

    private static func formatter(_ digits: Int) -> NumberFormatter {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US")
        f.numberStyle = .decimal
        f.maximumFractionDigits = digits
        return f
    }

    static func number(_ v: Double, digits: Int = 4) -> String {
        let r = abs(v) < 1e-9 ? 0 : v
        return formatter(digits).string(from: NSNumber(value: r)) ?? String(r)
    }

    /// "$11.52" with the symbol typed, or dollars when none was.
    static func money(_ v: Double, _ symbol: String?) -> String { money(v, code: symbol.flatMap { Money.symbols[$0] } ?? "USD") }

    static func money(_ v: Double, code: String) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US")
        f.numberStyle = .currency
        f.currencyCode = code
        return f.string(from: NSNumber(value: v)) ?? "\(number(v, digits: 2)) \(code)"
    }

    static func clock(_ d: Date, _ tz: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = "h:mm a"
        return f.string(from: d)
    }

    /// "10:00 AM" today, else "Nov 12".
    static func asOf(_ d: Date, now: Date, zone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        if cal.isDate(d, inSameDayAs: now) { return clock(d, zone) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = "MMM d"
        return f.string(from: d)
    }

    static func match(_ pattern: String, _ s: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (1..<m.numberOfRanges).map { i in Range(m.range(at: i), in: s).map { String(s[$0]) } ?? "" }
    }
}

// MARK: units

extension Calc {
    struct Unit: Equatable {
        enum Kind { case length, weight, volume, speed, temperature }
        let kind: Kind
        let symbol: String
        /// The base unit per one of this (m, kg, L, m/s). Temperature uses `convert` instead.
        let factor: Double
        let names: [String]

        func convert(_ v: Double, to u: Unit) -> Double {
            guard kind == .temperature else { return v * factor / u.factor }
            let c: Double = switch symbol { case "°F": (v - 32) * 5 / 9; case "K": v - 273.15; default: v }
            return switch u.symbol { case "°F": c * 9 / 5 + 32; case "K": c + 273.15; default: c }
        }

        static func find(_ word: String) -> Unit? {
            let w = word.trimmingCharacters(in: .whitespaces)
            guard !w.isEmpty else { return nil }
            return all.first { $0.names.contains(w) }
        }

        static let all: [Unit] = [
            Unit(kind: .length, symbol: "mm", factor: 0.001, names: ["mm", "millimeter", "millimeters", "millimetre", "millimetres"]),
            Unit(kind: .length, symbol: "cm", factor: 0.01, names: ["cm", "cms", "centimeter", "centimeters", "centimetre", "centimetres"]),
            Unit(kind: .length, symbol: "m", factor: 1, names: ["m", "meter", "meters", "metre", "metres"]),
            Unit(kind: .length, symbol: "km", factor: 1000, names: ["km", "kms", "kilometer", "kilometers", "kilometre", "kilometres"]),
            Unit(kind: .length, symbol: "in", factor: 0.0254, names: ["in", "inch", "inches", "\""]),
            Unit(kind: .length, symbol: "ft", factor: 0.3048, names: ["ft", "foot", "feet", "'"]),
            Unit(kind: .length, symbol: "yd", factor: 0.9144, names: ["yd", "yds", "yard", "yards"]),
            Unit(kind: .length, symbol: "mi", factor: 1609.344, names: ["mi", "mile", "miles"]),
            Unit(kind: .weight, symbol: "mg", factor: 1e-6, names: ["mg", "milligram", "milligrams"]),
            Unit(kind: .weight, symbol: "g", factor: 0.001, names: ["g", "gram", "grams", "gr"]),
            Unit(kind: .weight, symbol: "kg", factor: 1, names: ["kg", "kgs", "kilo", "kilos", "kilogram", "kilograms"]),
            Unit(kind: .weight, symbol: "oz", factor: 0.028349523125, names: ["oz", "ounce", "ounces"]),
            Unit(kind: .weight, symbol: "lb", factor: 0.45359237, names: ["lb", "lbs", "pound", "pounds"]),
            Unit(kind: .weight, symbol: "st", factor: 6.35029318, names: ["st", "stone", "stones"]),
            Unit(kind: .volume, symbol: "ml", factor: 0.001, names: ["ml", "mls", "milliliter", "milliliters", "millilitre", "millilitres"]),
            Unit(kind: .volume, symbol: "L", factor: 1, names: ["l", "liter", "liters", "litre", "litres", "ltr"]),
            Unit(kind: .volume, symbol: "tsp", factor: 0.00492892159375, names: ["tsp", "teaspoon", "teaspoons"]),
            Unit(kind: .volume, symbol: "tbsp", factor: 0.01478676478125, names: ["tbsp", "tablespoon", "tablespoons"]),
            Unit(kind: .volume, symbol: "fl oz", factor: 0.0295735295625, names: ["fl oz", "floz", "fluid ounce", "fluid ounces"]),
            Unit(kind: .volume, symbol: "cups", factor: 0.2365882365, names: ["cup", "cups"]),
            Unit(kind: .volume, symbol: "pt", factor: 0.473176473, names: ["pt", "pint", "pints"]),
            Unit(kind: .volume, symbol: "qt", factor: 0.946352946, names: ["qt", "quart", "quarts"]),
            Unit(kind: .volume, symbol: "gal", factor: 3.785411784, names: ["gal", "gallon", "gallons"]),
            Unit(kind: .speed, symbol: "mph", factor: 0.44704, names: ["mph", "miles per hour", "mi/h"]),
            Unit(kind: .speed, symbol: "km/h", factor: 1 / 3.6, names: ["kmh", "km/h", "kph", "kmph", "kilometers per hour", "kilometres per hour"]),
            Unit(kind: .speed, symbol: "m/s", factor: 1, names: ["m/s", "mps", "meters per second", "metres per second"]),
            Unit(kind: .speed, symbol: "kn", factor: 0.514444, names: ["kn", "knot", "knots"]),
            Unit(kind: .temperature, symbol: "°C", factor: 1, names: ["c", "°c", "celsius", "centigrade"]),
            Unit(kind: .temperature, symbol: "°F", factor: 1, names: ["f", "°f", "fahrenheit"]),
            Unit(kind: .temperature, symbol: "K", factor: 1, names: ["kelvin"]),
        ]
    }

    enum Money {
        static let symbols: [String: String] = ["$": "USD", "€": "EUR", "£": "GBP", "₹": "INR", "¥": "JPY"]
        static let names: [String: String] = [
            "dollar": "USD", "dollars": "USD", "bucks": "USD", "usd": "USD", "us dollars": "USD",
            "euro": "EUR", "euros": "EUR", "pound": "GBP", "pounds": "GBP", "quid": "GBP",
            "rupee": "INR", "rupees": "INR", "rs": "INR", "yen": "JPY", "yuan": "CNY", "rmb": "CNY",
            "francs": "CHF", "pesos": "MXN", "canadian dollars": "CAD", "aussie dollars": "AUD", "australian dollars": "AUD",
        ]
        static let codes = Set(Locale.commonISOCurrencyCodes)

        /// "usd", "euros", "rupees"; nil for anything else. A weight in pounds reads as money only next to another currency.
        static func code(_ word: String) -> String? {
            let w = word.trimmingCharacters(in: .whitespaces)
            if let c = names[w] { return c }
            let up = w.uppercased()
            return w.count == 3 && codes.contains(up) ? up : nil
        }
    }

    struct Zone: Equatable {
        let tz: TimeZone
        /// "IST" as typed for a short name, "London" for a place.
        let label: String

        static func find(_ word: String) -> Zone? {
            let w = word.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ".", with: "")
            guard !w.isEmpty else { return nil }
            if let id = abbreviations[w], let tz = TimeZone(identifier: id) { return Zone(tz: tz, label: w.uppercased()) }
            let place = w.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
            if let id = places[w], let tz = TimeZone(identifier: id) { return Zone(tz: tz, label: w.count <= 3 ? w.uppercased() : place) }
            if let id = cities[w], let tz = TimeZone(identifier: id) { return Zone(tz: tz, label: place) }
            return nil
        }

        /// Short names people type, read as the place's zone, so "PST" in July still means California time.
        static let abbreviations: [String: String] = [
            "pst": "America/Los_Angeles", "pdt": "America/Los_Angeles", "pt": "America/Los_Angeles", "pacific": "America/Los_Angeles",
            "mst": "America/Denver", "mdt": "America/Denver", "mt": "America/Denver", "mountain": "America/Denver",
            "cst": "America/Chicago", "cdt": "America/Chicago", "ct": "America/Chicago", "central": "America/Chicago",
            "est": "America/New_York", "edt": "America/New_York", "et": "America/New_York", "eastern": "America/New_York",
            "gmt": "GMT", "utc": "UTC", "bst": "Europe/London", "cet": "Europe/Paris", "cest": "Europe/Paris",
            "ist": "Asia/Kolkata", "jst": "Asia/Tokyo", "kst": "Asia/Seoul", "sgt": "Asia/Singapore", "hkt": "Asia/Hong_Kong",
            "aest": "Australia/Sydney", "aedt": "Australia/Sydney", "gst": "Asia/Dubai", "hst": "Pacific/Honolulu", "akst": "America/Anchorage",
        ]

        static let places: [String: String] = [
            "nyc": "America/New_York", "ny": "America/New_York", "new york city": "America/New_York",
            "sf": "America/Los_Angeles", "san francisco": "America/Los_Angeles", "la": "America/Los_Angeles", "bay area": "America/Los_Angeles",
            "seattle": "America/Los_Angeles", "silicon valley": "America/Los_Angeles", "boston": "America/New_York", "miami": "America/New_York",
            "washington": "America/New_York", "dc": "America/New_York", "austin": "America/Chicago", "dallas": "America/Chicago",
            "houston": "America/Chicago", "uk": "Europe/London", "england": "Europe/London", "india": "Asia/Kolkata",
            "delhi": "Asia/Kolkata", "new delhi": "Asia/Kolkata", "mumbai": "Asia/Kolkata", "bangalore": "Asia/Kolkata", "bengaluru": "Asia/Kolkata",
            "hyderabad": "Asia/Kolkata", "chennai": "Asia/Kolkata", "pune": "Asia/Kolkata", "japan": "Asia/Tokyo", "china": "Asia/Shanghai",
            "beijing": "Asia/Shanghai", "germany": "Europe/Berlin", "france": "Europe/Paris", "spain": "Europe/Madrid", "italy": "Europe/Rome",
            "netherlands": "Europe/Amsterdam", "dubai": "Asia/Dubai", "uae": "Asia/Dubai", "abu dhabi": "Asia/Dubai", "korea": "Asia/Seoul",
            "australia": "Australia/Sydney", "melbourne": "Australia/Melbourne", "brazil": "America/Sao_Paulo", "sao paulo": "America/Sao_Paulo",
            "mexico": "America/Mexico_City", "mexico city": "America/Mexico_City", "canada": "America/Toronto", "vancouver": "America/Vancouver",
            "hawaii": "Pacific/Honolulu", "israel": "Asia/Jerusalem", "tel aviv": "Asia/Jerusalem", "philippines": "Asia/Manila",
            "manila": "Asia/Manila", "vietnam": "Asia/Ho_Chi_Minh", "thailand": "Asia/Bangkok", "indonesia": "Asia/Jakarta", "bali": "Asia/Makassar",
            "nigeria": "Africa/Lagos", "kenya": "Africa/Nairobi", "egypt": "Africa/Cairo", "south africa": "Africa/Johannesburg",
        ]

        /// Every city in the time zone database by its own name: "london", "tokyo", "los angeles", "lisbon".
        static let cities: [String: String] = {
            var out: [String: String] = [:]
            for id in TimeZone.knownTimeZoneIdentifiers {
                guard let last = id.split(separator: "/").last, id.contains("/") else { continue }
                out[last.replacingOccurrences(of: "_", with: " ").lowercased()] = id
            }
            return out
        }()
    }
}
