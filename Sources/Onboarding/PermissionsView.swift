import SwiftUI

/// First launch, and whenever a shortcut is pressed without Screen Recording. Says
/// what the shortcuts do and which keys work over a translation, lets the user pick the
/// language to translate into, asks for the one permission, and is honest that it
/// takes a relaunch — which users otherwise discover by the app silently not working.
struct OnboardingView: View {
    @Bindable var store: SettingsStore
    let permissions: PermissionsChecker
    let onFinish: () -> Void

    @State private var didRequest = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                // The lectern alone, as Viaduct shows its arches: the Dock's rounded
                // square around it would be a box in a window.
                Image("Lectern")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 56, height: 56)
                // The one serif in the app: the wordmark of a reader's lectern.
                Text(AppConstants.name)
                    .font(.system(size: 30, weight: .semibold, design: .serif))
            }

            VStack(alignment: .leading, spacing: 12) {
                shortcutRow(store.settings.grabShortcut, title: "Grab text")
                shortcutRow(store.settings.translateShortcut, title: "Translate")
                shortcutRow(store.settings.liveShortcut, title: "Live translate")
            }

            HStack(spacing: 10) {
                Text("Translate into").fontWeight(.medium)
                Picker("Translate into", selection: $store.settings.targetLanguage) {
                    LanguageOptions(suggested: Languages.likelyTargets(current: store.settings.targetLanguage,
                                                                       recent: store.settings.recentTargets))
                }
                .labelsHidden()
                .fixedSize()
            }

            Rectangle()
                .fill(Color.ink.opacity(0.12))
                .frame(height: 1)

            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Screen Recording").fontWeight(.medium)
                    Text("Everything stays on this Mac.")
                        .font(.callout)
                        .foregroundStyle(Color.inkMuted)
                }
            } icon: {
                Image(systemName: permissions.hasScreenRecording ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(permissions.hasScreenRecording ? Color.accent : Color.inkMuted)
                    .font(.title2)
            }

            // No way past this without the permission: every shortcut needs it.
            HStack(spacing: 12) {
                if permissions.hasScreenRecording {
                    Spacer()
                    Button("Done") { onFinish() }
                        .buttonStyle(InkButtonStyle(prominent: true))
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(didRequest ? "Open System Settings…" : "Grant Access") {
                        permissions.request()
                        didRequest = true
                    }
                    .buttonStyle(InkButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                    if didRequest {
                        Button("Relaunch Now") { permissions.relaunch() }
                            .buttonStyle(InkButtonStyle())
                    }
                    Spacer()
                }
            }
            .padding(.top, 10)
        }
        .foregroundStyle(Color.ink)
        .padding(.horizontal, 32)
        // Below the title bar's safe area, which already clears the close button.
        .padding(.top, 16)
        .padding(.bottom, 28)
        // Fixed width, height from the content: the window is sized from this view, and
        // anything flexible here stretches it into empty space.
        .frame(width: 400, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        // The system's own window colour, light or dark, under the transparent title bar.
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        .onAppear { permissions.refresh() }
        // Granted in System Settings, so re-check on the way back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh()
        }
    }

    private func shortcutRow(_ shortcut: Shortcut, title: String) -> some View {
        HStack(spacing: 14) {
            Keycap(shortcut.label)
                .frame(width: 64, alignment: .leading)
            Text(title).fontWeight(.medium)
        }
    }
}

/// Vellum on the lectern's red for the action that moves things forward, a quiet ink
/// outline for the rest. The deeper red in both appearances: vellum on it is 6:1, where
/// the brighter one would leave the label under 4.5:1.
private struct InkButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .foregroundStyle(prominent ? Color(nsColor: Palette.vellum) : Color.ink)
            .background(prominent ? Color(nsColor: Palette.accentLight) : Color.ink.opacity(0.08), in: shape)
            .overlay(shape.strokeBorder(Color.ink.opacity(prominent ? 0 : 0.22)))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(shape)
    }
}
