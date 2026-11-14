import SwiftUI

/// The whole keyboard: an iOS-style predictive bar with our chips, then the system-replica keys.
struct KeyboardView: View {
    @ObservedObject var model: KeyboardModel
    typealias M = Theme.SystemKeyboard

    var body: some View {
        let p = model.isDark ? M.dark : M.light
        keyboard(p)
            .background(p.bed)
            .environment(\.colorScheme, model.isDark ? .dark : .light)
    }

    private func keyboard(_ p: M.Palette) -> some View {
        ZStack(alignment: .top) {
            p.bed
            if let panel = model.explainPanel {
                Group {
                    switch panel {
                    case .card(let offer): ExplainCardView(model: model, offer: offer, palette: p)
                    case .visual(let state): VisualPanelView(model: model, state: state, palette: p)
                    }
                }
                .padding(.top, M.barHeight).padding(.bottom, M.bottomInset)
            } else if let c = model.calendar {
                CalendarPanelView(model: model, panel: c, palette: p).padding(.top, M.barHeight).padding(.bottom, M.bottomInset)
            } else if model.notesOpen {
                NotesPanel(model: model, palette: p).padding(.top, M.barHeight).padding(.bottom, M.bottomInset)
            } else if model.writeOpen {
                WritePanelView(model: model, palette: p).padding(.top, M.barHeight).padding(.bottom, M.bottomInset)
            } else {
                SystemKeysView(model: model)
            }
            SuggestionBar(model: model, palette: p)
                .frame(height: M.barHeight)
            // Over the bar too: a top-row letter's accents reach into it.
            if let a = model.accents {
                AccentPopupView(popup: a, model: model, palette: p)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(height: model.keyboardHeight)
    }
}

/// Sits where iOS shows predictive text: same height, centred text, 1 pt dividers. Empty when there is nothing to say.
struct SuggestionBar: View {
    @ObservedObject var model: KeyboardModel
    let palette: Theme.SystemKeyboard.Palette
    typealias M = Theme.SystemKeyboard

    var body: some View {
        if let c = model.calendar {
            CalendarBar(model: model, panel: c, palette: palette)
                .padding(.bottom, M.barHeight - 2 * 23.8)
        } else {
            chipsBar
        }
    }

    private var chipsBar: some View {
        let items = model.barItems
        return HStack(spacing: 0) {
            if let panel = model.explainPanel {
                Buddy(size: 30).padding(.leading, 6)
                // The canvas shows "Step n of m"; the title keeps it for VoiceOver.
                Text(panelSubject(panel)).font(.system(size: 15)).foregroundStyle(Theme.Color.text1)
                    .lineLimit(1).truncationMode(.tail)
                    .padding(.horizontal, 13).frame(height: 36)
                    .background(Theme.Color.ice, in: Capsule())
                    .padding(.leading, 6)
                    .accessibilityLabel(panelTitle(panel))
                    .accessibilityIdentifier("explain.title")
                Spacer(minLength: 4)
                barButton("keyboard", id: "explain.close", label: "Keyboard", action: model.closeExplain)
            } else if !model.notesOpen, !model.writeOpen, let explain = items.first, explain.id == "explain" {
                dismissButton
                explainRow(explain)
                Spacer(minLength: 0)
            } else if model.notesOpen {
                Text("Notes").font(M.prediction.weight(.medium)).foregroundStyle(palette.label).padding(.leading, Theme.Space.s)
                Spacer()
                barButton("plus", id: "notes.add", label: "Save typed text as a note", action: model.saveNote)
                    .disabled(!model.canSaveNote)
                    .opacity(model.canSaveNote ? 1 : 0.3)
            } else if model.writeOpen {
                Text("Rewrite").font(M.prediction.weight(.medium)).foregroundStyle(palette.label).padding(.leading, Theme.Space.s)
                Spacer()
            } else if showsWords {
                wordRow
            } else {
                if showsFix || items.contains(where: BarItems.dismissible) { dismissButton }
                HStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                        if i > 0 { Rectangle().fill(palette.divider).frame(width: 1, height: M.dividerHeight) }
                        Slot(item: item, palette: palette, action: item.action.map { a in { model.perform(a) } },
                             width: item.id == "undo" ? 80 : nil)
                            .accessibilityIdentifier("chip.\(item.id)")
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            if showsFix, let plan = model.fixPlan {
                Rectangle().fill(palette.divider).frame(width: 1, height: M.dividerHeight)
                Button(action: model.fix) {
                    Text(plan.title).font(M.prediction.weight(.medium)).foregroundStyle(palette.accent)
                        .lineLimit(1).fixedSize()
                        .padding(.horizontal, Theme.Space.xs)
                        .frame(maxHeight: .infinity).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(plan.title)
                .accessibilityIdentifier("chip.fix")
                .transition(.opacity)
            }
            if model.paired && !showsWords && !model.notesOpen && model.explainPanel == nil && model.explainOffer == nil {
                Rectangle().fill(palette.divider).frame(width: 1, height: M.dividerHeight)
                barButton(model.writeOpen ? "keyboard" : "wand.and.stars", id: "write.toggle", label: model.writeOpen ? "Keyboard" : "Rewrite", action: model.toggleWrite)
            }
            // Notes live in the App Group, which the keyboard reaches only with Full Access.
            if model.hasFullAccess && !showsWords && !model.writeOpen && model.explainPanel == nil && model.explainOffer == nil {
                Rectangle().fill(palette.divider).frame(width: 1, height: M.dividerHeight)
                barButton(model.notesOpen ? "keyboard" : "note.text", id: "notes.toggle", label: model.notesOpen ? "Keyboard" : "Notes", action: model.toggleNotes)
                if !model.notesOpen {
                    barButton("calendar", id: "calendar.toggle", label: "Calendar", action: model.toggleCalendar)
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, M.barHeight - 2 * 23.8)
        .animation(Theme.Motion.chipAppear, value: items.map(\.id))
        .animation(Theme.Motion.chipAppear, value: showsFix)
    }

    /// B2: the bar holds the answer in an ice bubble while a panel is open.
    private func panelSubject(_ p: ExplainPanel) -> String {
        switch p {
        case .card(let o): "\u{201C}\(o.subject)\u{201D}"
        case .visual(let v): v.summary
        }
    }

    /// B2-3: the buddy, then the answer as a glowing sky chip ("btw → by the way"), then "Explain more".
    private func explainRow(_ item: BarItems.Item) -> some View {
        HStack(spacing: 8) {
            Buddy(size: 30)
            Button { model.tapExplainChip() } label: {
                HStack(spacing: 7) {
                    if let t = item.trigger {
                        Text(t).font(.system(size: 15)).foregroundStyle(Theme.Color.skyOnText).lineLimit(1)
                        Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.Color.skyOnText)
                    }
                    Text(item.title).font(.system(size: 16.5, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    if let d = item.detail {
                        Text(d).font(.system(size: 12)).foregroundStyle(Theme.Color.skyOnText).lineLimit(1)
                    }
                }
                .padding(.horizontal, 15).frame(height: 36)
                .background(SkyFill())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([item.trigger, item.title, item.detail].compactMap { $0 }.joined(separator: ": "))
            .accessibilityIdentifier("chip.explain")
            if model.explainOfferHasMore {
                Button { model.openExplainCard() } label: {
                    Text("Explain more").font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.Color.text1)
                        .padding(.horizontal, 14).frame(height: 36).background(FrostFill())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .accessibilityIdentifier("chip.explain.more")
            }
        }
        .padding(.leading, 6)
    }

    private func panelTitle(_ p: ExplainPanel) -> String {
        switch p {
        case .card: "Explain"
        case .visual(let v):
            if case .drawing(let n, let m) = v.status { "\u{201C}\(v.subject)\u{201D} \u{00B7} step \(n) of \(m)" } else { "\u{201C}\(v.subject)\u{201D}" }
        }
    }

    private var showsWords: Bool { model.showsWordSlots }

    private var wordRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(model.words.slots.enumerated()), id: \.offset) { i, slot in
                if i > 0 { Rectangle().fill(palette.divider).frame(width: 1, height: M.dividerHeight) }
                Button { model.useWord(slot.word) } label: {
                    Text(slot.title).font(M.prediction).foregroundStyle(palette.label)
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .padding(.horizontal, Theme.Space.xs)
                        .frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(slot.word)
                .accessibilityIdentifier("word.\(i)")
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Fix sits beside the chips, so it never takes a chip's place.
    private var showsFix: Bool {
        guard !showsWords, model.fixable, model.explainPanel == nil, model.explainOffer == nil, model.undo == nil, !model.notesOpen, !model.writeOpen else { return false }
        if case .idle = model.bar { return true }
        return false
    }

    /// ✕ at the leading edge: every chip goes, and none comes back for 10 s. 32 pt to tap, 8 pt clear of the chip.
    private var dismissButton: some View {
        Button(action: model.dismissChips) {
            Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.secondaryLabel)
                .frame(width: 32, height: 32).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.trailing, 8)
        .accessibilityLabel("Hide suggestions")
        .accessibilityIdentifier("chip.dismiss")
        .transition(.opacity)
    }

    private func barButton(_ systemImage: String, id: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage).font(M.icon).foregroundStyle(palette.label)
                .frame(width: 40).frame(maxHeight: .infinity).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    struct Slot: View {
        let item: BarItems.Item
        let palette: Theme.SystemKeyboard.Palette
        let action: (() -> Void)?
        /// A fixed width, or nil to share the bar with the other slots.
        var width: CGFloat? = nil

        var body: some View {
            Button { action?() } label: {
                VStack(spacing: 0) {
                    if let t = item.trigger {
                        // The words that caused the chip, quoted, on one line. The trigger shortens first, then goes,
                        // so the action stays whole.
                        ViewThatFits(in: .horizontal) {
                            quoted(t, item.title).fixedSize()
                            ForEach(Self.shortened(t), id: \.self) { s in quoted(s, item.short ?? item.title).fixedSize() }
                            titleText
                        }
                    } else {
                        titleText
                    }
                    if let d = item.detail {
                        Text(d).font(M.predictionSmall).foregroundStyle(palette.secondaryLabel).lineLimit(1).minimumScaleFactor(0.7)
                    }
                }
                .padding(.horizontal, Theme.Space.xs)
                .frame(maxWidth: width ?? .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(action == nil)
        }

        private var titleText: some View {
            Text(item.title).font(item.detail == nil ? M.prediction : M.prediction.weight(.medium))
                .foregroundStyle(tint)
                .lineLimit(item.id == "confirm" ? 2 : 1).minimumScaleFactor(item.id == "confirm" ? 0.8 : 0.6)
                .multilineTextAlignment(.center)
        }

        private func quoted(_ trigger: String, _ title: String) -> Text {
            Text("\u{201C}\(trigger)\u{201D} ").font(M.prediction).foregroundColor(palette.accent)
                + Text(title).font(item.detail == nil ? M.prediction : M.prediction.weight(.medium)).foregroundColor(tint)
        }

        /// The trigger whole, then cut shorter, for ViewThatFits to try in turn.
        static func shortened(_ t: String) -> [String] {
            var out = [t]
            for n in [16, 10, 6] where t.count > n + 1 { out.append(String(t.prefix(n)).trimmingCharacters(in: .whitespaces) + "\u{2026}") }
            return out
        }

        private var tint: Color {
            switch item.tone {
            case .label: palette.label
            case .secondary: palette.secondaryLabel
            case .accent: palette.accent
            case .success: Theme.Color.success
            case .warning: Theme.Color.warning
            }
        }
    }
}

/// The owner's notes, in place of the keys. A tap inserts the note at the cursor.
struct NotesPanel: View {
    @ObservedObject var model: KeyboardModel
    let palette: Theme.SystemKeyboard.Palette
    typealias M = Theme.SystemKeyboard

    var body: some View {
        ScrollView {
            VStack(spacing: M.keyGap) {
                ForEach(Array(model.notes.enumerated()), id: \.element.id) { i, note in
                    Button { model.insertNote(note) } label: {
                        Text(note.text).font(M.mode).foregroundStyle(palette.label)
                            .lineLimit(2).multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, minHeight: M.keyHeight - 20, alignment: .leading)
                            .padding(.horizontal, Theme.Space.s).padding(.vertical, Theme.Space.xs)
                            .background(palette.key, in: RoundedRectangle(cornerRadius: M.cornerRadius, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("note.\(i)")
                }
                if model.notes.isEmpty {
                    Text("No notes yet. Type a reply, then tap +.").font(M.mode).foregroundStyle(palette.secondaryLabel).padding(.top, Theme.Space.xl)
                }
            }
            .padding(.horizontal, M.sideInset)
        }
    }
}

/// Rewrite, in place of the keys: every version in one list, each row filling in as it arrives.
/// Tap a row to replace the text, hold it to copy. A row that took too long offers Retry.
struct WritePanelView: View {
    @ObservedObject var model: KeyboardModel
    let palette: Theme.SystemKeyboard.Palette
    typealias M = Theme.SystemKeyboard

    var body: some View {
        Group {
            switch model.writePanel {
            case .menu: note("Type a message first. Then tap Rewrite.")
            case .versions(let list): versions(list)
            case .failed(let text):
                VStack(spacing: M.rowGap) { note(text); wide("Retry", id: "write.retry", accent: true) { model.retryRewrite() } }
            case .preview(let p): preview(p)
            }
        }
        .padding(.horizontal, M.sideInset)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func versions(_ list: RewriteList) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\u{201C}\(list.text)\u{201D}").font(M.predictionSmall).foregroundStyle(palette.secondaryLabel)
                .lineLimit(1).truncationMode(.middle)
                .padding(.horizontal, Theme.Space.xs)
                .accessibilityIdentifier("write.quote")
            ScrollView {
                VStack(spacing: M.keyGap) {
                    ForEach(list.rows) { row in versionRow(row, copied: list.copied == row.tone) }
                }
            }
        }
    }

    @ViewBuilder
    private func versionRow(_ row: RewriteRow, copied: Bool) -> some View {
        let card = RoundedRectangle(cornerRadius: M.cornerRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(row.tone.title).font(M.predictionSmall.weight(.semibold)).foregroundStyle(palette.secondaryLabel)
                Spacer()
                if copied { Text("Copied").font(M.predictionSmall.weight(.semibold)).foregroundStyle(palette.accent) }
            }
            switch row.status {
            case .ready(let text):
                Text(text).font(M.mode).foregroundStyle(palette.label).multilineTextAlignment(.leading).lineLimit(3)
            case .writing:
                Text("Writing\u{2026}").font(M.mode).foregroundStyle(palette.secondaryLabel)
            case .stalled:
                HStack {
                    Text("Took too long").font(M.mode).foregroundStyle(palette.secondaryLabel)
                    Spacer()
                    Button("Retry") { model.retryRewrite(row.tone) }
                        .font(M.mode.weight(.medium)).foregroundStyle(palette.accent).buttonStyle(.plain)
                        .accessibilityIdentifier("write.retry.\(row.id)")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Space.s).padding(.vertical, Theme.Space.xs)
        .background(palette.key, in: card)
        .contentShape(card)
        .onTapGesture { model.useRewrite(row.tone) }
        .onLongPressGesture(minimumDuration: 0.4) { model.copyRewrite(row.tone) }
        .accessibilityElement(children: row.status == .stalled ? .contain : .combine)
        .accessibilityAddTraits(row.text != nil ? .isButton : [])
        .accessibilityAction(named: "Copy") { model.copyRewrite(row.tone) }
        .accessibilityIdentifier("write.row.\(row.id)")
    }

    private func preview(_ p: WritePreview) -> some View {
        VStack(spacing: M.keyGap) {
            Button(action: model.usePreview) {
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    Text(p.title).font(M.predictionSmall.weight(.semibold)).foregroundStyle(palette.secondaryLabel)
                    Text(p.text).font(M.mode).foregroundStyle(palette.label)
                        .multilineTextAlignment(.leading).minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .padding(.horizontal, Theme.Space.s).padding(.vertical, Theme.Space.xs)
                .background(palette.key, in: RoundedRectangle(cornerRadius: M.cornerRadius, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("write.preview")
            HStack(spacing: M.keyGap) {
                wide("Back", id: "write.back", action: model.backToWriteMenu)
                wide("Replace", id: "write.use", accent: true, action: model.usePreview)
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(M.mode).foregroundStyle(palette.secondaryLabel).multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("write.note")
    }

    private func wide(_ title: String, id: String, accent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(M.mode).foregroundStyle(accent ? .white : palette.label)
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: M.keyHeight, maxHeight: M.keyHeight + 9)
                .background(accent ? palette.accent : palette.key, in: RoundedRectangle(cornerRadius: M.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}
