import Foundation

/// What the suggestion bar shows, slot by slot. Pure: the view maps tones to colors and actions to model calls.
enum BarItems {
    enum Tone: Equatable { case label, secondary, accent, success, warning }

    enum Action: Equatable {
        case useCopied
        case undo
        case openCalm
        /// On-device actions: add an event, a reminder or a note, then undo it.
        case smart(SmartChip)
        case undoSmart
        case today
        case notes
        /// Opens the card for the meaning or answer on the bar.
        case explain
        /// Opens the drawing panel for the topic on the bar, without the text card.
        case draw
        /// Proposes the typed payment and opens the app to approve it.
        case pay
        /// Types the "Sent you 5 USDC ✓ <link>" line.
        case insertPaid
    }

    struct Item: Equatable, Identifiable {
        let id: String
        var title: String
        var detail: String? = nil
        var tone: Tone = .label
        var action: Action? = nil
        /// The typed words that caused the chip. The bar shows them quoted, in the accent color, before the title.
        var trigger: String? = nil
        /// A shorter title to sit beside the trigger when the full one does not fit: "Add to calendar".
        var short: String? = nil
    }

    /// A smart chip and whether its store can take it now.
    struct Smart {
        let chip: SmartChip
        let access: SmartAccess
    }

    struct State {
        var hasFullAccess: Bool
        var paired: Bool
        var undo: WriteUndo?
        var hasCalmOffer: Bool
        var bar: BarState
        var copiedAvailable: Bool
        var nextUp: Appointment?
        var smart: [Smart] = []
        /// The line after a smart chip was added; Undo removes it.
        var added: String?
        /// Nothing is typed: the bar shows ready chips.
        var fieldEmpty = false
        var ready = ReadyChips.Input()
        /// "btw" → "by the way": the answer to what the last sentence asks. It comes before every other chip.
        var explain: Item?
        /// "Draw it" beside the explain chip, for a topic the server can draw.
        var draw: Item?
        /// The current line holds a secret: no AI chips, one muted line instead.
        var secret = false
        /// "Send 5 USDC to ana.testnet · Approve in Pip". It comes first while typing.
        var pay: Item?
        /// A payment the app just sent, with Insert.
        var paid: Item?
        var now = Date()
    }

    static func build(_ s: State) -> [Item] {
        // A dictionary meaning works offline, so it shows even before Full Access or pairing.
        if !s.hasFullAccess { return s.explain.map { [$0] } ?? [Item(id: "info", title: "Allow Full Access in Settings for \(AppConfig.keyboardName)", tone: .secondary)] }
        if !s.paired { return s.explain.map { [$0] } ?? [Item(id: "info", title: "Open \(AppConfig.displayName) to sign in", tone: .secondary)] }
        if let u = s.undo {
            return [Item(id: "written", title: u.label, tone: .success), Item(id: "undo", title: "Undo", action: .undo)]
        }
        if let a = s.added {
            return [Item(id: "added", title: a, tone: .success), Item(id: "undo", title: "Undo", action: .undoSmart)]
        }
        // A new payment typed in the field wins over the last one's receipt line.
        if let p = s.paid, s.pay == nil { return [p, Item(id: "paid.insert", title: "Insert", action: .insertPaid)] }
        var out: [Item] = []
        if s.hasCalmOffer {
            out.append(Item(id: "calm", title: "Calm reply", detail: "they sound upset", action: .openCalm))
        }
        if case .idle = s.bar, s.fieldEmpty {
            return Array((out + ReadyChips.build(s.ready)).prefix(3))
        }
        let smart = smartItems(s.smart, now: s.now)
        switch s.bar {
        case .idle:
            // A secret in the line: only a sum worked out on the phone, and the quiet line. Nothing else about the typing.
            if s.secret {
                if let e = s.explain, s.draw == nil { out.append(e) }
                return out + [Item(id: "secret", title: secretLine, tone: .secondary)]
            }
            // A chip about the typed words gets the room; the day's chips wait for an empty field.
            if let p = s.pay { out.append(p) }
            if let e = s.explain { out.append(e) }
            if let d = s.draw { out.append(d) }
            out += smart
            let aboutTyping = !smart.isEmpty || s.explain != nil || s.draw != nil || s.pay != nil
            if !aboutTyping, s.copiedAvailable { out.append(Item(id: "copied", title: "Use copied message", action: .useCopied)) }
            if !aboutTyping, let a = s.nextUp { out.append(Item(id: "next", title: "Next: \(a.time)", detail: a.title, tone: .secondary)) }
            out = Array(out.prefix(3))
        case .working(let text):
            out.append(Item(id: "working", title: text, tone: .secondary))
        case .done(let text):
            out.append(Item(id: "done", title: text, tone: .secondary))
        case .error(let text):
            out.append(Item(id: "error", title: text, tone: .warning))
        }
        return out
    }

    static let secretLine = "Sensitive text detected. AI is off."

    /// A chip the ✕ hides: an offer about the typing or the copy. Lines, Undo and the day's chips stay.
    static func dismissible(_ item: Item) -> Bool {
        ["copied", "calm", "explain", "draw", "pay", "paid"].contains(item.id) || item.id.hasPrefix("smart.")
    }

    /// Each smart chip, or the one line that says which permission it waits for. The line opens nothing: a keyboard cannot.
    static func smartItems(_ list: [Smart], now: Date) -> [Item] {
        var out: [Item] = []
        for s in list {
            let item: Item
            switch s.access {
            case .ready:
                item = Item(id: s.chip.id, title: s.chip.label(now: now), action: .smart(s.chip), trigger: s.chip.trigger, short: s.chip.shortLabel)
            case .needsFullAccess:
                item = Item(id: "allow.full", title: "Allow Full Access for \(AppConfig.keyboardName)", tone: .secondary)
            case .needsPermission:
                let place = s.chip.place == .calendar ? "Calendar" : "Reminders"
                item = Item(id: "allow.\(place)", title: "Allow \(place) in \(AppConfig.displayName)", tone: .secondary)
            }
            if !out.contains(where: { $0.id == item.id }) { out.append(item) }
        }
        return out
    }

    static func string(_ chip: Chip, _ key: String) -> String? {
        if case .string(let v)? = chip.payload[key], !v.isEmpty { return v }
        return nil
    }
}
