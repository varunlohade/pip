import Foundation

/// What the bar offers when nothing is typed: up to 3 chips from data the keyboard already holds. No server call.
enum ReadyChips {
    struct Input {
        var copiedAvailable = false
        var nextUp: Appointment?
        var today: [Appointment] = []
    }

    static func build(_ i: Input) -> [BarItems.Item] {
        typealias Item = BarItems.Item
        var out: [Item] = []
        if i.copiedAvailable { out.append(Item(id: "copied", title: "Use copied message", action: .useCopied)) }
        if let a = i.nextUp { out.append(Item(id: "next", title: "Next: \(a.time)", detail: a.title, tone: .secondary)) }
        if !i.today.isEmpty {
            let n = i.today.count
            out.append(Item(id: "today", title: "Today", detail: "\(n) event\(n == 1 ? "" : "s")", action: .today))
        }
        out.append(Item(id: "notes", title: "Notes", action: .notes))
        return Array(out.prefix(3))
    }
}
