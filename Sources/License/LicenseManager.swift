import Foundation

/// The license key the user bought on Gumroad, and the tier it gives.
///
/// Lector is one Gumroad product with two versions, Text and Translate, plus a separate
/// upgrade product that turns a Text license into Translate. Every key is checked with
/// Gumroad's license API when it's entered and again at each launch. A key Gumroad
/// accepted once keeps working without a network for `offlineGrace`, so Lector stays
/// usable offline; a key Gumroad turns down (refunded, disputed, unknown) is forgotten.
///
/// https://gumroad.com/api#licenses
@MainActor
@Observable
final class LicenseManager {
    nonisolated static let productID = "NiBMY3O2KJjXseWPGuS6sA=="
    nonisolated static let upgradeProductID = "Cr26UgEWcI4Eea5eipRssA=="
    nonisolated static let offlineGrace: TimeInterval = 30 * 86_400

    /// What Gumroad says about a key, as far as Lector cares.
    struct Purchase: Equatable, Sendable {
        /// The version bought, as Gumroad lists it: "(Translate)" or similar; empty for
        /// a product without versions.
        var variants: String
        var email: String?
    }

    enum VerifyError: Error, Equatable {
        /// Gumroad answered and said no.
        case rejected(String)
        /// Gumroad couldn't be reached, or answered with a server error.
        case unreachable
    }

    typealias Verifier = @Sendable (_ productID: String, _ key: String) async throws(VerifyError) -> Purchase

    /// What's saved between launches: the keys, and the tier they gave when Gumroad last
    /// confirmed them, for launches without a network.
    struct Stored: Codable, Equatable {
        var key: String
        /// The version the key itself is for: Text or Translate.
        var keyTier: Tier
        var upgradeKey: String?
        var email: String?
        var verified: Date
    }

    private(set) var stored: Stored?
    private(set) var isChecking = false
    /// Why the last activation or launch check didn't work out, for the license window.
    var error: String?

    @ObservationIgnored private let file: URL
    @ObservationIgnored private let verify: Verifier
    @ObservationIgnored private let now: () -> Date

    init(directory: URL, verify: @escaping Verifier = LicenseManager.gumroad, now: @escaping () -> Date = Date.init) {
        file = directory.appendingPathComponent("license.json")
        self.verify = verify
        self.now = now
        stored = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
    }

    var tier: Tier {
        guard let stored else { return .free }
        return stored.keyTier == .text && stored.upgradeKey != nil ? .translate : stored.keyTier
    }

    // MARK: Launch

    /// Asks Gumroad about the saved keys again. Without an answer, the tier from the last
    /// answer holds until the grace period runs out.
    func refresh() async {
        guard var current = stored else { return }
        isChecking = true
        defer { isChecking = false }
        do {
            let purchase = try await verify(Self.productID, current.key)
            current.keyTier = Self.tier(of: purchase)
            current.email = purchase.email ?? current.email
            if let upgrade = current.upgradeKey {
                do {
                    _ = try await verify(Self.upgradeProductID, upgrade)
                } catch .rejected(let reason) {
                    current.upgradeKey = nil
                    error = reason
                }
            }
            current.verified = now()
            save(current)
        } catch .rejected(let reason) {
            save(nil)
            error = reason
        } catch {
            if now().timeIntervalSince(current.verified) > Self.offlineGrace {
                save(nil)
                self.error = "Lector couldn't reach Gumroad to check your license for a month. "
                    + "Connect to the internet and enter your key again."
            }
        }
    }

    // MARK: Activation

    /// A key from either product: Lector's own (Text or Translate) replaces any saved
    /// key, and an upgrade key is added to the Text key already active.
    func activate(_ rawKey: String) async {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        error = nil
        isChecking = true
        defer { isChecking = false }
        do {
            let purchase = try await verify(Self.productID, key)
            // A new license of Lector's own; an upgrade bought earlier still applies to it.
            save(Stored(key: key, keyTier: Self.tier(of: purchase), upgradeKey: stored?.upgradeKey,
                        email: purchase.email, verified: now()))
            return
        } catch .unreachable {
            error = Self.unreachableMessage
            return
        } catch {
            // Not a key for Lector itself: it may be an upgrade.
        }
        do {
            _ = try await verify(Self.upgradeProductID, key)
        } catch .unreachable {
            error = Self.unreachableMessage
            return
        } catch {
            self.error = "Gumroad doesn't know this key. Check that you copied all of it."
            return
        }
        guard var current = stored else {
            error = "This is an upgrade key. Enter your Lector Text key first, then this one."
            return
        }
        guard current.keyTier == .text else {
            error = "Your license already includes Translate."
            return
        }
        current.upgradeKey = key
        current.verified = now()
        save(current)
    }

    /// Forgets the keys on this Mac, to move them to another one. Gumroad keeps no
    /// record of activations, so there's nothing to tell it.
    func remove() {
        error = nil
        save(nil)
    }

    private static let unreachableMessage = "Lector couldn't reach Gumroad. Check your connection and try again."

    /// The version is all a Lector key differs by. Matching the name rather than the
    /// exact format Gumroad writes it in keeps working if that format changes.
    nonisolated static func tier(of purchase: Purchase) -> Tier {
        purchase.variants.localizedCaseInsensitiveContains("translate") ? .translate : .text
    }

    private func save(_ value: Stored?) {
        stored = value
        guard let value, let data = try? JSONEncoder().encode(value) else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    // MARK: Gumroad

    private nonisolated static let verifyURL = URL(string: "https://api.gumroad.com/v2/licenses/verify")!

    /// POST /v2/licenses/verify without counting a use: the count would only climb with
    /// every launch, and Lector doesn't cap activations.
    nonisolated static let gumroad: Verifier = { (productID: String, key: String) async throws(VerifyError) -> Purchase in
        var request = URLRequest(url: verifyURL, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "product_id", value: productID),
            URLQueryItem(name: "license_key", value: key),
            URLQueryItem(name: "increment_uses_count", value: "false"),
        ]
        // URLComponents leaves "+" alone, which a form body reads as a space.
        request.httpBody = form.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw .unreachable
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return try purchase(from: data, status: status)
    }

    /// Reads Gumroad's answer. A purchase that was refunded, disputed or charged back no
    /// longer counts.
    nonisolated static func purchase(from data: Data, status: Int) throws(VerifyError) -> Purchase {
        guard status < 500,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { throw .unreachable }
        guard json["success"] as? Bool == true, let purchase = json["purchase"] as? [String: Any] else {
            throw .rejected("Gumroad doesn't know this key. Check that you copied all of it.")
        }
        for (flag, word) in [("refunded", "refunded"), ("disputed", "disputed"), ("chargebacked", "charged back")]
        where purchase[flag] as? Bool == true {
            throw .rejected("This purchase was \(word), so its license no longer works.")
        }
        return Purchase(variants: purchase["variants"] as? String ?? "", email: purchase["email"] as? String)
    }
}
