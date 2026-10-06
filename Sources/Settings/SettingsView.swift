import AppKit
import LectorKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Bindable var store: SettingsStore
    let controller: AppController

    var body: some View {
        TabView {
            GeneralSettings(store: store, controller: controller)
                .tabItem { Label("General", systemImage: "gearshape") }
            TranslationSettings(store: store, offline: controller.offline)
                .tabItem { Label("Translation", systemImage: "character.bubble") }
            LicenseView(license: controller.license, usage: controller.usage)
                .tabItem { Label("License", systemImage: "key") }
            AcknowledgementsSettings()
                .tabItem { Label("Acknowledgements", systemImage: "heart.text.square") }
        }
        .frame(width: 480, height: 470)
        .foregroundStyle(Color.ink)
        .tint(Color.accent)
    }
}

private struct GeneralSettings: View {
    @Bindable var store: SettingsStore
    let controller: AppController

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var checksForUpdates = Updater.shared.automaticallyChecksForUpdates

    private static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""

    var body: some View {
        Form {
            Section("Shortcuts") {
                LabeledContent("Grab text") {
                    ShortcutRecorder(shortcut: $store.settings.grabShortcut,
                                     defaultShortcut: .grabDefault,
                                     onRecordingChange: recordingChanged)
                }
                if controller.grabConflict { conflictNote }
                LabeledContent("Translate") {
                    ShortcutRecorder(shortcut: $store.settings.translateShortcut,
                                     defaultShortcut: .translateDefault,
                                     onRecordingChange: recordingChanged)
                }
                if controller.translateConflict { conflictNote }
                LabeledContent("Live translate") {
                    ShortcutRecorder(shortcut: $store.settings.liveShortcut,
                                     defaultShortcut: .liveDefault,
                                     onRecordingChange: recordingChanged)
                }
                if controller.liveConflict { conflictNote }
            }

            Section("Pill beside a capture") {
                Toggle("Show keys", isOn: $store.settings.pill.showsKeys)
                Toggle("Show languages", isOn: $store.settings.pill.showsLanguages)
                Toggle("Shorten after a few seconds", isOn: $store.settings.pill.shortens)
            }

            Section {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }

            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $checksForUpdates)
                    .onChange(of: checksForUpdates) { _, enabled in
                        Updater.shared.automaticallyChecksForUpdates = enabled
                    }
                LabeledContent("Version \(Self.version)") {
                    Button("Check Now") { Updater.shared.checkForUpdates() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var conflictNote: some View {
        Label("In use by another app", systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
    }

    private func recordingChanged(_ recording: Bool) {
        recording ? controller.suspendHotKeys() : controller.resumeHotKeys()
    }
}

private struct TranslationSettings: View {
    @Bindable var store: SettingsStore
    let offline: OpusMTTranslator

    @State private var packs: [OpusMTPack] = []

    var body: some View {
        Form {
            Section {
                Picker("Translate into", selection: $store.settings.targetLanguage) {
                    LanguageOptions(suggested: Languages.likelyTargets(current: store.settings.targetLanguage,
                                                                       recent: store.settings.recentTargets))
                }
                // A grouped form draws the chosen value in the tint; it's text, so ink.
                .tint(Color.ink)
            }

            AppLanguagesSection(store: store)

            Section {
                Toggle(isOn: $store.settings.prefetchesPacks) {
                    Text("Download packs for instant drafts")
                    if let packSize { Text("About \(packSize) per language") }
                }
                if packs.isEmpty {
                    Text("None yet").foregroundStyle(.secondary)
                } else {
                    ForEach(packs) { pack in
                        LabeledContent {
                            HStack(spacing: 10) {
                                Text(Self.size(pack.bytesOnDisk))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                Button {
                                    try? offline.removePack(pack)
                                    packs = offline.installedPacks()
                                } label: {
                                    Image(systemName: "trash").foregroundStyle(Color.accent)
                                }
                                .buttonStyle(.borderless)
                                .help("Delete the \(pack.title) pack")
                                .accessibilityLabel("Delete \(pack.title)")
                            }
                        } label: {
                            Text(pack.title)
                            if let coverage = pack.coverage { Text(coverage) }
                        }
                    }
                    LabeledContent("Total") {
                        HStack(spacing: 10) {
                            Text(Self.size(packs.reduce(0) { $0 + $1.bytesOnDisk }))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            Button("Remove All", role: .destructive) {
                                try? offline.removeAllModels()
                                packs = offline.installedPacks()
                            }
                        }
                    }
                }
            } header: {
                Text("Offline language packs")
            }
        }
        .formStyle(.grouped)
        .onAppear { packs = offline.installedPacks() }
    }

    /// The download one more language would take, for the drafts toggle.
    private var packSize: String? {
        let target = Locale.Language(identifier: store.settings.targetLanguage)
        return offline.typicalPackBytes(into: target).map(Self.size)
    }

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// The language each app's text is in: those picked with Tab over a translation, which
/// can be changed or removed here, and apps added before anything is captured from them.
private struct AppLanguagesSection: View {
    @Bindable var store: SettingsStore

    private struct AppItem: Identifiable {
        /// The bundle identifier.
        let id: String
        let name: String
        let icon: NSImage
    }

    /// Apps running with a window, any of which text might be captured from: the ones
    /// offered to add, kept current as apps open and quit.
    @State private var running: [AppItem] = []
    @State private var choosingApp = false

    var body: some View {
        Section {
            ForEach(apps) { app in
                LabeledContent {
                    HStack(spacing: 10) {
                        Picker(app.name, selection: language(of: app.id)) {
                            LanguageOptions(suggested: Languages.likelySources(
                                current: picked(for: app.id), recent: store.settings.recentSources,
                                target: store.settings.targetLanguage))
                        }
                        .labelsHidden()
                        .fixedSize()
                        // A grouped form draws the chosen value in the tint; it's text, so ink.
                        .tint(Color.ink)
                        Button {
                            store.settings.sourceLanguages[app.id] = nil
                        } label: {
                            Image(systemName: "trash").foregroundStyle(Color.accent)
                        }
                        .buttonStyle(.borderless)
                        .help("Remove \(app.name)")
                        .accessibilityLabel("Remove \(app.name)")
                    }
                } label: {
                    Label {
                        Text(app.name)
                    } icon: {
                        Image(nsImage: app.icon)
                    }
                }
            }
            HStack {
                Spacer()
                Menu("Add App") {
                    let addable = running.filter { store.settings.sourceLanguages[$0.id] == nil }
                    ForEach(addable) { app in
                        Button {
                            add(app.id)
                        } label: {
                            Label {
                                Text(app.name)
                            } icon: {
                                Image(nsImage: app.icon)
                            }
                        }
                    }
                    if !addable.isEmpty { Divider() }
                    Button("Other…") { choosingApp = true }
                }
                .fixedSize()
            }
            .onAppear(perform: listRunningApps)
            .onReceive(NSWorkspace.shared.notificationCenter
                .publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in listRunningApps() }
            .onReceive(NSWorkspace.shared.notificationCenter
                .publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in listRunningApps() }
            .fileImporter(isPresented: $choosingApp, allowedContentTypes: [.application]) { result in
                guard let url = try? result.get(), let app = Bundle(url: url)?.bundleIdentifier else { return }
                add(app)
            }
            .fileDialogDefaultDirectory(URL(filePath: "/Applications", directoryHint: .isDirectory))
        } header: {
            Text("Languages picked for apps")
        }
    }

    /// The apps with a language, by name.
    private var apps: [AppItem] {
        store.settings.sourceLanguages.keys
            .map { AppItem(id: $0, name: AppNames.name(forBundleID: $0), icon: AppNames.icon(forBundleID: $0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The app's language as the picker lists it, or as stored when it isn't listed: one
    /// picked with Tab that Lector can't translate from.
    private func picked(for app: String) -> String {
        let stored = store.settings.sourceLanguages[app] ?? ""
        // As stored: a bare "zh" is Simplified, not whichever Chinese the user reads.
        return Languages.target(for: stored, preferred: []) ?? stored
    }

    private func language(of app: String) -> Binding<String> {
        Binding(get: { picked(for: app) }, set: { store.settings.sourceLanguages[app] = $0 })
    }

    /// Starts an app off on the language its text likeliest is, to change from there.
    private func add(_ app: String) {
        guard store.settings.sourceLanguages[app] == nil else { return }
        let target = store.settings.targetLanguage
        store.settings.sourceLanguages[app] =
            Languages.likelySources(current: nil, recent: store.settings.recentSources, target: target).first
            ?? Languages.sortedTargets.first { $0 != target }
    }

    private func listRunningApps() {
        // Not Lector itself, whose own windows are never what's captured.
        var seen: Set<String> = [Bundle.main.bundleIdentifier ?? ""]
        running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let id = app.bundleIdentifier, seen.insert(id).inserted else { return nil }
                return AppItem(id: id, name: app.localizedName ?? AppNames.name(forBundleID: id),
                               icon: AppNames.icon(forBundleID: id))
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

private struct AcknowledgementsSettings: View {
    private struct Component: Identifiable {
        let name: String
        let licence: String
        let files: [String]
        var id: String { name }
    }

    /// Notices live in the app bundle's `licenses` folder, copied from Vendor/licenses.
    private static let components = [
        Component(name: "Tesseract", licence: "Apache 2.0", files: ["tesseract-LICENSE.txt"]),
        Component(name: "Leptonica", licence: "BSD 2-Clause", files: ["leptonica-LICENSE.txt"]),
        Component(name: "ONNX Runtime", licence: "MIT",
                  files: ["onnxruntime-LICENSE.txt", "onnxruntime-ThirdPartyNotices.txt"]),
        // CC BY asks for the authors by name.
        Component(name: "Opus-MT by Helsinki-NLP", licence: "CC BY 4.0", files: ["opus-mt-NOTICE.txt"]),
    ]

    var body: some View {
        Form {
            Section {
                ForEach(Self.components) { component in
                    LabeledContent {
                        Button("View Licence") { open(component.files) }
                    } label: {
                        Text("\(component.name) · \(component.licence)")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func open(_ files: [String]) {
        guard let folder = Bundle.main.url(forResource: "licenses", withExtension: nil) else { return }
        for file in files {
            NSWorkspace.shared.open(folder.appendingPathComponent(file))
        }
    }
}
