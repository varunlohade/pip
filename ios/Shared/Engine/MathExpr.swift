import Foundation

/// A small, safe expression parser for "y = x^2", "sin x", "2x + 1", "log(x)". Recursive descent; nothing is evaluated as code.
/// Grammar: sum := product (("+"|"-") product)* ; product := power (("*"|"/"|implicit) power)* ;
/// unary := "-" unary | power ; power := call ("^" unary)? ; call := fn power | atom ; atom := number | x | pi | e | "(" sum ")".
/// So -x^2 is -(x^2), 2^-x works, and "sin x^2" is sin(x^2).
indirect enum MathExpr: Equatable {
    case number(Double)
    case x
    case neg(MathExpr)
    case add(MathExpr, MathExpr), sub(MathExpr, MathExpr), mul(MathExpr, MathExpr), div(MathExpr, MathExpr), pow(MathExpr, MathExpr)
    case call(Fn, MathExpr)

    enum Fn: String, CaseIterable {
        case sin, cos, tan, sqrt, abs, ln, log, exp
        func apply(_ v: Double) -> Double {
            switch self {
            case .sin: Foundation.sin(v)
            case .cos: Foundation.cos(v)
            case .tan: Foundation.tan(v)
            case .sqrt: v.squareRoot()
            case .abs: Swift.abs(v)
            case .ln: Foundation.log(v)
            case .log: Foundation.log10(v)
            case .exp: Foundation.exp(v)
            }
        }
    }

    func eval(_ xv: Double) -> Double {
        switch self {
        case .number(let n): n
        case .x: xv
        case .neg(let a): -a.eval(xv)
        case .add(let a, let b): a.eval(xv) + b.eval(xv)
        case .sub(let a, let b): a.eval(xv) - b.eval(xv)
        case .mul(let a, let b): a.eval(xv) * b.eval(xv)
        case .div(let a, let b): a.eval(xv) / b.eval(xv)
        case .pow(let a, let b): Foundation.pow(a.eval(xv), b.eval(xv))
        case .call(let f, let a): f.apply(a.eval(xv))
        }
    }

    var usesX: Bool {
        switch self {
        case .number: false
        case .x: true
        case .neg(let a), .call(_, let a): a.usesX
        case .add(let a, let b), .sub(let a, let b), .mul(let a, let b), .div(let a, let b), .pow(let a, let b): a.usesX || b.usesX
        }
    }

    /// Nil for anything it does not fully understand, so "plot twist" or "graph paper" is not a graph.
    static func parse(_ text: String) -> MathExpr? {
        var p = Parser(tokens: tokenize(text) ?? [])
        guard !p.tokens.isEmpty, let e = p.sum(), p.i == p.tokens.count else { return nil }
        return e
    }

    enum Token: Equatable { case num(Double), x, word(String), op(Character), open, close }

    static func tokenize(_ text: String) -> [Token]? {
        var out: [Token] = []
        let chars = Array(text.lowercased().replacingOccurrences(of: "\u{00B2}", with: "^2").replacingOccurrences(of: "\u{00B3}", with: "^3")
            .replacingOccurrences(of: "\u{00D7}", with: "*").replacingOccurrences(of: "\u{2212}", with: "-").replacingOccurrences(of: "**", with: "^"))
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if c.isNumber || c == "." {
                var j = i
                while j < chars.count, chars[j].isNumber || chars[j] == "." { j += 1 }
                guard let v = Double(String(chars[i..<j])) else { return nil }
                out.append(.num(v)); i = j; continue
            }
            if c.isLetter {
                var j = i
                while j < chars.count, chars[j].isLetter { j += 1 }
                let w = String(chars[i..<j])
                i = j
                if w == "x" { out.append(.x); continue }
                if w == "pi" || w == "\u{03C0}" { out.append(.num(Double.pi)); continue }
                if w == "e" { out.append(.num(M_E)); continue }
                if Fn(rawValue: w) != nil { out.append(.word(w)); continue }
                // "xx" from "x x" is rare; "sinx" is common: a function name glued to x.
                if let f = Fn.allCases.first(where: { w == $0.rawValue + "x" }) { out += [.word(f.rawValue), .x]; continue }
                return nil
            }
            switch c {
            case "+", "-", "*", "/", "^": out.append(.op(c))
            case "(": out.append(.open)
            case ")": out.append(.close)
            default: return nil
            }
            i += 1
        }
        return out
    }

    struct Parser {
        let tokens: [Token]
        var i = 0
        var depth = 0

        mutating func peek() -> Token? { i < tokens.count ? tokens[i] : nil }

        mutating func sum() -> MathExpr? {
            guard var left = product() else { return nil }
            while case .op(let o)? = peek(), o == "+" || o == "-" {
                i += 1
                guard let right = product() else { return nil }
                left = o == "+" ? .add(left, right) : .sub(left, right)
            }
            return left
        }

        mutating func product() -> MathExpr? {
            guard var left = unary() else { return nil }
            while let t = peek() {
                if case .op(let o) = t, o == "*" || o == "/" {
                    i += 1
                    guard let right = unary() else { return nil }
                    left = o == "*" ? .mul(left, right) : .div(left, right)
                } else if t == .x || t == .open || { if case .word = t { return true }; if case .num = t { return true }; return false }() {
                    // Implicit multiplication: 2x, 3(x+1), x sin x.
                    guard let right = power() else { return nil }
                    left = .mul(left, right)
                } else {
                    break
                }
            }
            return left
        }

        mutating func power() -> MathExpr? {
            guard let base = call() else { return nil }
            if case .op("^")? = peek() {
                i += 1
                guard let exp = unary() else { return nil }
                return .pow(base, exp)
            }
            return base
        }

        mutating func unary() -> MathExpr? {
            depth += 1
            defer { depth -= 1 }
            guard depth < 40 else { return nil }
            if case .op("-")? = peek() { i += 1; return unary().map { .neg($0) } }
            if case .op("+")? = peek() { i += 1; return unary() }
            return power()
        }

        mutating func call() -> MathExpr? {
            if case .word(let w)? = peek(), let f = Fn(rawValue: w) {
                i += 1
                // "sin x" binds only the next atom; "sin(x+1)" the bracket; "sin x^2" is sin(x^2).
                guard let arg = power() else { return nil }
                return .call(f, arg)
            }
            return atom()
        }

        mutating func atom() -> MathExpr? {
            guard let t = peek() else { return nil }
            switch t {
            case .num(let v): i += 1; return .number(v)
            case .x: i += 1; return .x
            case .open:
                depth += 1
                guard depth < 20 else { return nil }
                i += 1
                guard let e = sum(), peek() == .close else { return nil }
                i += 1
                depth -= 1
                return e
            default: return nil
            }
        }
    }
}
