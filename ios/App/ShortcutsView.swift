import SwiftUI

/// Every keyboard shortcut in one place: the built-in actions and the notes that have a trigger.
/// The owner can change each trigger. All of it stays on this phone, in the App Group.
struct ShortcutsView: View {
    @State private var actions = SharedStore.actionShortcuts
    @State private var notes = SharedStore.notes
    @State private var editingAction: ActionShortcut?
    @State private var editingNote: Note?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metric.cardGap) {
                HStack {
                    Text("Shortcuts").font(Theme.Font.title).foregroundStyle(Theme.Color.text1)
                    Spacer()
                    Button { editingNote = Note(text: "", trigger: ";") } label: { IconCircle(systemImage: "plus") }
                        .buttonStyle(PressScale())
                        .accessibilityLabel("Add shortcut")
                        .accessibilityIdentifier("shortcuts.new")
                }
                .padding(.leading, Theme.Metric.margin)
                .padding(.trailing, Theme.Metric.cardInset)
                Text("Type a shortcut on the keyboard, then space. Shortcuts stay on this phone.")
                    .font(Theme.Font.label).foregroundStyle(Theme.Color.text2).padding(.horizontal, Theme.Metric.margin)

                SectionHeader(title: "Actions").padding(.top, Theme.Metric.sectionGap - Theme.Metric.cardGap)
                ForEach(actions) { a in
                    row(trigger: a.usage, title: a.title, detail: a.detail, dimmed: !a.enabled) { editingAction = a }
                        .accessibilityIdentifier("shortcut.\(a.id)")
                }
                SectionHeader(title: "Your text").padding(.top, Theme.Metric.sectionGap - Theme.Metric.cardGap)
                ForEach(notes.filter { $0.trigger != nil }) { n in
                    row(trigger: n.trigger ?? "", title: n.text, detail: nil, dimmed: false) { editingNote = n }
                }
                if !notes.contains(where: { $0.trigger != nil }) {
                    Text("No text shortcuts yet. Tap + to add one.").font(Theme.Font.label).foregroundStyle(Theme.Color.text3).padding(.horizontal, Theme.Metric.margin)
                }
            }
            .padding(.top, Theme.Space.xs)
            .padding(.bottom, Theme.Space.l)
        }
        .background(Theme.Color.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            notes = SharedStore.notes
            actions = SharedStore.actionShortcuts
        }
        .sheet(item: $editingAction) { a in
            ActionShortcutEditor(shortcut: a, taken: Set(actions.filter { $0.id != a.id }.map(\.trigger) + notes.compactMap(\.trigger))) { changed in
                if let i = actions.firstIndex(where: { $0.id == changed.id }) { actions[i] = changed }
                SharedStore.actionShortcuts = actions
            }
        }
        .sheet(item: $editingNote) { note in
            NoteEditor(note: note, isNew: !notes.contains { $0.id == note.id }, taken: NoteEditor.taken(notes, except: note), save: save, delete: delete)
        }
    }

    private func row(trigger: String, title: String, detail: String?, dimmed: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Card {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    HStack(spacing: Theme.Space.xs) {
                        Text(trigger).font(Theme.Font.paper(14)).foregroundStyle(Theme.Color.text1)
                            .padding(.horizontal, Theme.Space.s).frame(height: Theme.Space.xl)
                            .background(Theme.Color.button, in: Capsule())
                        if dimmed { Text("Off").font(Theme.Font.label).foregroundStyle(Theme.Color.text3) }
                        Spacer(minLength: 0)
                    }
                    Text(title).font(Theme.Font.body).foregroundStyle(Theme.Color.text1).lineLimit(2).multilineTextAlignment(.leading)
                    if let detail {
                        Text(detail).font(Theme.Font.label).foregroundStyle(Theme.Color.text2)
                            .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(dimmed ? 0.55 : 1)
            }
        }
        .buttonStyle(PressScale())
        .padding(.horizontal, Theme.Metric.cardInset)
    }

    private func save(_ note: Note) {
        if let i = notes.firstIndex(where: { $0.id == note.id }) { notes[i] = note } else { notes.insert(note, at: 0) }
        SharedStore.notes = notes
    }

    private func delete(_ note: Note) {
        notes.removeAll { $0.id == note.id }
        SharedStore.notes = notes
    }
}

/// Change the trigger of a built-in action, or turn the action off.
struct ActionShortcutEditor: View {
    @State var shortcut: ActionShortcut
    let taken: Set<String>
    let save: (ActionShortcut) -> Void
    @Environment(\.dismiss) private var dismiss

    private var trigger: String { Shortcuts.normalize(shortcut.trigger) }
    private var problem: String? { Shortcuts.problem(trigger, taken: taken) }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                TextField("", text: $shortcut.trigger, prompt: Text("Shortcut").foregroundStyle(Theme.Color.text3))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .modifier(FieldStyle())
                    .accessibilityIdentifier("shortcut.trigger")
                Text(problem ?? shortcut.detail)
                    .font(Theme.Font.label).foregroundStyle(problem == nil ? Theme.Color.text2 : Theme.Color.due)
                    .padding(.horizontal, Theme.Space.xs).fixedSize(horizontal: false, vertical: true)
                Toggle("On", isOn: $shortcut.enabled)
                    .font(Theme.Font.body).foregroundStyle(Theme.Color.text1).tint(Theme.Color.paid)
                    .padding(.horizontal, Theme.Space.xs)
                    .accessibilityIdentifier("shortcut.enabled")
                Button("Reset to \(ActionShortcut.defaults.first { $0.action == shortcut.action }?.trigger ?? "")") {
                    shortcut.trigger = ActionShortcut.defaults.first { $0.action == shortcut.action }?.trigger ?? shortcut.trigger
                }
                .font(Theme.Font.label).foregroundStyle(Theme.Color.text2).padding(.horizontal, Theme.Space.xs)
                Spacer()
            }
            .padding(Theme.Metric.cardInset)
            .background(Theme.Color.bg.ignoresSafeArea())
            .navigationTitle(shortcut.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        shortcut.trigger = trigger
                        save(shortcut)
                        dismiss()
                    }
                    .disabled(problem != nil)
                    .accessibilityIdentifier("shortcut.save")
                }
            }
        }
        .presentationDetents([.medium])
    }
}
