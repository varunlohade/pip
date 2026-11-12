import SwiftUI
import UIKit

// A replica of the iOS 26 system keyboard: measured geometry, light/dark palettes, multi-touch keys,
// callout balloons, shift and caps lock, 123 and #+= layouts.

/// `digits` is the pad for number, phone and code fields.
enum KeyLayout: Equatable { case letters, numbers, symbols, digits }

enum KeyKind: Equatable {
    case char(String)
    case shift
    case delete
    case mode(KeyLayout)
    case space
    case ret
    case globe
}

struct KeyCap: Identifiable, Equatable {
    let id: String
    let kind: KeyKind
    let frame: CGRect
    var a11y: String
}

enum KeyboardGeometry {
    typealias M = Theme.SystemKeyboard

    static func rowTop(_ row: Int, _ s: M.Sizes) -> CGFloat { M.barHeight + CGFloat(row) * (s.keyHeight + s.rowGap) }

    static func keys(layout: KeyLayout, width w: CGFloat, globe: Bool, currency: String, field: FieldKind = .text) -> [KeyCap] {
        let s = M.sizes(for: w)
        if layout == .digits { return digitPad(width: w, globe: globe, field: field) }
        func rowTop(_ r: Int) -> CGFloat { Self.rowTop(r, s) }
        let keyW = (w - 2 * M.sideInset - 9 * M.keyGap) / 10
        let pitch = keyW + M.keyGap
        var out: [KeyCap] = []
        func row(_ chars: [String], _ r: Int, startX: CGFloat, width kw: CGFloat = keyW, gap: CGFloat = M.keyGap) {
            for (i, c) in chars.enumerated() {
                let f = CGRect(x: startX + CGFloat(i) * (kw + gap), y: rowTop(r), width: kw, height: s.keyHeight)
                out.append(KeyCap(id: "k.\(r).\(c)", kind: .char(c), frame: f, a11y: c))
            }
        }
        let rows: [[String]]
        switch layout {
        case .letters: rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"].map { $0.map(String.init) }
        case .numbers: rows = [Array("1234567890").map(String.init), ["-", "/", ":", ";", "(", ")", currency, "&", "@", "\""], [".", ",", "?", "!", "'"]]
        case .symbols: rows = [["[", "]", "{", "}", "#", "%", "^", "*", "+", "="], ["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"], [".", ",", "?", "!", "'"]]
        case .digits: rows = []
        }
        row(rows[0], 0, startX: M.sideInset)
        row(rows[1], 1, startX: layout == .letters ? M.sideInset + pitch / 2 : M.sideInset)

        // Row 3: shift (or #+= / 123), the middle keys, delete.
        let r3 = CGRect(x: M.sideInset, y: rowTop(2), width: s.wideKey, height: s.keyHeight)
        switch layout {
        case .letters:
            out.append(KeyCap(id: "shift", kind: .shift, frame: r3, a11y: "shift"))
            row(rows[2], 2, startX: M.sideInset + 1.5 * pitch)
        case .numbers, .symbols, .digits:
            out.append(KeyCap(id: "mode.alt", kind: .mode(layout == .numbers ? .symbols : .numbers), frame: r3,
                              a11y: layout == .numbers ? "more symbols" : "numbers"))
            let start = M.sideInset + 1.5 * pitch
            let span = w - 2 * start
            row(rows[2], 2, startX: start, width: (span - 4 * M.keyGap) / 5)
        }
        out.append(KeyCap(id: "delete", kind: .delete, frame: CGRect(x: w - M.sideInset - s.wideKey, y: rowTop(2), width: s.wideKey, height: s.keyHeight), a11y: "delete"))

        // Row 4: 123/ABC, globe (only when iOS does not draw its own), space, return.
        let y4 = rowTop(3)
        out.append(KeyCap(id: "mode", kind: .mode(layout == .letters ? .numbers : .letters),
                          frame: CGRect(x: M.sideInset, y: y4, width: s.modeKey, height: s.keyHeight), a11y: "more"))
        var x = M.sideInset + s.modeKey + M.keyGap
        if globe {
            out.append(KeyCap(id: "globe", kind: .globe, frame: CGRect(x: x, y: y4, width: s.modeKey, height: s.keyHeight), a11y: "next keyboard"))
            x += s.modeKey + M.keyGap
        }
        let retX = w - M.sideInset - s.returnKey
        // Email and link fields: two keys between space and return ("@ ." or ". /").
        var spaceEnd = retX - M.keyGap
        for c in field.spaceKeys.reversed() {
            spaceEnd -= keyW
            out.append(KeyCap(id: "k.3.\(c)", kind: .char(c), frame: CGRect(x: spaceEnd, y: y4, width: keyW, height: s.keyHeight), a11y: c))
            spaceEnd -= M.keyGap
        }
        out.append(KeyCap(id: "space", kind: .space, frame: CGRect(x: x, y: y4, width: spaceEnd - x, height: s.keyHeight), a11y: "space"))
        out.append(KeyCap(id: "return", kind: .ret, frame: CGRect(x: retX, y: y4, width: s.returnKey, height: s.keyHeight), a11y: "return"))
        return out
    }

