import Foundation

/// The Buy and Upgrade links. They open a product's Polar checkout, tagged so the order's
/// metadata says where in Lector the button was pressed, on which plan, how much of this
/// month's grabs and translations had been used, and roughly how long Lector had been
/// installed.
enum BuyLink {
    /// Where the Buy button was pressed.
    enum Origin: Equatable {
        case settings
        /// The license window: opened from the menu bar's Buy item (nil), or by reaching a limit.
        case window(Limit?)
    }

    static func url(_ checkout: URL, from origin: Origin, tier: Tier, grabs: Int, translations: Int,
                    daysSinceFirstLaunch days: Int) -> URL {
        guard var components = URLComponents(url: checkout, resolvingAgainstBaseURL: false) else { return checkout }
        components.queryItems = [
            URLQueryItem(name: "utm_source", value: "lector-app"),
            URLQueryItem(name: "utm_medium", value: "app"),
            URLQueryItem(name: "utm_campaign", value: campaign(origin)),
            URLQueryItem(name: "utm_term", value: "g\(grabs)-t\(translations)"),
            URLQueryItem(name: "utm_content", value: "\(tier.rawValue)-\(installAge(days))"),
        ]
        // URLComponents leaves "+" alone, which a server reads back as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url ?? checkout
    }

    private static func campaign(_ origin: Origin) -> String {
        switch origin {
        case .settings: "settings"
        case .window(nil): "menu"
        case .window(.grabs?): "limit-grabs"
        case .window(.translations?): "limit-translations"
        case .window(.live?): "limit-live"
        }
    }

    /// Bucketed, so the tag says how soon someone bought without dating the install.
    private static func installAge(_ days: Int) -> String {
        switch days {
        case ..<2: "d0-1"
        case 2...7: "d2-7"
        case 8...30: "d8-30"
        default: "d31+"
        }
    }
}
