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
    private func query(_ origin: BuyLink.Origin = .settings, tier: Tier = .free,
                       grabs: Int = 0, translations: Int = 0, days: Int = 0) -> [String: String] {
        let url = BuyLink.url(AppConstants.textCheckoutURL, from: origin, tier: tier, grabs: grabs,
                              translations: translations, daysSinceFirstLaunch: days)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    func testCampaignSaysWhereTheBuyButtonWasPressed() {
        XCTAssertEqual(query(.settings)["utm_campaign"], "settings")
        XCTAssertEqual(query(.window(nil))["utm_campaign"], "menu")
        XCTAssertEqual(query(.window(.grabs(100)))["utm_campaign"], "limit-grabs")
        XCTAssertEqual(query(.window(.translations(30, free: false)))["utm_campaign"], "limit-translations")
        XCTAssertEqual(query(.window(.live))["utm_campaign"], "limit-live")
    }

    func testCarriesUsageAndTier() {
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
        let url = BuyLink.url(AppConstants.textCheckoutURL, from: .settings, tier: .free, grabs: 0,
                              translations: 0, daysSinceFirstLaunch: 40)
        XCTAssertTrue(url.absoluteString.contains("utm_content=free-d31%2B"), url.absoluteString)
    }
}

/// Polar and Gumroad stood in for by a table of keys.
private actor FakeStores {
    typealias Store = LicenseManager.Store
    var keys: [Store: [String: LicenseManager.Purchase]] = [:]
    var refused: [Store: [String: String]] = [:]
    var reachable = true

    func set(_ store: Store, _ key: String, _ product: LicenseManager.Product) {
        keys[store, default: [:]][key] = LicenseManager.Purchase(product: product, email: "buyer@example.com")
    }

    func forget(_ store: Store, _ key: String) { keys[store]?[key] = nil }
    func refuse(_ store: Store, _ key: String, _ reason: String) { refused[store, default: [:]][key] = reason }
    func setReachable(_ value: Bool) { reachable = value }

    func verify(_ store: Store, _ key: String) throws(LicenseManager.VerifyError) -> LicenseManager.Purchase {
        guard reachable else { throw .unreachable }
        if let reason = refused[store]?[key] { throw .rejected(reason) }
        guard let purchase = keys[store]?[key] else { throw .unknown }
        return purchase
    }
}

@MainActor
final class LicenseManagerTests: XCTestCase {
    private var directory: URL!
    private let stores = FakeStores()
    private var now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func manager() -> LicenseManager {
        let stores = stores
        return LicenseManager(directory: directory,
                              verify: { store, key throws(LicenseManager.VerifyError) in
                                  try await stores.verify(store, key)
                              },
                              now: { [unowned self] in now })
    }

    func testProductBoughtDecidesTheTierAndIsKeptAcrossLaunches() async {
        await stores.set(.polar, "TEXT-KEY", .text)
        await stores.set(.polar, "TRANSLATE-KEY", .translate)
        let license = manager()
        XCTAssertEqual(license.tier, .free)

        await license.activate("  TEXT-KEY\n")
        XCTAssertEqual(license.tier, .text)
        XCTAssertNil(license.error)

        await license.activate("TRANSLATE-KEY")
        XCTAssertEqual(manager().tier, .translate)
    }

    func testGumroadKeyBoughtBeforePolarStillActivatesAndRefreshesWithGumroad() async {
        await stores.set(.gumroad, "OLD-KEY", .translate)
        let license = manager()
        await license.activate("OLD-KEY")
        XCTAssertEqual(license.tier, .translate)
        XCTAssertEqual(license.stored?.keyStore, .gumroad)

        await stores.forget(.gumroad, "OLD-KEY")
        await license.refresh()
        XCTAssertEqual(license.tier, .free)
    }

    func testPolarRefusalIsShownWithoutAskingGumroad() async {
        await stores.set(.gumroad, "VIADUCT-KEY", .translate)
        await stores.refuse(.polar, "VIADUCT-KEY", "This key is for a different app.")
        let license = manager()
        await license.activate("VIADUCT-KEY")
        XCTAssertEqual(license.tier, .free)
        XCTAssertEqual(license.error, "This key is for a different app.")
    }

    func testUpgradeKeyNeedsATextKeyFirst() async {
        await stores.set(.polar, "TEXT-KEY", .text)
        await stores.set(.polar, "UPGRADE-KEY", .upgrade)
        let license = manager()

        await license.activate("UPGRADE-KEY")
        XCTAssertEqual(license.tier, .free)
        XCTAssertNotNil(license.error)

        await license.activate("TEXT-KEY")
        await license.activate("UPGRADE-KEY")
        XCTAssertEqual(license.tier, .translate)
        XCTAssertEqual(manager().tier, .translate)
    }

