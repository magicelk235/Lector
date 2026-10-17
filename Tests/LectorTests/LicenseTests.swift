import XCTest
@testable import Lector

final class TierLimitTests: XCTestCase {
    func testFreeStopsAtTheHundredthGrabAndTenthTranslation() {
        XCTAssertNil(Tier.free.limit(for: .grab, grabs: 99, translations: 0))
        XCTAssertEqual(Tier.free.limit(for: .grab, grabs: 100, translations: 0), .grabs(100))
        XCTAssertNil(Tier.free.limit(for: .translate, grabs: 0, translations: 9))
        XCTAssertEqual(Tier.free.limit(for: .translate, grabs: 0, translations: 10), .translations(10, free: true))
    }

    func testTextGrabsWithoutLimitButCountsTranslations() {
        XCTAssertNil(Tier.text.limit(for: .grab, grabs: 10_000, translations: 0))
        XCTAssertNil(Tier.text.limit(for: .translate, grabs: 0, translations: 29))
        XCTAssertEqual(Tier.text.limit(for: .translate, grabs: 0, translations: 30), .translations(30, free: false))
    }

    func testOnlyTranslateHasLiveAndNoLimits() {
        XCTAssertEqual(Tier.free.limit(for: .live, grabs: 0, translations: 0), .live)
        XCTAssertEqual(Tier.text.limit(for: .live, grabs: 0, translations: 0), .live)
        XCTAssertNil(Tier.translate.limit(for: .live, grabs: 0, translations: 0))
        XCTAssertNil(Tier.translate.limit(for: .translate, grabs: 10_000, translations: 10_000))
    }
}

@MainActor
final class UsageMeterTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        suite = "UsageMeterTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    func testCountsStartOverInANewMonthAndSurviveRelaunch() {
        var now = date(2026, 10, 31)
        let meter = UsageMeter(defaults: defaults, now: { now })
        meter.record(.grab)
        meter.record(.grab)
        meter.record(.translation)
        XCTAssertEqual(UsageMeter(defaults: defaults, now: { now }).used(.grab), 2)

        now = date(2026, 11, 1)
        XCTAssertEqual(meter.used(.grab), 0)
        XCTAssertEqual(meter.used(.translation), 0)
        meter.record(.translation)
        XCTAssertEqual(meter.used(.translation), 1)
        XCTAssertEqual(meter.used(.grab), 0)
    }

    func testInstallAgeCountsFromTheFirstLaunchOnly() {
        var now = date(2026, 10, 1)
        _ = UsageMeter(defaults: defaults, now: { now })
        now = date(2026, 10, 9)
        let later = UsageMeter(defaults: defaults, now: { now })
        XCTAssertEqual(later.daysSinceFirstLaunch, 8)
        now = date(2026, 11, 1)
        XCTAssertEqual(later.daysSinceFirstLaunch, 31)
    }
}

final class BuyLinkTests: XCTestCase {
    private func query(_ origin: BuyLink.Origin = .settings, version: String? = nil, tier: Tier = .free,
                       grabs: Int = 0, translations: Int = 0, days: Int = 0) -> [String: String] {
        let url = BuyLink.url(AppConstants.storeURL, version: version, from: origin, tier: tier, grabs: grabs,
                              translations: translations, daysSinceFirstLaunch: days)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    func testOpensCheckoutWithTheVersionChosen() {
        let text = query(version: "Text")
        XCTAssertEqual(text["wanted"], "true")
        XCTAssertEqual(text["variant"], "Text")
        let upgrade = query()
        XCTAssertEqual(upgrade["wanted"], "true")
        XCTAssertNil(upgrade["variant"])
    }

    func testCampaignSaysWhereTheBuyButtonWasPressed() {
        XCTAssertEqual(query(.settings)["utm_campaign"], "settings")
        XCTAssertEqual(query(.window(nil))["utm_campaign"], "menu")
        XCTAssertEqual(query(.window(.grabs(100)))["utm_campaign"], "limit-grabs")
        XCTAssertEqual(query(.window(.translations(30, free: false)))["utm_campaign"], "limit-translations")
        XCTAssertEqual(query(.window(.live))["utm_campaign"], "limit-live")
    }

    func testCarriesAllThreeRequiredParamsUsageAndTier() {
        let tags = query(.settings, tier: .text, grabs: 87, translations: 30, days: 5)
        XCTAssertEqual(tags["utm_source"], "lector-app")
        XCTAssertEqual(tags["utm_medium"], "app")
        XCTAssertEqual(tags["utm_term"], "g87-t30")
        XCTAssertEqual(tags["utm_content"], "text-d2-7")
    }

    func testInstallAgeBucketBoundaries() {
        XCTAssertEqual(query(.settings, days: -3)["utm_content"], "free-d0-1")
        XCTAssertEqual(query(.settings, days: 1)["utm_content"], "free-d0-1")
        XCTAssertEqual(query(.settings, days: 2)["utm_content"], "free-d2-7")
        XCTAssertEqual(query(.settings, days: 7)["utm_content"], "free-d2-7")
        XCTAssertEqual(query(.settings, days: 8)["utm_content"], "free-d8-30")
        XCTAssertEqual(query(.settings, days: 30)["utm_content"], "free-d8-30")
        XCTAssertEqual(query(.settings, days: 31)["utm_content"], "free-d31+")
    }

    func testPlusSurvivesAsALiteralPlusNotASpace() {
        let url = BuyLink.url(AppConstants.storeURL, from: .settings, tier: .free, grabs: 0,
                              translations: 0, daysSinceFirstLaunch: 40)
        XCTAssertTrue(url.absoluteString.contains("utm_content=free-d31%2B"), url.absoluteString)
    }
}

/// Gumroad stood in for by a table of keys.
private actor FakeGumroad {
    var keys: [String: [String: LicenseManager.Purchase]] = [:]
    var reachable = true

    func set(_ productID: String, _ key: String, variants: String) {
        keys[productID, default: [:]][key] = LicenseManager.Purchase(variants: variants, email: "buyer@example.com")
    }

    func forget(_ productID: String, _ key: String) { keys[productID]?[key] = nil }
    func setReachable(_ value: Bool) { reachable = value }

    func verify(_ productID: String, _ key: String) throws(LicenseManager.VerifyError) -> LicenseManager.Purchase {
        guard reachable else { throw .unreachable }
        guard let purchase = keys[productID]?[key] else { throw .rejected("unknown") }
        return purchase
    }
}

@MainActor
final class LicenseManagerTests: XCTestCase {
    private var directory: URL!
    private let gumroad = FakeGumroad()
    private var now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func manager() -> LicenseManager {
        let gumroad = gumroad
        return LicenseManager(directory: directory,
                              verify: { product, key throws(LicenseManager.VerifyError) in
                                  try await gumroad.verify(product, key)
                              },
                              now: { [unowned self] in now })
    }

