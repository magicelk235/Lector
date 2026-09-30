import HoverLensKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var store: SettingsStore
    let controller: AppController
    let permissions: PermissionsChecker

    var body: some View {
        TabView {
            GeneralSettings(store: store, controller: controller, permissions: permissions)
                .tabItem { Label("General", systemImage: "gearshape") }
            TranslationSettings(store: store, offline: controller.offline)
                .tabItem { Label("Translation", systemImage: "character.bubble") }
            PrivacySettings()
                .tabItem { Label("Privacy", systemImage: "lock") }
            AcknowledgementsSettings()
                .tabItem { Label("Acknowledgements", systemImage: "heart.text.square") }
        }
        .frame(width: 480, height: 400)
    }
}

private struct GeneralSettings: View {
    @Bindable var store: SettingsStore
    let controller: AppController
    let permissions: PermissionsChecker

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

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

            Section("Screen Recording") {
                HStack {
                    Image(systemName: permissions.hasScreenRecording
                          ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(permissions.hasScreenRecording ? .green : .orange)
                    Text(permissions.hasScreenRecording
                         ? "Granted."
                         : "Needed to read text on screen.")
                    Spacer()
                    if !permissions.hasScreenRecording {
                        Button("Open Settings…") { permissions.openSettings() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { permissions.refresh() }
    }

    private var conflictNote: some View {
        Label("Another app is using this shortcut. Pick a different one.",
              systemImage: "exclamationmark.triangle.fill")
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

    @State private var installed: [String] = []

    var body: some View {
        Form {
            Section {
                Picker("Translate into", selection: $store.settings.targetLanguage) {
                    ForEach(Languages.sortedTargets, id: \.self) { code in
                        Text(Languages.name(code)).tag(code)
                    }
                }
            }

            Section {
                if installed.isEmpty {
                    Text("None yet. They download on their own the first time a language needs one.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(installed, id: \.self) { Text($0) }
                    Button("Remove All", role: .destructive) {
                        try? offline.removeAllModels()
                        installed = offline.installedPairs()
                    }
                }
            } header: {
                Text("Offline language packs")
            } footer: {
                Text("""
                A language pack gives an instant first translation, then Apple's built-in \
                translation refines it; languages Apple doesn't support use the pack alone. \
                Packs download once, in the background, and then work without internet.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { installed = offline.installedPairs() }
    }
}

private struct PrivacySettings: View {
    var body: some View {
        Form {
            Section("What happens to what you capture") {
                Text("""
                The screen is captured only when you press a shortcut, with macOS's own \
                screenshot tool. The capture is read and its temporary file deleted at once.

                Text is read and translated entirely on your Mac. Nothing you capture \
                is stored, logged, or sent anywhere. There is no history and no analytics.

                The only network use is downloading language packs, which happens on its own \
                the first time you translate from a language. Your text is never sent.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AcknowledgementsSettings: View {
    private struct Component: Identifiable {
        let name: String
        let role: String
        let licence: String
        let files: [String]
        var id: String { name }
    }

    /// Notices live in the app bundle's `licenses` folder, copied from Vendor/licenses.
    private static let components = [
        Component(name: "Tesseract", role: "Reads the scripts Vision can't, with its tessdata models.",
                  licence: "Apache 2.0", files: ["tesseract-LICENSE.txt"]),
        Component(name: "Leptonica", role: "Image handling for Tesseract.",
                  licence: "BSD 2-Clause", files: ["leptonica-LICENSE.txt"]),
        Component(name: "ONNX Runtime", role: "Runs the offline translation models.",
                  licence: "MIT", files: ["onnxruntime-LICENSE.txt", "onnxruntime-ThirdPartyNotices.txt"]),
        Component(name: "Opus-MT", role: "Offline translation models by Helsinki-NLP, University of Helsinki.",
                  licence: "CC BY 4.0", files: ["opus-mt-NOTICE.txt"]),
    ]

    var body: some View {
        Form {
            Section {
                ForEach(Self.components) { component in
                    LabeledContent {
                        Button("View Licence") { open(component.files) }
                    } label: {
                        Text("\(component.name) · \(component.licence)")
                        Text(component.role)
                    }
                }
            } footer: {
                Text("Hover Lens is built on these open-source projects.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
