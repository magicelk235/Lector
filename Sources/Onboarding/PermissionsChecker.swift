import AppKit
import CoreGraphics

/// Screen Recording is the only permission this app needs.
///
/// Stage 5 measured the global modifier monitor working with Accessibility denied, so
/// nothing here checks `AXIsProcessTrusted()` and no UI mentions it. One permission is
/// a materially easier sell than two.
@MainActor
@Observable
final class PermissionsChecker {
    private(set) var hasScreenRecording: Bool = CGPreflightScreenCaptureAccess()

    /// `CGRequestScreenCaptureAccess` only ever prompts once per launch. Calling it
    /// again silently returns, leaving the user staring at a button that does nothing,
    /// so after the first attempt they are sent to System Settings instead.
    private(set) var hasRequestedThisLaunch = false

    func refresh() {
        hasScreenRecording = CGPreflightScreenCaptureAccess()
    }

    /// Ask the system, once. Returns false when the prompt has already been spent.
    @discardableResult
    func request() -> Bool {
        guard !hasRequestedThisLaunch else {
            openSettings()
            return false
        }
        hasRequestedThisLaunch = true
        let granted = CGRequestScreenCaptureAccess()
        refresh()
        return granted
    }

    func openSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Screen Recording only takes effect after a relaunch, which users otherwise
    /// discover by the app not working.
    func relaunch() {
        let url = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            Task { @MainActor in AppDelegate.quit() }
        }
    }
}
