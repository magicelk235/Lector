import SwiftUI

@main
struct HoverLensApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra(AppConstants.name, systemImage: "text.viewfinder") {
            if let controller = delegate.controller {
                Button("Grab Text  \(controller.settings.grabShortcut.label)") {
                    delegate.beginFromMenu(.grab)
                }
                Button("Translate  \(controller.settings.translateShortcut.label)") {
                    delegate.beginFromMenu(.translate)
                }
                Divider()
            }
            SettingsLink { Text("Settings…") }
                .keyboardShortcut(",")
            Button("Welcome Guide") { delegate.showOnboarding() }
            Divider()
            Button("Quit \(AppConstants.name)") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }

        Settings {
            if let store = delegate.store, let controller = delegate.controller {
                SettingsView(store: store, controller: controller, permissions: delegate.permissions)
            }
        }
    }
}

/// Observable so the menu and Settings scenes, first built before launch finishes,
/// redraw once `controller` and `store` exist.
@MainActor
@Observable
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var controller: AppController?
    private(set) var store: SettingsStore?
    let permissions = PermissionsChecker()

    @ObservationIgnored private var onboardingWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = SettingsStore()
        let controller = AppController(settings: store.settings)
        store.onChange = { [weak controller] settings in controller?.apply(settings) }
        controller.onNeedsPermission = { [weak self] in self?.showOnboarding() }

        controller.start()
        self.store = store
        self.controller = controller

        // SwiftUI finishes setting up the MenuBarExtra scene after this callback and
        // resets the activation policy back to .accessory while doing it, which takes
        // the onboarding window down with it. Showing on the next pass lets that settle.
        if store.needsOnboarding || !permissions.hasScreenRecording {
            DispatchQueue.main.async { [weak self] in self?.showOnboarding() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
    }

    /// The menu is still animating closed when its action fires; freezing the screen
    /// at that moment would put a half-faded menu in the picture.
    func beginFromMenu(_ purpose: AppController.Purpose) {
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            controller?.begin(purpose)
        }
    }

    func showOnboarding() {
        guard let store else { return }
        if let onboardingWindow {
            onboardingWindow.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        // LSUIElement agents cannot show a window until the activation policy allows
        // it. Without this the window is created and never appears, which for a
        // first-time buyer looks exactly like the app not launching.
        NSApplication.shared.setActivationPolicy(.regular)

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = AppConstants.name
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: OnboardingView(
            settings: store.settings,
            permissions: permissions,
            onFinish: { [weak self] in
                self?.store?.needsOnboarding = false
                self?.onboardingWindow?.close()
            }))
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.onboardingWindow = nil
                    // Back to being an agent: no Dock icon, just the menu bar.
                    NSApplication.shared.setActivationPolicy(.accessory)
                }
            }
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        onboardingWindow = window
    }
}