    func testVersionBoughtDecidesTheTierAndIsKeptAcrossLaunches() async {
        await gumroad.set(LicenseManager.productID, "TEXT-KEY", variants: "(Text)")
        await gumroad.set(LicenseManager.productID, "TRANSLATE-KEY", variants: "(Translate)")
        let license = manager()
        XCTAssertEqual(license.tier, .free)

        await license.activate("  TEXT-KEY\n")
        XCTAssertEqual(license.tier, .text)
        XCTAssertNil(license.error)

        await license.activate("TRANSLATE-KEY")
        XCTAssertEqual(manager().tier, .translate)
    }

    func testUpgradeKeyNeedsATextKeyFirst() async {
        await gumroad.set(LicenseManager.productID, "TEXT-KEY", variants: "(Text)")
        await gumroad.set(LicenseManager.upgradeProductID, "UPGRADE-KEY", variants: "")
        let license = manager()

        await license.activate("UPGRADE-KEY")
        XCTAssertEqual(license.tier, .free)
        XCTAssertNotNil(license.error)

        await license.activate("TEXT-KEY")
        await license.activate("UPGRADE-KEY")
        XCTAssertEqual(license.tier, .translate)
        XCTAssertEqual(manager().tier, .translate)
    }

    func testUnknownKeyLeavesTheLicenseAsItWas() async {
        await gumroad.set(LicenseManager.productID, "TEXT-KEY", variants: "(Text)")
        let license = manager()
        await license.activate("TEXT-KEY")
        await license.activate("TYPO-KEY")
        XCTAssertEqual(license.tier, .text)
        XCTAssertNotNil(license.error)
    }

    func testOfflineLaunchKeepsTheTierUntilTheGraceRunsOut() async {
        await gumroad.set(LicenseManager.productID, "TRANSLATE-KEY", variants: "(Translate)")
        await manager().activate("TRANSLATE-KEY")
        await gumroad.setReachable(false)

        now += LicenseManager.offlineGrace - 60
        let early = manager()
        await early.refresh()
        XCTAssertEqual(early.tier, .translate)

        now += 120
        let late = manager()
        await late.refresh()
        XCTAssertEqual(late.tier, .free)
    }

    func testKeyGumroadNoLongerAcceptsIsDroppedAtLaunch() async {
        await gumroad.set(LicenseManager.productID, "TEXT-KEY", variants: "(Text)")
        await gumroad.set(LicenseManager.upgradeProductID, "UPGRADE-KEY", variants: "")
        let license = manager()
        await license.activate("TEXT-KEY")
        await license.activate("UPGRADE-KEY")

        await gumroad.forget(LicenseManager.upgradeProductID, "UPGRADE-KEY")
        await license.refresh()
        XCTAssertEqual(license.tier, .text)

        await gumroad.forget(LicenseManager.productID, "TEXT-KEY")
        await license.refresh()
        XCTAssertEqual(manager().tier, .free)
    }

    func testRefundedPurchaseIsRejected() {
        let body = Data(#"{"success":true,"purchase":{"variants":"(Translate)","refunded":true}}"#.utf8)
        XCTAssertThrowsError(try LicenseManager.purchase(from: body, status: 200)) { error in
            guard case .rejected = error as? LicenseManager.VerifyError else {
                return XCTFail("expected a rejection, got \(error)")
            }
        }
    }

    func testServerErrorIsNotARejection() {
        XCTAssertThrowsError(try LicenseManager.purchase(from: Data("<html>".utf8), status: 502)) { error in
            XCTAssertEqual(error as? LicenseManager.VerifyError, .unreachable)
        }
    }
}
