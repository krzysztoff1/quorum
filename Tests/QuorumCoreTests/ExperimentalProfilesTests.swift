import XCTest
@testable import QuorumCore

/// The experimental-profile switch: Codex, Budget and Full BYOK stay in the code but are hidden unless
/// the flag is on, and a persisted hidden selection falls back to Subscription while it is off.
final class ExperimentalProfilesTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "ExperimentalProfilesTests")!
        defaults.removePersistentDomain(forName: "ExperimentalProfilesTests")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "ExperimentalProfilesTests")
        super.tearDown()
    }

    func testFlagDefaultsOff() {
        XCTAssertFalse(ExperimentalProfiles.isEnabled(in: defaults))
    }

    func testFlagReadsItsDefaultsKey() {
        defaults.set(true, forKey: ExperimentalProfiles.defaultsKey)
        XCTAssertTrue(ExperimentalProfiles.isEnabled(in: defaults))
    }

    func testFlagOffOffersOnlySubscription() {
        XCTAssertEqual(ExperimentalProfiles.selectable(experimentsEnabled: false), [.subscription])
    }

    func testFlagOnOffersSubscriptionThenExperimentalProfilesInPickerOrder() {
        XCTAssertEqual(ExperimentalProfiles.selectable(experimentsEnabled: true),
                       [.subscription, .codex, .budget, .fullBYOK])
    }

    func testFlagOffFallsBackHiddenSelectionsToSubscription() {
        for hidden in [RunProfile.codex, .budget, .fullBYOK] {
            XCTAssertEqual(ExperimentalProfiles.effective(hidden, experimentsEnabled: false), .subscription)
        }
    }

    func testFlagOffKeepsSubscriptionAndBenchmark() {
        XCTAssertEqual(ExperimentalProfiles.effective(.subscription, experimentsEnabled: false), .subscription)
        XCTAssertEqual(ExperimentalProfiles.effective(.benchmark, experimentsEnabled: false), .benchmark)
    }

    func testFlagOnKeepsEveryProfileSelected() {
        for profile in RunProfile.allCases {
            XCTAssertEqual(ExperimentalProfiles.effective(profile, experimentsEnabled: true), profile)
        }
    }
}
