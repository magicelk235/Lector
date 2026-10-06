import AppKit
import Sparkle

/// Self-updating through Sparkle. The feed, the public key and installing in the
/// background are set in Info.plist (project.yml); this decides when a downloaded update
/// may install, and gives Settings and the menu something to call.
///
/// Sparkle asks once, on the second launch, before it checks for anything. After that it
/// checks daily. Debug builds never check: they'd be offered the release build.
@MainActor
final class Updater: NSObject {
    static let shared = Updater()

    /// True while replacing the app would cut something short: a live translation or a
    /// capture on screen.
    var isBusy: () -> Bool = { false }

    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)

    func start() {
        #if !DEBUG
        controller.startUpdater()
        #endif
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    /// Shows Sparkle's own window, including "You're up to date".
    func checkForUpdates() {
        // A menu-bar app's windows open behind the app in front unless it's a regular app.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
}

extension Updater: SPUUpdaterDelegate {
    /// Sparkle installs a downloaded update when the app quits, but Lector rarely quits:
    /// it lives in the menu bar, and ⌘Q only closes its windows. So it installs straight
    /// away instead, and Sparkle relaunches it, unless something is under way; then it
    /// waits for the quit after all.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock: @escaping () -> Void) -> Bool {
        guard !isBusy() else { return false }
        // Sparkle quits the app to install, which the menu-bar quit handling would refuse.
        AppDelegate.quitRequested = true
        immediateInstallationBlock()
        // If installing doesn't go ahead, ⌘Q goes back to only closing the windows.
        Task {
            try? await Task.sleep(for: .seconds(30))
            AppDelegate.quitRequested = false
        }
        return true
    }
}
