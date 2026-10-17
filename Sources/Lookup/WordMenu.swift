import AppKit
import SwiftUI

/// What a right-click on a captured word can do, handed to the picker and the overlay by
/// the controller, which knows the app the capture came from and its glossary.
@MainActor
struct WordActions {
    /// The app the capture is from, whose glossary terms are added to; nil — Lector
    /// itself, or no app in front — offers no glossary.
    let app: String?
    /// The language a term's translation is into.
    let target: String
    /// Shows `term`, in `language` if known, beside `anchor` in `view`.
    let lookUp: (_ term: String, _ language: Locale.Language?, _ anchor: CGRect, _ view: NSView) -> Void
    /// The app's glossary as it is now.
    let glossary: () -> [GlossaryTerm]
    /// Adds a term, or replaces the one with the same original.
    let setTerm: (GlossaryTerm) -> Void
    /// Takes the term with this original out.
    let removeTerm: (String) -> Void
}

/// The menu a right-click on a captured word opens.
@MainActor
enum WordMenu {
    /// - Parameters:
    ///   - text: the words clicked, as shown.
    ///   - language: what they're in, if known.
    ///   - isOriginal: they're the captured text, not a translation: only that can go in
    ///     the glossary, which matches what the app shows.
    ///   - extra: items for the end of the menu.
    static func menu(for text: String, language: Locale.Language?, isOriginal: Bool, actions: WordActions,
                     anchor: CGRect, in view: NSView, extra: [NSMenuItem] = []) -> NSMenu? {
        let term = WordLookup.term(text)
        guard !term.isEmpty else { return nil }
        let menu = NSMenu()
        let quoted = "“\(shortened(term))”"
        menu.addItem(ClosureMenuItem("Look Up \(quoted)") { [weak view] in
            guard let view else { return }
            actions.lookUp(term, language, anchor, view)
        })

        if isOriginal, actions.app != nil {
            menu.addItem(.separator())
            let glossary = actions.glossary()
            if let existing = glossary.firstIndex(matching: term).map({ glossary[$0] }) {
                let said = existing.translation.map { "\(quoted) → \(shortened($0))" } ?? "\(quoted) is kept as written"
                let note = NSMenuItem(title: said, action: nil, keyEquivalent: "")
                note.isEnabled = false
                menu.addItem(note)
                if existing.translation == nil {
                    menu.addItem(ClosureMenuItem("Always Translate As…") { [weak view] in
                        guard let view else { return }
                        GlossaryEditor.show(original: existing.original, translation: nil, actions: actions,
                                            relativeTo: anchor, of: view)
                    })
                } else {
                    menu.addItem(ClosureMenuItem("Change Translation…") { [weak view] in
                        guard let view else { return }
                        GlossaryEditor.show(original: existing.original, translation: existing.translation,
                                            actions: actions, relativeTo: anchor, of: view)
                    })
                    menu.addItem(ClosureMenuItem("Keep as Written") {
                        actions.setTerm(.keep(existing.original))
                    })
                }
                menu.addItem(ClosureMenuItem("Remove from Glossary") { actions.removeTerm(existing.original) })
            } else {
                menu.addItem(ClosureMenuItem("Keep \(quoted) as Written") { actions.setTerm(.keep(term)) })
                menu.addItem(ClosureMenuItem("Always Translate \(quoted) As…") { [weak view] in
                    guard let view else { return }
                    GlossaryEditor.show(original: term, translation: nil, actions: actions, relativeTo: anchor, of: view)
                })
            }
        }

        if !extra.isEmpty {
            menu.addItem(.separator())
            extra.forEach(menu.addItem)
        }
        return menu
    }

    /// A long selection named in full would stretch the menu across the screen.
    private static func shortened(_ text: String) -> String {
        text.count > 28 ? text.prefix(26).trimmingCharacters(in: .whitespaces) + "…" : text
    }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(runAction), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func runAction() {
        run()
    }
}

/// "Always translate “Kakariko” as ___": a small popover by the word to type a term's
/// translation in.
@MainActor
enum GlossaryEditor {
    static func show(original: String, translation: String?, actions: WordActions, relativeTo rect: CGRect,
                     of view: NSView) {
        let popover = NSPopover()
        popover.behavior = .transient
        let into = Languages.name(Locale.Language(identifier: actions.target))
        popover.contentViewController = NSHostingController(rootView: GlossaryEditorView(
            original: original, into: into, translation: translation ?? "",
            save: { [weak popover] text in
                let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                actions.setTerm(text.isEmpty
                    ? .keep(original)
                    : GlossaryTerm(original: original, translation: text, target: actions.target))
                popover?.close()
            },
            cancel: { [weak popover] in popover?.close() }))
        LookupPopover.present(popover, relativeTo: rect, of: view)
    }
}

private struct GlossaryEditorView: View {
    let original: String
    let into: String
    @State var translation: String
    let save: (String) -> Void
    let cancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Always translate “\(original)” into \(into) as")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Translation", text: $translation)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { save(translation) }
            Text("Left empty, it's kept as written.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save(translation) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 300)
        .onAppear { focused = true }
    }
}
