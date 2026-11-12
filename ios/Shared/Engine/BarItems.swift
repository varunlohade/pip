import Foundation

/// What the suggestion bar shows, slot by slot. Pure: the view maps tones to colors and actions to model calls.
enum BarItems {
    enum Tone: Equatable { case label, secondary, accent, paid, due }

    enum Action: Equatable {
        case useCopied
        case undo
        case openCalm
        /// On-device actions: add an event, a reminder or a note, then undo it.
        case smart(SmartChip)
        case undoSmart
        case today
        case notes
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
        var now = Date()
    }

    static func build(_ s: State) -> [Item] {
        if !s.hasFullAccess { return [Item(id: "info", title: "Allow Full Access in Settings for \(AppConfig.keyboardName)", tone: .secondary)] }
        if !s.paired { return [Item(id: "info", title: "Open \(AppConfig.displayName) to pair", tone: .secondary)] }
        if let u = s.undo {
            return [Item(id: "written", title: u.label, tone: .paid), Item(id: "undo", title: "Undo", action: .undo)]
        }
        if let a = s.added {
            return [Item(id: "added", title: a, tone: .paid), Item(id: "undo", title: "Undo", action: .undoSmart)]
        }
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
            // A chip about the typed words gets the room; the day's chips wait for an empty field.
            out += smart
            if smart.isEmpty, s.copiedAvailable { out.append(Item(id: "copied", title: "Use copied message", action: .useCopied)) }
            if smart.isEmpty, let a = s.nextUp { out.append(Item(id: "next", title: "Next: \(a.time)", detail: a.title, tone: .secondary)) }
            out = Array(out.prefix(3))
        case .working(let text):
            out.append(Item(id: "working", title: text, tone: .secondary))
        case .done(let text):
            out.append(Item(id: "done", title: text, tone: .secondary))
        case .error(let text):
            out.append(Item(id: "error", title: text, tone: .due))
        }
        return out
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
