import Foundation

/// The license keys the user bought, and the tier they give.
///
/// Lector is sold on Polar as three products: Text, Translate, and an upgrade that turns a
/// Text license into Translate. Each has its own license-key benefit, so the benefit a key
/// belongs to says what it's for. Keys bought on Gumroad before the move (one product with
/// Text and Translate versions, plus a separate upgrade product) keep working.
///
/// Every key is checked with the store that sold it when it's entered and again at each
/// launch. A key accepted once keeps working without a network for `offlineGrace`, so
/// Lector stays usable offline; a key the store turns down (refunded, revoked, unknown) is
/// forgotten. Neither store caps how many Macs use a key.
///
/// https://polar.sh/docs/features/benefits/license-keys
/// https://gumroad.com/api#licenses
@MainActor
@Observable
final class LicenseManager {
    nonisolated static let offlineGrace: TimeInterval = 30 * 86_400

    /// What a key is for.
    enum Product: Equatable, Sendable {
        case text, translate, upgrade

        /// The tier a key of Lector's own gives; nil for an upgrade key.
        var tier: Tier? {
            switch self {
            case .text: .text
            case .translate: .translate
            case .upgrade: nil
            }
        }
    }

    /// Where a key was bought.
    enum Store: String, Codable, Sendable {
        case polar, gumroad
    }

    /// What a store says about a key, as far as Lector cares.
    struct Purchase: Equatable, Sendable {
        var product: Product
        var email: String?
    }

    enum VerifyError: Error, Equatable {
        /// The store has never heard of the key.
        case unknown
        /// The store knows the key and turned it down, for this reason.
        case rejected(String)
        /// The store couldn't be reached, or answered with something other than its own verdict.
        case unreachable
    }

    typealias Verifier = @Sendable (_ store: Store, _ key: String) async throws(VerifyError) -> Purchase

    /// What's saved between launches: the keys, where each was bought, and the tier they
    /// gave when last confirmed, for launches without a network.
    struct Stored: Codable, Equatable {
        var key: String
        var keyStore: Store
        /// The version the key itself is for: Text or Translate.
        var keyTier: Tier
        var upgradeKey: String?
        var upgradeStore: Store?
        var email: String?
        var verified: Date

        init(key: String, keyStore: Store, keyTier: Tier, upgradeKey: String? = nil, upgradeStore: Store? = nil,
             email: String?, verified: Date) {
            self.key = key
            self.keyStore = keyStore
            self.keyTier = keyTier
            self.upgradeKey = upgradeKey
            self.upgradeStore = upgradeStore
            self.email = email
            self.verified = verified
        }

