import Foundation

/// Every user-visible mention of the product name resolves here, so a rename is
/// this file plus project.yml and nothing else.
enum AppConstants {
    static let name = "Lector"
    static let bundleID = "com.magicelklabs.lector"
    /// Folder under Application Support for downloaded translation models.
    static let supportFolder = "Lector"
    static let supportURL = URL(string: "https://magicelk235.github.io/lector")!
    /// Where Text and Translate are bought, and the Text-to-Translate upgrade.
    static let storeURL = URL(string: "https://magicelk235.gumroad.com/l/lector")!
    static let upgradeURL = URL(string: "https://magicelk235.gumroad.com/l/lector-upgrade")!
}