    /// Number, phone and code fields: 1-9 in three rows, then the pad's extra key, 0 and delete.
    /// The extra key is "." for decimals, "+" for phones, else the globe when iOS draws none.
    static func digitPad(width w: CGFloat, globe: Bool, field: FieldKind) -> [KeyCap] {
        let s = M.sizes(for: w)
        let keyW = (w - 2 * M.sideInset - 2 * M.keyGap) / 3
        var out: [KeyCap] = []
        func frame(_ r: Int, _ c: Int) -> CGRect {
            CGRect(x: M.sideInset + CGFloat(c) * (keyW + M.keyGap), y: rowTop(r, s), width: keyW, height: s.keyHeight)
        }
        for (i, d) in "123456789".enumerated() {
            out.append(KeyCap(id: "k.\(i / 3).\(d)", kind: .char(String(d)), frame: frame(i / 3, i % 3), a11y: String(d)))
        }
        switch field {
        case .digits(.decimal): out.append(KeyCap(id: "k.3..", kind: .char("."), frame: frame(3, 0), a11y: "point"))
        case .digits(.phone): out.append(KeyCap(id: "k.3.+", kind: .char("+"), frame: frame(3, 0), a11y: "plus"))
        default: if globe { out.append(KeyCap(id: "globe", kind: .globe, frame: frame(3, 0), a11y: "next keyboard")) }
        }
        out.append(KeyCap(id: "k.3.0", kind: .char("0"), frame: frame(3, 1), a11y: "0"))
        out.append(KeyCap(id: "delete", kind: .delete, frame: frame(3, 2), a11y: "delete"))
        return out
    }

    /// The letter keys of the letters layout, for the touch decoder.
    static func touchKeys(_ keys: [KeyCap]) -> [TouchKey] {
        keys.compactMap { k in
            guard case .char(let c) = k.kind, c.count == 1, let ch = c.first, LanguageModel.index(ch) != nil,
                  let row = Int(k.id.split(separator: ".").dropFirst().first ?? "") else { return nil }
            return TouchKey(letter: ch, frame: k.frame, row: row)
        }
    }

    /// The key under a touch: its frame grown by half the gaps, else the nearest key.
    static func key(at p: CGPoint, in keys: [KeyCap]) -> KeyCap? {
        if let hit = keys.first(where: { $0.frame.insetBy(dx: -M.keyGap / 2, dy: -M.rowGap / 2).contains(p) }) { return hit }
        return keys.min { dist(p, $0.frame) < dist(p, $1.frame) }
    }

    private static func dist(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX), dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return dx * dx + dy * dy
    }
}

/// UIKit surface for real multi-touch: fast two-thumb typing needs overlapping touches.
struct TouchSurface: UIViewRepresentable {
    let began: (ObjectIdentifier, CGPoint) -> Void
    let moved: (ObjectIdentifier, CGPoint) -> Void
    let ended: (ObjectIdentifier, CGPoint) -> Void
    let cancelled: (ObjectIdentifier) -> Void

    final class View: UIView {
        var surface: TouchSurface?
        override init(frame: CGRect) {
            super.init(frame: frame)
            isMultipleTouchEnabled = true
            backgroundColor = .clear
        }
        required init?(coder: NSCoder) { fatalError() }
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            for t in touches { surface?.began(ObjectIdentifier(t), t.location(in: self)) }
        }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            for t in touches { surface?.moved(ObjectIdentifier(t), t.location(in: self)) }
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            for t in touches { surface?.ended(ObjectIdentifier(t), t.location(in: self)) }
        }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            for t in touches { surface?.cancelled(ObjectIdentifier(t)) }
        }
    }

    func makeUIView(context: Context) -> View { let v = View(); v.surface = self; return v }
    func updateUIView(_ v: View, context: Context) { v.surface = self }
}