        /// A license saved before Polar has no stores written down; every key in it came from Gumroad.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            key = try container.decode(String.self, forKey: .key)
            keyStore = try container.decodeIfPresent(Store.self, forKey: .keyStore) ?? .gumroad
            keyTier = try container.decode(Tier.self, forKey: .keyTier)
            upgradeKey = try container.decodeIfPresent(String.self, forKey: .upgradeKey)
            upgradeStore = try container.decodeIfPresent(Store.self, forKey: .upgradeStore)
                ?? (upgradeKey == nil ? nil : .gumroad)
            email = try container.decodeIfPresent(String.self, forKey: .email)
            verified = try container.decode(Date.self, forKey: .verified)
        }
    }

    private(set) var stored: Stored?
    private(set) var isChecking = false
    /// Why the last activation or launch check didn't work out, for the license window.
    var error: String?

    @ObservationIgnored private let file: URL
    @ObservationIgnored private let verify: Verifier
    @ObservationIgnored private let now: () -> Date

    init(directory: URL, verify: @escaping Verifier = LicenseManager.live, now: @escaping () -> Date = Date.init) {
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

    /// Asks the stores about the saved keys again. Without an answer, the tier from the
    /// last answer holds until the grace period runs out.
    func refresh() async {
        guard var current = stored else { return }
        isChecking = true
        defer { isChecking = false }
        do throws(VerifyError) {
            let purchase = try await verify(current.keyStore, current.key)
            guard let tier = purchase.product.tier else { throw VerifyError.unknown }
            current.keyTier = tier
            current.email = purchase.email ?? current.email
            if let upgrade = current.upgradeKey {
                do throws(VerifyError) {
                    let upgradePurchase = try await verify(current.upgradeStore ?? .gumroad, upgrade)
                    if upgradePurchase.product != .upgrade { throw VerifyError.unknown }
                } catch .unreachable {
                    // The upgrade holds as long as the key it upgrades does.
                } catch {
                    current.upgradeKey = nil
                    current.upgradeStore = nil
                    self.error = Self.message(for: error)
                }
            }
            current.verified = now()
            save(current)
        } catch .unreachable {
            if now().timeIntervalSince(current.verified) > Self.offlineGrace {
                save(nil)
                error = "Lector couldn't check your license for a month. "
                    + "Connect to the internet and enter your key again."
            }
        } catch {
            save(nil)
            self.error = Self.message(for: error)
        }
    }

    // MARK: Activation

    /// A key from any product: Lector's own (Text or Translate) replaces any saved key, and
    /// an upgrade key is added to the Text key already active.
    func activate(_ rawKey: String) async {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        error = nil
        isChecking = true
        defer { isChecking = false }
        let store: Store
        let purchase: Purchase
        do {
            (store, purchase) = try await identify(key)
        } catch {
            self.error = Self.message(for: error)
            return
        }
        if let tier = purchase.product.tier {
            // A new license of Lector's own; an upgrade bought earlier still applies to it.
            save(Stored(key: key, keyStore: store, keyTier: tier, upgradeKey: stored?.upgradeKey,
                        upgradeStore: stored?.upgradeStore, email: purchase.email, verified: now()))
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
        current.upgradeStore = store
        current.verified = now()
        save(current)
    }

    /// Asks Polar first, where Lector is sold now, and Gumroad only about a key Polar has
    /// never heard of.
    private func identify(_ key: String) async throws(VerifyError) -> (Store, Purchase) {
        do {
            return (.polar, try await verify(.polar, key))
        } catch .unknown {
            return (.gumroad, try await verify(.gumroad, key))
        }
    }

    /// Forgets the keys on this Mac, to move them to another one. Neither store keeps a
    /// record of the Macs a key is on, so there's nothing to tell them.
    func remove() {
        error = nil
        save(nil)
    }

    private static func message(for error: VerifyError) -> String {
        switch error {
        case .unknown: "Lector doesn't know this key. Check that you copied all of it."
        case .rejected(let reason): reason
        case .unreachable: "Lector couldn't reach the store to check your key. Try again once you're online."
        }
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

    // MARK: Stores

    nonisolated static let live: Verifier = { (store: Store, key: String) async throws(VerifyError) -> Purchase in
        switch store {
        case .polar:
            return try await polar(key)
        case .gumroad:
            do throws(VerifyError) {
                return try await gumroad(productID: gumroadProductID, key: key)
            } catch .unknown {
                return try await gumroad(productID: gumroadUpgradeProductID, key: key)
            }
        }
    }

    /// POSTs a request and hands back the body and status, or `.unreachable` without a response.
    private nonisolated static func send(_ request: URLRequest) async throws(VerifyError) -> (Data, Int) {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            throw .unreachable
        }
    }

    // MARK: Polar

    nonisolated static let polarOrganizationID = "760e4bf4-f5a2-4a74-8a22-66da54f6f33b"
    /// The license-key benefit of each Lector product on Polar.
    nonisolated static let polarBenefits: [String: Product] = [
        "47775725-6d58-428a-a664-70271f2e0edc": .text,
        "fba4c928-be07-45ea-989a-70d343713df5": .translate,
        "ab55a39f-bfc2-4528-9941-c8160654571d": .upgrade,
    ]

    private nonisolated static let polarValidateURL =
        URL(string: "https://api.polar.sh/v1/customer-portal/license-keys/validate")!

    /// The customer-portal endpoint, which takes no access token, only the organization.
    /// No Polar-Version header: Polar retires a pinned version after about nine months and
    /// then answers 404 to everything.
    private nonisolated static func polar(_ key: String) async throws(VerifyError) -> Purchase {
        var request = URLRequest(url: polarValidateURL, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["key": key, "organization_id": polarOrganizationID])
        let (data, status) = try await send(request)
        return try polarPurchase(from: data, status: status)
    }

    /// Reads Polar's answer. Polar only says yes to a granted key, so a refunded or revoked
    /// one comes back as a 404. Only Polar's own error bodies count as a no: anything else
    /// (an outage, a proxy's page, a request Polar couldn't parse) leaves the key as it was.
    nonisolated static func polarPurchase(from data: Data, status: Int) throws(VerifyError) -> Purchase {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if status == 200 {
            guard let benefit = json?["benefit_id"] as? String else { throw .unreachable }
            // The same Polar account sells other apps.
            guard let product = polarBenefits[benefit] else { throw .rejected("This key is for a different app.") }
            let customer = json?["customer"] as? [String: Any]
            return Purchase(product: product, email: customer?["email"] as? String)
        }
        guard status == 404, json?["error"] as? String == "ResourceNotFound",
              let detail = json?["detail"] as? String
        else { throw .unreachable }
        // "Not found" is Polar's stock answer for a key it doesn't have.
        throw detail == "Not found" ? .unknown : .rejected(detail)
    }

    // MARK: Gumroad

    nonisolated static let gumroadProductID = "NiBMY3O2KJjXseWPGuS6sA=="
    nonisolated static let gumroadUpgradeProductID = "Cr26UgEWcI4Eea5eipRssA=="

    private nonisolated static let gumroadVerifyURL = URL(string: "https://api.gumroad.com/v2/licenses/verify")!

    /// POST /v2/licenses/verify without counting a use: the count would only climb with
    /// every launch, and Lector doesn't cap activations.
    private nonisolated static func gumroad(productID: String, key: String) async throws(VerifyError) -> Purchase {
        var request = URLRequest(url: gumroadVerifyURL, timeoutInterval: 15)
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
        let (data, status) = try await send(request)
        return try gumroadPurchase(from: data, status: status, upgrade: productID == gumroadUpgradeProductID)
    }

    /// Reads Gumroad's answer. A purchase that was refunded, disputed or charged back no
    /// longer counts. Lector's own product says Text or Translate in the version bought;
    /// matching the name rather than the exact format Gumroad writes it in keeps working if
    /// that format changes.
    nonisolated static func gumroadPurchase(from data: Data, status: Int, upgrade: Bool) throws(VerifyError) -> Purchase {
        guard status < 500,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { throw .unreachable }
        guard json["success"] as? Bool == true, let purchase = json["purchase"] as? [String: Any] else {
            throw .unknown
        }
        for (flag, word) in [("refunded", "refunded"), ("disputed", "disputed"), ("chargebacked", "charged back")]
        where purchase[flag] as? Bool == true {
            throw .rejected("This purchase was \(word), so its license no longer works.")
        }
        let variants = purchase["variants"] as? String ?? ""
        let product: Product = upgrade ? .upgrade
            : variants.localizedCaseInsensitiveContains("translate") ? .translate : .text
        return Purchase(product: product, email: purchase["email"] as? String)
    }
}
