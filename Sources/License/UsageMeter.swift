import Foundation

/// Grabs and translations used this calendar month. Each new month starts from zero.
///
/// Kept in UserDefaults, so deleting Lector's preferences resets it. That's accepted:
/// anyone who goes that far to avoid paying wasn't going to pay.
@MainActor
@Observable
final class UsageMeter {
    enum Kind: String { case grab, translation }

    private struct Stored: Codable {
        var month: Int
        var grabs: Int
        var translations: Int
    }

    private static let defaultsKey = "Usage"

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Date
    private var stored: Stored

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
        stored = defaults.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
            ?? Stored(month: 0, grabs: 0, translations: 0)
    }

    /// How many of `kind` this month so far.
    func used(_ kind: Kind) -> Int {
        guard stored.month == currentMonth else { return 0 }
        return kind == .grab ? stored.grabs : stored.translations
    }

    func record(_ kind: Kind) {
        let month = currentMonth
        if stored.month != month { stored = Stored(month: month, grabs: 0, translations: 0) }
        switch kind {
        case .grab: stored.grabs += 1
        case .translation: stored.translations += 1
        }
        if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    /// The month as yyyymm, in the user's own calendar and time zone.
    private var currentMonth: Int {
        let parts = Calendar.current.dateComponents([.year, .month], from: now())
        return (parts.year ?? 0) * 100 + (parts.month ?? 0)
    }
}
