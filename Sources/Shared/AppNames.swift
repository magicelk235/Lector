import AppKit
import UniformTypeIdentifiers

enum AppNames {
    /// "Safari" for "com.apple.Safari", as Finder shows it; the identifier itself for an
    /// app no longer on the Mac.
    static func name(forBundleID bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        let name = FileManager.default.displayName(atPath: url.path(percentEncoded: false))
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    /// The app's icon at 16 points, as a list shows it; a generic app's for one no longer
    /// on the Mac.
    static func icon(forBundleID bundleID: String) -> NSImage {
        let workspace = NSWorkspace.shared
        let icon = workspace.urlForApplication(withBundleIdentifier: bundleID)
            .map { workspace.icon(forFile: $0.path(percentEncoded: false)) } ?? workspace.icon(for: .applicationBundle)
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }
}
