import SwiftUI

@main
struct LectorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // The icon's lectern as a template image, so it takes the menu bar's own colour.
        MenuBarExtra(AppConstants.name, image: "MenuBarIcon") {
            // Locked until Screen Recording is allowed: nothing else can work without it.
            if !delegate.permissions.hasScreenRecording {
                Button("Allow Screen Recording…") { delegate.showOnboarding() }
                Divider()
            } else if let controller = delegate.controller {
                // Shortcuts as menus show them, right-aligned like Settings…'s; the
                // hot keys themselves are registered globally by the controller.
                Button("Grab Text") { delegate.beginFromMenu(.grab) }
                    .keyboardShortcut(controller.settings.grabShortcut.menuShortcut)
                Button("Translate") { delegate.beginFromMenu(.translate) }
                    .keyboardShortcut(controller.settings.translateShortcut.menuShortcut)
                if controller.isLive {
                    Button("Stop Live Translation") { controller.stopLive() }
                        .keyboardShortcut(controller.settings.liveShortcut.menuShortcut)
                } else {
                    Button("Live Translate (Beta)") { delegate.beginFromMenu(.live) }
                        .keyboardShortcut(controller.settings.liveShortcut.menuShortcut)
                }
                if let store = delegate.store {
                    TranslateIntoMenu(store: store)
                }
                if controller.license.tier != .translate {
                    Button(controller.license.tier == .free ? "Buy Lector…" : "Upgrade to Translate…") {
                        delegate.showLicense(limit: nil)
                    }
                }
                Divider()
            }
            if delegate.permissions.hasScreenRecording {
                SettingsButton(onOpen: delegate.bringForward)
                Button("Welcome Guide") { delegate.showOnboarding() }
            }
            Button("Check for Updates…") { Updater.shared.checkForUpdates() }
            Divider()
            Button("Quit \(AppConstants.name)") { AppDelegate.quit() }
                .keyboardShortcut("q")
        }

        Settings {
            if let store = delegate.store, let controller = delegate.controller {
                SettingsView(store: store, controller: controller)
            }
        }
    }
}

/// The language translations are into, switched from the menu bar: the likeliest first —
/// the one chosen now, those translated into lately, those the Mac reads and those of
/// its region — then every other one alphabetically. The current one is checked.
private struct TranslateIntoMenu: View {
    @Bindable var store: SettingsStore