struct SystemKeysView: View {
    @ObservedObject var model: KeyboardModel
    typealias M = Theme.SystemKeyboard

    var body: some View {
        GeometryReader { geo in
            let p = model.isDark ? M.dark : M.light
            let keys = KeyboardGeometry.keys(layout: model.layout, width: geo.size.width,
                                             globe: model.host?.needsGlobeKey ?? false,
                                             currency: Locale.current.currencySymbol ?? "$", field: model.field)
            ZStack(alignment: .topLeading) {
                ForEach(keys) { key in
                    KeyCapView(key: key, model: model, palette: p,
                               pressed: model.pressedKeys.contains(key.id), hidden: model.calloutKeyID == key.id)
                        .frame(width: key.frame.width, height: key.frame.height)
                        .position(x: key.frame.midX, y: key.frame.midY)
                }
                if let id = model.calloutKeyID, let key = keys.first(where: { $0.id == id }), case .char(let c) = key.kind {
                    Callout(key: key.frame, width: geo.size.width)
                        .fill(p.key)
                        .shadow(color: .black.opacity(model.isDark ? 0.5 : 0.22), radius: 1.5, y: 1)
                        .overlay(alignment: .topLeading) {
                            let b = Callout.bubble(key: key.frame, width: geo.size.width)
                            Text(model.display(c)).font(M.callout).foregroundStyle(p.label)
                                .frame(width: b.width, height: b.height).offset(x: b.minX, y: b.minY)
                        }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                TouchSurface(
                    began: { id, pt in
                        let p = pt.offsetBy(M.barHeight - 6)
                        model.keyboardWidth = geo.size.width
                        if let k = model.key(for: id, at: p, in: keys) { model.touchBegan(id, k, at: p) }
                    },
                    moved: { id, pt in let p = pt.offsetBy(M.barHeight - 6); if let k = model.key(for: id, at: p, in: keys) { model.touchMoved(id, k, at: p) } },
                    ended: { id, _ in model.touchEnded(id) },
                    cancelled: { id in model.touchCancelled(id) }
                )
                .frame(width: geo.size.width, height: geo.size.height - M.barHeight + 6)
                .offset(y: M.barHeight - 6)
                .accessibilityHidden(true)
            }
        }
    }
}

private extension CGPoint {
    func offsetBy(_ dy: CGFloat) -> CGPoint { CGPoint(x: x, y: y + dy) }
}

struct KeyCapView: View {
    let key: KeyCap
    @ObservedObject var model: KeyboardModel
    let palette: Theme.SystemKeyboard.Palette
    let pressed: Bool
    let hidden: Bool
    typealias M = Theme.SystemKeyboard

    var body: some View {
        let returnOff = key.kind == .ret && !model.returnEnabled
        let isReturnAccent = key.kind == .ret && model.returnStyle.accent && !returnOff
        RoundedRectangle(cornerRadius: M.cornerRadius, style: .continuous)
            .fill(isReturnAccent ? palette.accent : pressed && !isChar ? palette.keyPressed : palette.key)
            .overlay {
                label.foregroundStyle(isReturnAccent ? .white : returnOff ? palette.secondaryLabel : palette.label)
                    .opacity(model.trackpad ? 0 : 1)
            }
            .opacity(hidden ? 0 : 1)
            .accessibilityElement()
            .accessibilityLabel(key.a11y)
            .accessibilityAddTraits(.isKeyboardKey)
            .accessibilityIdentifier(key.id == "mode" ? "pip.more" : key.id)
            .accessibilityAction { model.activate(key) }
    }

    private var isChar: Bool { if case .char = key.kind { return true } else { return false } }

