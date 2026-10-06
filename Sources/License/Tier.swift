import Foundation

/// What a license buys. Free and Text count captures per calendar month; Translate
/// counts nothing and is the only one with live translation.
enum Tier: String, Codable, Sendable {
    case free, text, translate

    var name: String {
        switch self {
        case .free: "Free"
        case .text: "Text"
        case .translate: "Translate"
        }
    }

    /// nil: unlimited.
    var grabsPerMonth: Int? { self == .free ? 100 : nil }

    /// nil: unlimited.
    var translationsPerMonth: Int? {
        switch self {
        case .free: 10
        case .text: 30
        case .translate: nil
        }
    }

    var allowsLive: Bool { self == .translate }

    /// Why `purpose` can't start with this much already used this month, or nil when it
    /// can. A capture under way is never stopped: only starting one is refused.
    func limit(for purpose: AppController.Purpose, grabs: Int, translations: Int) -> Limit? {
        switch purpose {
        case .grab:
            guard let cap = grabsPerMonth, grabs >= cap else { return nil }
            return .grabs(cap)
        case .translate:
            guard let cap = translationsPerMonth, translations >= cap else { return nil }
            return .translations(cap, free: self == .free)
        case .live:
            return allowsLive ? nil : .live
        }
    }
}

/// A limit the user ran into, said the way the license window opens with it.
enum Limit: Equatable, Sendable {
    case grabs(Int)
    case translations(Int, free: Bool)
    case live

    var message: String {
        switch self {
        case .grabs(let cap):
            "You've used this month's \(cap) free grabs."
        case .translations(let cap, let free):
            "You've used this month's \(cap) \(free ? "free " : "")translations."
        case .live:
            "Live translation comes with Lector Translate."
        }
    }
}