    var body: some View {
        let likely = Languages.likelyTargets(current: store.settings.targetLanguage, recent: store.settings.recentTargets)
        Menu("Translate Into") {
            Picker("Translate Into", selection: $store.settings.targetLanguage) {
                ForEach(likely, id: \.self) { code in
                    Text(Languages.name(code)).tag(code)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Picker("All Languages", selection: $store.settings.targetLanguage) {
                ForEach(Languages.sortedTargets.filter { !likely.contains($0) }, id: \.self) { code in
                    Text(Languages.name(code)).tag(code)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }
}

/// A menu-bar app isn't active when its menu is used, so Settings would open behind
/// whatever app is in front — and only surface the next time something activated
/// Lector, like a capture. Opening it also brings the app forward.
private struct SettingsButton: View {
    let onOpen: () -> Void
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Settings…") {
            onOpen()
            openSettings()
        }
        .keyboardShortcut(",")
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
    @ObservationIgnored private var licenseWindow: NSWindow?
    @ObservationIgnored private var licenseLimit: LicenseLimitHolder?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = SettingsStore()
        // A plain "zh" from before Simplified and Traditional were separate targets, or a
        // system language that came without its script, becomes the one the user reads.
        if let target = Languages.target(for: store.settings.targetLanguage), target != store.settings.targetLanguage {
            store.settings.targetLanguage = target
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppConstants.supportFolder, isDirectory: true)
        let license = LicenseManager(directory: support)
        let controller = AppController(settings: store.settings, license: license, usage: UsageMeter())
        store.onChange = { [weak controller] settings in controller?.apply(settings) }
        controller.onChooseSource = { [weak store] app, language in store?.settings.sourceLanguages[app] = language }
        controller.onTranslate = { [weak store] target, source in
            store?.settings.noteTranslation(into: target, from: source)
        }
        controller.onNeedsPermission = { [weak self] in self?.showOnboarding() }
        controller.onLimit = { [weak self] limit in self?.showLicense(limit: limit) }
        Task { await license.refresh() }

        controller.start()
        Updater.shared.isBusy = { [weak controller] in controller?.isBusy ?? false }
        Updater.shared.start()
        self.store = store
        self.controller = controller

        // Back to being an agent, no Dock icon, once the last of its windows closes.
        // Capture windows, the picker and toasts are borderless and don't count.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main) { notification in
                guard let object = notification.object as AnyObject? else { return }
                let closingID = ObjectIdentifier(object)
                MainActor.assumeIsolated {
                    let windows = NSApplication.shared.windows
                    guard windows.first(where: { ObjectIdentifier($0) == closingID })?
                        .styleMask.contains(.titled) == true else { return }
                    let othersOpen = windows.contains {
                        ObjectIdentifier($0) != closingID && $0.isVisible && $0.styleMask.contains(.titled)
                    }
                    if !othersOpen { NSApplication.shared.setActivationPolicy(.accessory) }
                }
            }

        // SwiftUI finishes setting up the MenuBarExtra scene after this callback and
        // resets the activation policy back to .accessory while doing it, which takes
        // the onboarding window down with it. Showing on the next pass lets that settle.
        if store.needsOnboarding || !permissions.hasScreenRecording {
            DispatchQueue.main.async { [weak self] in self?.showOnboarding() }
        }
    }

    /// Makes Lector an ordinary app while one of its windows is open. An agent (no Dock
    /// icon) can't take focus from the app in front: its window would open behind it,
    /// or in front but with keystrokes still going to the other app.
    func bringForward() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// Set by `quit()`, the menu bar's Quit and a relaunch, and by an update installing.
    static var quitRequested = false

    /// Actually exits. Every other quit — ⌘Q, the Dock's Quit — only closes the windows.
    static func quit() {
        quitRequested = true
        NSApplication.shared.terminate(nil)
    }

    /// ⌘Q and the Dock's Quit arrive while a window has put Lector in the Dock; they
    /// close the windows and leave it running in the menu bar, ready for its shortcuts.
    /// Logging out, restarting or shutting down is never held up.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let systemQuit = NSAppleEventManager.shared().currentAppleEvent?
            .attributeDescriptor(forKeyword: kAEQuitReason) != nil
        if Self.quitRequested || systemQuit { return .terminateNow }
        for window in sender.windows where window.isVisible && window.styleMask.contains(.titled) {
            window.close()
        }
        sender.setActivationPolicy(.accessory)
        return .terminateCancel
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
            bringForward()
            onboardingWindow.makeKeyAndOrderFront(nil)
            return
        }

        // LSUIElement agents cannot show a window until the activation policy allows
        // it. Without this the window is created and never appears, which for a
        // first-time buyer looks exactly like the app not launching.
        bringForward()

        // Height is a placeholder: the hosting view resizes the window to fit the content.
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = AppConstants.name
        // The view's background runs under the title bar; only the close button sits on it.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: OnboardingView(
            store: store,
            permissions: permissions,
            onFinish: { [weak self] in
                self?.store?.needsOnboarding = false
                self?.onboardingWindow?.close()
            }))
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onboardingWindow = nil }
            }
        window.makeKeyAndOrderFront(nil)
        onboardingWindow = window
    }

    /// Opens on reaching a limit, headed by it, and from the menu bar's Buy item.
    func showLicense(limit: Limit?) {
        guard let controller else { return }
        bringForward()
        if let licenseWindow, let licenseLimit {
            licenseLimit.limit = limit
            licenseWindow.makeKeyAndOrderFront(nil)
            return
        }
        let holder = LicenseLimitHolder(limit: limit)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 460, height: 580),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "\(AppConstants.name) License"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: LicenseWindowContent(
            license: controller.license, usage: controller.usage, holder: holder))
        window.center()
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.licenseWindow = nil
                    self?.licenseLimit = nil
                }
            }
        window.makeKeyAndOrderFront(nil)
        licenseWindow = window
        licenseLimit = holder
    }
}

/// The limit the open license window is headed by: a second one reached while it's up
/// replaces the first.
@MainActor
@Observable
private final class LicenseLimitHolder {
    var limit: Limit?
    init(limit: Limit?) { self.limit = limit }
}

private struct LicenseWindowContent: View {
    let license: LicenseManager
    let usage: UsageMeter
    let holder: LicenseLimitHolder

    var body: some View {
        LicenseView(license: license, usage: usage, limit: holder.limit)
            .frame(width: 460, height: 580)
            .foregroundStyle(Color.ink)
            .tint(Color.accent)
    }
}
