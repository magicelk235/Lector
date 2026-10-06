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
