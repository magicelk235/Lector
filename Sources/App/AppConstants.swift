import Foundation

/// Every user-visible mention of the product name resolves here, so a rename is
/// this file plus project.yml and nothing else.
enum AppConstants {
    static let name = "Lector"
    static let bundleID = "com.magicelklabs.lector"
    /// Folder under Application Support for downloaded translation models.
    static let supportFolder = "Lector"
    static let supportURL = URL(string: "https://magicelk235.github.io/lector")!
    static let price = "$15"
}
