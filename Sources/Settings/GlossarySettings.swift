import AppKit
import SwiftUI

/// Each app's glossary: the names and terms its text keeps as written or always
/// translates the same way. Terms are added here or by right-clicking a word over a
/// capture; names that keep turning up are offered at the top.
struct GlossarySettings: View {
    @Bindable var store: SettingsStore
    let names: NameSuggestions

    @State private var running: [String] = []
    @State private var choosingApp = false
    /// The new term being typed, per app.
    @State private var drafts: [String: String] = [:]

    var body: some View {
        Form {
            let suggestingApps = names.apps(excluding: store.settings.glossaries)
            if !suggestingApps.isEmpty {
                Section {
                    ForEach(suggestingApps, id: \.self) { app in
                        ForEach(names.suggestions(for: app, excluding: terms(of: app)).prefix(8), id: \.self) { name in
                            LabeledContent {
                                Button("Keep as Written") { add(.keep(name), to: app) }
                            } label: {
                                Text(name)
                                Text(AppNames.name(forBundleID: app))
                            }
                        }
                    }
                } header: {
                    Text("Names seen often")
                } footer: {
                    Text("Names that keep turning up in what you translate. Lector forgets them when it quits.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(apps, id: \.self) { app in
                Section {
                    ForEach(terms(of: app), id: \.original) { term in
                        row(term, in: app)
                    }
                    HStack {
                        TextField("New term", text: draft(for: app))
                            .onSubmit { addDraft(to: app) }
                        Button("Add") { addDraft(to: app) }
                            .disabled(drafts[app, default: ""].trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    HStack {
                        Label {
                            Text(AppNames.name(forBundleID: app))
                        } icon: {
                            Image(nsImage: AppNames.icon(forBundleID: app))
                        }
                        Spacer()
                        Button {
                            store.settings.glossaries[app] = nil
                        } label: {
                            Image(systemName: "trash").foregroundStyle(Color.accent)
                        }
                        .buttonStyle(.borderless)
                        .help("Remove the glossary for \(AppNames.name(forBundleID: app))")
                        .accessibilityLabel("Remove glossary for \(AppNames.name(forBundleID: app))")
                    }
                }
            }

            Section {
                if apps.isEmpty {
                    Text("Right-click a word over a capture to keep it as written or give it a translation.")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Menu("Add App") {
                        let addable = running.filter { store.settings.glossaries[$0] == nil }
                        ForEach(addable, id: \.self) { app in
                            Button {
                                add(app: app)
                            } label: {
                                Label {
                                    Text(AppNames.name(forBundleID: app))
                                } icon: {
                                    Image(nsImage: AppNames.icon(forBundleID: app))
                                }
                            }
                        }
                        if !addable.isEmpty { Divider() }
                        Button("Other…") { choosingApp = true }
                    }
                    .fixedSize()
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: listRunningApps)
        .fileImporter(isPresented: $choosingApp, allowedContentTypes: [.application]) { result in
            guard let url = try? result.get(), let app = Bundle(url: url)?.bundleIdentifier else { return }
            add(app: app)
        }
        .fileDialogDefaultDirectory(URL(filePath: "/Applications", directoryHint: .isDirectory))
    }

    /// One term: what the app writes, and what it becomes — kept as written when the
    /// translation is left empty. A translation into another language than the one
    /// translated into now says which.
    private func row(_ term: GlossaryTerm, in app: String) -> some View {
        HStack(spacing: 8) {
            Text(term.original)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Kept as written", text: translation(of: term, in: app))
                .labelsHidden()
                .frame(maxWidth: .infinity)
            if let target = term.target, target != store.settings.targetLanguage {
                Text(Languages.name(target))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                remove(term, from: app)
            } label: {
                Image(systemName: "trash").foregroundStyle(Color.accent)
            }
            .buttonStyle(.borderless)
            .help("Remove \(term.original)")
            .accessibilityLabel("Remove \(term.original)")
        }
    }

    /// The apps with a glossary, by name. One added with no terms yet stays listed
    /// while Settings is open, so its first term can be typed in.
    private var apps: [String] {
        store.settings.glossaries.keys.sorted {
            AppNames.name(forBundleID: $0).localizedStandardCompare(AppNames.name(forBundleID: $1)) == .orderedAscending
        }
    }

    private func terms(of app: String) -> [GlossaryTerm] {
        store.settings.glossaries[app] ?? []
    }

    private func translation(of term: GlossaryTerm, in app: String) -> Binding<String> {
        Binding(
            get: { term.translation ?? "" },
            set: { text in
                guard let index = terms(of: app).firstIndex(matching: term.original) else { return }
                let text = text.trimmingCharacters(in: .whitespaces)
                store.settings.glossaries[app]?[index] = text.isEmpty
                    ? .keep(term.original)
                    : GlossaryTerm(original: term.original, translation: text, target: store.settings.targetLanguage)
            })
    }

    private func draft(for app: String) -> Binding<String> {
        Binding(get: { drafts[app, default: ""] }, set: { drafts[app] = $0 })
    }

    private func addDraft(to app: String) {
        let original = drafts[app, default: ""].trimmingCharacters(in: .whitespaces)
        guard !original.isEmpty else { return }
        add(.keep(original), to: app)
        drafts[app] = nil
    }

    private func add(_ term: GlossaryTerm, to app: String) {
        var terms = terms(of: app)
        guard terms.firstIndex(matching: term.original) == nil else { return }
        terms.append(term)
        store.settings.glossaries[app] = terms
    }

    private func add(app: String) {
        guard store.settings.glossaries[app] == nil else { return }
        store.settings.glossaries[app] = []
    }

    private func remove(_ term: GlossaryTerm, from app: String) {
        store.settings.glossaries[app]?.removeAll { $0.original == term.original }
    }

    private func listRunningApps() {
        let own = Bundle.main.bundleIdentifier
        var seen: Set<String> = []
        running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { $0.bundleIdentifier }
            .filter { $0 != own && seen.insert($0).inserted }
            .sorted {
                AppNames.name(forBundleID: $0).localizedStandardCompare(AppNames.name(forBundleID: $1)) == .orderedAscending
            }
    }
}
