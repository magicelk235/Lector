import Foundation

/// Every user-visible mention of the product name resolves here, so a rename is
/// this file plus project.yml and nothing else.
enum AppConstants {
    static let name = "Lector"
    static let bundleID = "com.magicelklabs.lector"
    /// Folder under Application Support for downloaded translation models.
    static let supportFolder = "Lector"
    static let supportURL = URL(string: "https://magicelk235.github.io/lector")!
    /// Polar checkouts for Text, Translate, and the Text-to-Translate upgrade.
    static let textCheckoutURL = URL(string: "https://buy.polar.sh/polar_cl_tkgqF9gxvlZNU5Ge769WkrAE6Slzsr5e2PmnI4HV1NT")!
    static let translateCheckoutURL = URL(string: "https://buy.polar.sh/polar_cl_DRiORzR9dAEomeWXX9oMsMB5YfOMM0lEn58xm0dzoKs")!
    static let upgradeCheckoutURL = URL(string: "https://buy.polar.sh/polar_cl_AI6jll9ffzZxapGmXkblVNZEQE0yecYUrLbcU2qceSe")!
}
