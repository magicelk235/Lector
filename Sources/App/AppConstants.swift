import Foundation

/// Every user-visible mention of the product name resolves here, so a rename is
/// this file plus project.yml and nothing else.
enum AppConstants {
    static let name = "Hover Lens"
    static let bundleID = "com.magicelklabs.hoverlens"
    /// Folder under Application Support for downloaded translation models.
    static let supportFolder = "HoverLens"
    static let supportURL = URL(string: "https://magicelk235.github.io/hover-lens")!
    static let price = "$15"
}