    func testPolarUpgradeAppliesToAGumroadTextKey() async {
        await stores.set(.gumroad, "OLD-TEXT-KEY", .text)
        await stores.set(.polar, "UPGRADE-KEY", .upgrade)
        let license = manager()
        await license.activate("OLD-TEXT-KEY")
        await license.activate("UPGRADE-KEY")
        XCTAssertEqual(license.tier, .translate)

        await license.refresh()
        XCTAssertEqual(manager().tier, .translate)
        XCTAssertEqual(license.stored?.keyStore, .gumroad)
        XCTAssertEqual(license.stored?.upgradeStore, .polar)
    }

    func testUnknownKeyLeavesTheLicenseAsItWas() async {
        await stores.set(.polar, "TEXT-KEY", .text)
        let license = manager()
        await license.activate("TEXT-KEY")
        await license.activate("TYPO-KEY")
        XCTAssertEqual(license.tier, .text)
        XCTAssertNotNil(license.error)
    }

    func testOfflineLaunchKeepsTheTierUntilTheGraceRunsOut() async {
        await stores.set(.polar, "TRANSLATE-KEY", .translate)
        await manager().activate("TRANSLATE-KEY")
        await stores.setReachable(false)

        now += LicenseManager.offlineGrace - 60
        let early = manager()
        await early.refresh()
        XCTAssertEqual(early.tier, .translate)

        now += 120
        let late = manager()
        await late.refresh()
        XCTAssertEqual(late.tier, .free)
    }

    func testKeyTheStoreNoLongerAcceptsIsDroppedAtLaunch() async {
        await stores.set(.polar, "TEXT-KEY", .text)
        await stores.set(.polar, "UPGRADE-KEY", .upgrade)
        let license = manager()
        await license.activate("TEXT-KEY")
        await license.activate("UPGRADE-KEY")

        await stores.forget(.polar, "UPGRADE-KEY")
        await license.refresh()
        XCTAssertEqual(license.tier, .text)

        await stores.forget(.polar, "TEXT-KEY")
        await license.refresh()
        XCTAssertEqual(manager().tier, .free)
    }

    func testLicenseSavedBeforePolarIsReadAsGumroad() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let saved = #"{"key":"OLD-KEY","keyTier":"text","upgradeKey":"OLD-UPGRADE","verified":800000000}"#
        try Data(saved.utf8).write(to: directory.appendingPathComponent("license.json"))
        await stores.set(.gumroad, "OLD-KEY", .text)
        await stores.set(.gumroad, "OLD-UPGRADE", .upgrade)

        let license = manager()
        XCTAssertEqual(license.tier, .translate)
        await license.refresh()
        XCTAssertEqual(license.tier, .translate)
        XCTAssertEqual(license.stored?.keyStore, .gumroad)
        XCTAssertEqual(license.stored?.upgradeStore, .gumroad)
    }
}

final class StoreAnswerTests: XCTestCase {
    private func polar(_ json: String, status: Int) -> Result<LicenseManager.Purchase, LicenseManager.VerifyError> {
        Result { () throws(LicenseManager.VerifyError) in
            try LicenseManager.polarPurchase(from: Data(json.utf8), status: status)
        }
    }

    func testPolarBenefitDecidesTheProduct() throws {
        let (benefit, product) = try XCTUnwrap(LicenseManager.polarBenefits.first { $0.value == .upgrade })
        let body = #"{"benefit_id":"\#(benefit)","status":"granted","customer":{"email":"buyer@example.com"}}"#
        XCTAssertEqual(polar(body, status: 200), .success(.init(product: product, email: "buyer@example.com")))
    }

    func testPolarKeyForAnotherAppIsRejected() {
        let body = #"{"benefit_id":"82852254-3f6b-4395-a527-e9d930b87234","status":"granted"}"#
        XCTAssertEqual(polar(body, status: 200), .failure(.rejected("This key is for a different app.")))
    }

    func testOnlyPolarsStockNotFoundMeansUnknown() {
        XCTAssertEqual(polar(#"{"error":"ResourceNotFound","detail":"Not found"}"#, status: 404), .failure(.unknown))
        XCTAssertEqual(polar(#"{"error":"ResourceNotFound","detail":"License key is no longer active."}"#, status: 404),
                       .failure(.rejected("License key is no longer active.")))
        XCTAssertEqual(polar("<html>Not Found</html>", status: 404), .failure(.unreachable))
        XCTAssertEqual(polar(#"{"detail":[{"msg":"bad"}]}"#, status: 422), .failure(.unreachable))
    }

    func testRefundedGumroadPurchaseIsRejected() {
        let body = Data(#"{"success":true,"purchase":{"variants":"(Translate)","refunded":true}}"#.utf8)
        XCTAssertThrowsError(try LicenseManager.gumroadPurchase(from: body, status: 200, upgrade: false)) { error in
            guard case .rejected = error as? LicenseManager.VerifyError else {
                return XCTFail("expected a rejection, got \(error)")
            }
        }
    }

    func testGumroadServerErrorIsNotARejection() {
        XCTAssertThrowsError(try LicenseManager.gumroadPurchase(from: Data("<html>".utf8), status: 502, upgrade: false)) {
            XCTAssertEqual($0 as? LicenseManager.VerifyError, .unreachable)
        }
    }
}
