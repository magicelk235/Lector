import AppKit
import SwiftUI

/// The area live translation last watched in each app, where the live shortcut watches it
/// again without the crosshair. Forgetting one here has the next live translation in that
/// app drawn anew.
struct LiveAreasSection: View {
    @Bindable var store: SettingsStore

    private struct AppItem: Identifiable {
        /// The bundle identifier.
        let id: String
        let name: String
        let icon: NSImage
    }

    var body: some View {
        Section {
            if apps.isEmpty {
                Text("None yet").foregroundStyle(.secondary)
            } else {
                ForEach(apps) { app in
                    LabeledContent {
                        Button {
                            store.settings.liveAreas[app.id] = nil
                        } label: {
                            Image(systemName: "trash").foregroundStyle(Color.accent)
                        }
                        .buttonStyle(.borderless)
                        .help("Forget the area in \(app.name)")
                        .accessibilityLabel("Forget the area in \(app.name)")
                    } label: {
                        Label {
                            Text(app.name)
                        } icon: {
                            Image(nsImage: app.icon)
                        }
                    }
                }
            }
        } header: {
            Text("Live translation areas")
        } footer: {
            Text("In these apps, \(shortcut) watches the same area again without the crosshair. Press it again while the message says so to draw a new one.")
        }
    }

    /// The apps with a remembered area, by name.
    private var apps: [AppItem] {
        store.settings.liveAreas.keys
            .map { AppItem(id: $0, name: AppNames.name(forBundleID: $0), icon: AppNames.icon(forBundleID: $0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var shortcut: String {
        store.settings.liveShortcut.label
    }
}
