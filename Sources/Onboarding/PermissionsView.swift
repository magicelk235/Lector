import SwiftUI

/// First launch, and whenever a shortcut is pressed without Screen Recording. Says
/// what the two shortcuts do, asks for the one permission, and is honest that it
/// takes a relaunch — which users otherwise discover by the app silently not working.
struct OnboardingView: View {
    let settings: AppSettings
    let permissions: PermissionsChecker
    let onFinish: () -> Void

    @State private var didRequest = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(AppConstants.name)
                .font(.system(size: 26, weight: .semibold))

            VStack(alignment: .leading, spacing: 10) {
                shortcutRow(settings.grabShortcut, title: "Grab text",
                            detail: "Drag over any text on screen. One line is copied right away; for more, pick the words you want.")
                shortcutRow(settings.translateShortcut, title: "Translate",
                            detail: "Drag over text in any language and read it in yours.")
            }

            Divider()

            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Screen Recording").fontWeight(.medium)
                    Text("""
                    Needed to read text from the screen. The screen is only captured \
                    when you press a shortcut, and nothing is saved or sent anywhere.
                    """)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: permissions.hasScreenRecording ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(permissions.hasScreenRecording ? .green : .secondary)
                    .font(.title2)
            }

            if !permissions.hasScreenRecording {
                HStack {
                    Button(didRequest ? "Open System Settings…" : "Grant Access") {
                        permissions.request()
                        didRequest = true
                    }
                    .buttonStyle(.borderedProminent)

                    if didRequest {
                        Text("Then reopen \(AppConstants.name).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            HStack {
                if didRequest, !permissions.hasScreenRecording {
                    Button("Relaunch Now") { permissions.relaunch() }
                }
                Spacer()
                Button(permissions.hasScreenRecording ? "Done" : "Later") { onFinish() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 520, height: 420)
        .onAppear { permissions.refresh() }
        // Granted in System Settings, so re-check on the way back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh()
        }
    }

    private func shortcutRow(_ shortcut: Shortcut, title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(shortcut.label)
                .font(.system(.body, design: .rounded).weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                .frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}