    @ViewBuilder private var label: some View {
        switch key.kind {
        case .char(let c):
            Text(c == "'" ? "’" : c == "\"" ? "”" : model.display(c)).font(model.layout == .letters ? M.letter : M.symbol)
                .offset(y: model.layout == .letters && model.shift == .off ? -1.5 : 0)
        case .shift:
            Image(systemName: model.shift == .locked ? "capslock.fill" : model.shift == .once ? "shift.fill" : "shift").font(M.icon)
        case .delete:
            Image(systemName: "delete.left").font(M.icon)
        case .mode(let to):
            Text(to == .letters ? "ABC" : to == .numbers ? "123" : "#+=").font(to == .symbols ? M.smallMode : M.mode)
        case .space:
            EmptyView()
        case .ret:
            if let text = model.returnStyle.title { Text(text).font(M.mode) } else { Image(systemName: "return.left").font(M.icon) }
        case .globe:
            Image(systemName: "globe").font(M.icon)
        }
    }
}

/// The accents over a held letter, inside the keyboard. The picked one is filled with the accent colour.
struct AccentPopupView: View {
    let popup: AccentPopup
    @ObservedObject var model: KeyboardModel
    let palette: Theme.SystemKeyboard.Palette
    typealias M = Theme.SystemKeyboard

    var body: some View {
        let first = popup.cells.first ?? .zero
        let box = popup.cells.reduce(first) { $0.union($1) }.insetBy(dx: -4, dy: -4)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 11, style: .continuous).fill(palette.key)
                .shadow(color: .black.opacity(model.isDark ? 0.5 : 0.25), radius: 3, y: 1)
                .frame(width: box.width, height: box.height)
                .offset(x: box.minX, y: box.minY)
            ForEach(Array(popup.options.enumerated()), id: \.offset) { i, option in
                let cell = popup.cells[i]
                let on = i == popup.selected
                Text(model.display(option)).font(M.letter)
                    .foregroundStyle(on ? .white : palette.label)
                    .frame(width: cell.width, height: cell.height)
                    .background(on ? palette.accent : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .offset(x: cell.minX, y: cell.minY)
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel(popup.options[popup.selected])
        .accessibilityIdentifier("accents")
    }
}

/// The enlarged-letter balloon: a wide rounded bubble over the key, joined to it by a curved neck.
struct Callout: Shape {
    let key: CGRect
    let width: CGFloat

    static func bubble(key: CGRect, width: CGFloat) -> CGRect {
        let bw = key.width + 22
        let rise = min(52, key.minY - 2)
        let x = min(max(key.midX - bw / 2, 2), width - bw - 2)
        return CGRect(x: x, y: key.minY - rise, width: bw, height: rise + 4)
    }

    func path(in _: CGRect) -> Path {
        let b = Self.bubble(key: key, width: width)
        let r: CGFloat = 11, kr = Theme.SystemKeyboard.cornerRadius
        let neck = key.minY + 14
        var p = Path()
        p.move(to: CGPoint(x: b.minX + r, y: b.minY))
        p.addLine(to: CGPoint(x: b.maxX - r, y: b.minY))
        p.addQuadCurve(to: CGPoint(x: b.maxX, y: b.minY + r), control: CGPoint(x: b.maxX, y: b.minY))
        p.addLine(to: CGPoint(x: b.maxX, y: b.maxY - 6))
        p.addCurve(to: CGPoint(x: key.maxX, y: neck), control1: CGPoint(x: b.maxX, y: b.maxY + 2), control2: CGPoint(x: key.maxX, y: neck - 8))
        p.addLine(to: CGPoint(x: key.maxX, y: key.maxY - kr))
        p.addQuadCurve(to: CGPoint(x: key.maxX - kr, y: key.maxY), control: CGPoint(x: key.maxX, y: key.maxY))
        p.addLine(to: CGPoint(x: key.minX + kr, y: key.maxY))
        p.addQuadCurve(to: CGPoint(x: key.minX, y: key.maxY - kr), control: CGPoint(x: key.minX, y: key.maxY))
        p.addLine(to: CGPoint(x: key.minX, y: neck))
        p.addCurve(to: CGPoint(x: b.minX, y: b.maxY - 6), control1: CGPoint(x: key.minX, y: neck - 8), control2: CGPoint(x: b.minX, y: b.maxY + 2))
        p.addLine(to: CGPoint(x: b.minX, y: b.minY + r))
        p.addQuadCurve(to: CGPoint(x: b.minX + r, y: b.minY), control: CGPoint(x: b.minX, y: b.minY))
        p.closeSubpath()
        return p
    }
}
