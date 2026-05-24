import Foundation
@testable import HarnessMonitorCloudKit
import XCTest

final class NeedsMeCountWatchPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private var fresh: Date { now.addingTimeInterval(-30 * 60) }
    private var stale: Date { now.addingTimeInterval(-90 * 60) }

    // MARK: - countLabel

    func testCountLabelShowsDashesWhenNoTimestamp() {
        let p = NeedsMeCountWatchPresentation(count: 5, updatedAt: nil, state: .live, now: now)
        XCTAssertEqual(p.countLabel, "--")
    }

    func testCountLabelShowsCountWhenTimestampPresent() {
        let p = NeedsMeCountWatchPresentation(count: 5, updatedAt: fresh, state: .live, now: now)
        XCTAssertEqual(p.countLabel, "5")
    }

    // MARK: - countTone

    func testCountToneIsPrimaryForFreshLive() {
        let p = NeedsMeCountWatchPresentation(count: 3, updatedAt: fresh, state: .live, now: now)
        XCTAssertEqual(p.countTone, .primary)
    }

    func testCountToneIsSecondaryForStaleLive() {
        let p = NeedsMeCountWatchPresentation(count: 3, updatedAt: stale, state: .live, now: now)
        XCTAssertEqual(p.countTone, .secondary)
    }

    func testCountToneIsSecondaryForAllErrorStates() {
        for state in [NeedsMeCountState.notAuthenticated, .offline, .unknownError] {
            let p = NeedsMeCountWatchPresentation(count: 3, updatedAt: fresh, state: state, now: now)
            XCTAssertEqual(p.countTone, .secondary, "state=\(state)")
        }
    }

    // MARK: - circularSymbolName

    func testCircularSymbolNamePerState() {
        XCTAssertEqual(
            NeedsMeCountWatchPresentation(count: 0, updatedAt: fresh, state: .notAuthenticated, now: now).circularSymbolName,
            "icloud.slash"
        )
        XCTAssertEqual(
            NeedsMeCountWatchPresentation(count: 0, updatedAt: fresh, state: .offline, now: now).circularSymbolName,
            "wifi.slash"
        )
        XCTAssertEqual(
            NeedsMeCountWatchPresentation(count: 0, updatedAt: fresh, state: .unknownError, now: now).circularSymbolName,
            "wifi.slash"
        )
        XCTAssertEqual(
            NeedsMeCountWatchPresentation(count: 0, updatedAt: fresh, state: .cached, now: now).circularSymbolName,
            "clock.arrow.circlepath"
        )
        XCTAssertEqual(
            NeedsMeCountWatchPresentation(count: 0, updatedAt: fresh, state: .live, now: now).circularSymbolName,
            "rectangle.stack.badge.person.crop"
        )
    }

    // MARK: - circularSymbolTone

    func testCircularSymbolToneIsWarningForErrorStates() {
        for state in [NeedsMeCountState.notAuthenticated, .offline, .unknownError] {
            let p = NeedsMeCountWatchPresentation(count: 0, updatedAt: fresh, state: state, now: now)
            XCTAssertEqual(p.circularSymbolTone, .warning, "state=\(state)")
        }
    }

    func testCircularSymbolToneIsStaleAccentForCachedState() {
        let p = NeedsMeCountWatchPresentation(count: 0, updatedAt: fresh, state: .cached, now: now)
        XCTAssertEqual(p.circularSymbolTone, .staleAccent)
    }

    func testCircularSymbolToneIsStaleAccentForStaleLive() {
        let p = NeedsMeCountWatchPresentation(count: 0, updatedAt: stale, state: .live, now: now)
        XCTAssertEqual(p.circularSymbolTone, .staleAccent)
    }

    func testCircularSymbolToneIsPrimaryForFreshLive() {
        let p = NeedsMeCountWatchPresentation(count: 0, updatedAt: fresh, state: .live, now: now)
        XCTAssertEqual(p.circularSymbolTone, .primary)
    }

    // MARK: - rectangularTopLabel

    func testRectangularTopLabelPerState() {
        let labels: [NeedsMeCountState: String] = [
            .notAuthenticated: "iCloud sign-in needed",
            .offline: "Offline",
            .unknownError: "Sync failed",
            .cached: "Cached",
            .live: "Needs you",
        ]
        for (state, expected) in labels {
            let p = NeedsMeCountWatchPresentation(count: 1, updatedAt: fresh, state: state, now: now)
            XCTAssertEqual(p.rectangularTopLabel, expected, "state=\(state)")
        }
    }

    // MARK: - rectangularHeadline

    func testHeadlinePluralizesPerCount() {
        XCTAssertEqual(
            NeedsMeCountWatchPresentation(count: 1, updatedAt: fresh, state: .live, now: now).rectangularHeadline,
            "1 review"
        )
        XCTAssertEqual(
            NeedsMeCountWatchPresentation(count: 5, updatedAt: fresh, state: .live, now: now).rectangularHeadline,
            "5 reviews"
        )
    }

    func testHeadlineForNoDataNotAuthenticated() {
        let p = NeedsMeCountWatchPresentation(count: 0, updatedAt: nil, state: .notAuthenticated, now: now)
        XCTAssertEqual(p.rectangularHeadline, "Sign in")
    }

    func testHeadlineForNoDataOffline() {
        let p = NeedsMeCountWatchPresentation(count: 0, updatedAt: nil, state: .offline, now: now)
        XCTAssertEqual(p.rectangularHeadline, "No data")
    }

    func testHeadlineForNoDataLive() {
        let p = NeedsMeCountWatchPresentation(count: 0, updatedAt: nil, state: .live, now: now)
        XCTAssertEqual(p.rectangularHeadline, "-- reviews")
    }

    // MARK: - rectangularSubtitle

    func testSubtitleForNotAuthenticatedIsConstant() {
        let p = NeedsMeCountWatchPresentation(count: 0, updatedAt: fresh, state: .notAuthenticated, now: now)
        XCTAssertEqual(p.rectangularSubtitle, "Open the Mac app to refresh")
    }

    func testSubtitleForOfflineWithoutDataPromptsRetry() {
        let p = NeedsMeCountWatchPresentation(count: 0, updatedAt: nil, state: .offline, now: now)
        XCTAssertEqual(p.rectangularSubtitle, "Connect to retry")
    }

    func testSubtitleForOfflineWithStaleDataAddsStalenessHint() {
        let p = NeedsMeCountWatchPresentation(count: 0, updatedAt: stale, state: .offline, now: now)
        XCTAssertTrue(p.rectangularSubtitle.hasPrefix("May be outdated · "), "got \(p.rectangularSubtitle)")
    }

    func testSubtitleForCachedAlwaysAddsStalenessHint() {
        let p = NeedsMeCountWatchPresentation(count: 0, updatedAt: fresh, state: .cached, now: now)
        XCTAssertTrue(p.rectangularSubtitle.hasPrefix("May be outdated · "), "got \(p.rectangularSubtitle)")
    }

    func testSubtitleForFreshLiveOmitsStalenessHint() {
        let p = NeedsMeCountWatchPresentation(count: 0, updatedAt: fresh, state: .live, now: now)
        XCTAssertFalse(p.rectangularSubtitle.hasPrefix("May be outdated"), "got \(p.rectangularSubtitle)")
    }

    // MARK: - inlineText

    func testInlinePluralizesAndConjugatesVerb() {
        XCTAssertEqual(
            NeedsMeCountWatchPresentation(count: 1, updatedAt: fresh, state: .live, now: now).inlineText,
            "1 review needs you"
        )
        XCTAssertEqual(
            NeedsMeCountWatchPresentation(count: 4, updatedAt: fresh, state: .live, now: now).inlineText,
            "4 reviews need you"
        )
    }

    func testInlinePrefixesTildeForCached() {
        let p = NeedsMeCountWatchPresentation(count: 3, updatedAt: fresh, state: .cached, now: now)
        XCTAssertTrue(p.inlineText.hasPrefix("~"), "got \(p.inlineText)")
    }

    func testInlinePrefixesTildeForStaleLive() {
        let p = NeedsMeCountWatchPresentation(count: 3, updatedAt: stale, state: .live, now: now)
        XCTAssertTrue(p.inlineText.hasPrefix("~"), "got \(p.inlineText)")
    }

    func testInlineNoPrefixForFreshLive() {
        let p = NeedsMeCountWatchPresentation(count: 3, updatedAt: fresh, state: .live, now: now)
        XCTAssertFalse(p.inlineText.hasPrefix("~"), "got \(p.inlineText)")
    }

    func testInlineForNoDataPerState() {
        XCTAssertEqual(
            NeedsMeCountWatchPresentation(count: 0, updatedAt: nil, state: .notAuthenticated, now: now).inlineText,
            "Sign in to iCloud"
        )
        XCTAssertEqual(
            NeedsMeCountWatchPresentation(count: 0, updatedAt: nil, state: .offline, now: now).inlineText,
            "-- reviews (offline)"
        )
        XCTAssertEqual(
            NeedsMeCountWatchPresentation(count: 0, updatedAt: nil, state: .unknownError, now: now).inlineText,
            "-- reviews (offline)"
        )
        XCTAssertEqual(
            NeedsMeCountWatchPresentation(count: 0, updatedAt: nil, state: .live, now: now).inlineText,
            "-- reviews need you"
        )
    }
}
