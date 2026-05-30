import Foundation
@testable import HarnessMonitorCloudKit
import XCTest

final class NeedsMeCountWatchPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private var fresh: Date { now.addingTimeInterval(-30 * 60) }
    private var stale: Date { now.addingTimeInterval(-90 * 60) }

    // MARK: - countLabel

    func testCountLabelShowsDashesWhenNoTimestamp() {
        let presentation = NeedsMeCountWatchPresentation(count: 5, updatedAt: nil, state: .live, now: now)
        XCTAssertEqual(presentation.countLabel, "--")
    }

    func testCountLabelShowsCountWhenTimestampPresent() {
        let presentation = NeedsMeCountWatchPresentation(count: 5, updatedAt: fresh, state: .live, now: now)
        XCTAssertEqual(presentation.countLabel, "5")
    }

    // MARK: - countTone

    func testCountToneIsPrimaryForFreshLive() {
        let presentation = NeedsMeCountWatchPresentation(count: 3, updatedAt: fresh, state: .live, now: now)
        XCTAssertEqual(presentation.countTone, .primary)
    }

    func testCountToneIsSecondaryForStaleLive() {
        let presentation = NeedsMeCountWatchPresentation(count: 3, updatedAt: stale, state: .live, now: now)
        XCTAssertEqual(presentation.countTone, .secondary)
    }

    func testCountToneIsSecondaryForAllErrorStates() {
        for state in [NeedsMeCountState.notAuthenticated, .offline, .unknownError] {
            let presentation = NeedsMeCountWatchPresentation(
                count: 3, updatedAt: fresh, state: state, now: now
            )
            XCTAssertEqual(presentation.countTone, .secondary, "state=\(state)")
        }
    }

    // MARK: - circularSymbolName

    func testCircularSymbolNamePerState() {
        XCTAssertEqual(
            NeedsMeCountWatchPresentation(
                count: 0, updatedAt: fresh, state: .notAuthenticated, now: now
            ).circularSymbolName,
            "icloud.slash"
        )
        XCTAssertEqual(
            NeedsMeCountWatchPresentation(count: 0, updatedAt: fresh, state: .offline, now: now)
                .circularSymbolName,
            "wifi.slash"
        )
        XCTAssertEqual(
            NeedsMeCountWatchPresentation(count: 0, updatedAt: fresh, state: .unknownError, now: now)
                .circularSymbolName,
            "wifi.slash"
        )
        XCTAssertEqual(
            NeedsMeCountWatchPresentation(count: 0, updatedAt: fresh, state: .cached, now: now)
                .circularSymbolName,
            "clock.arrow.circlepath"
        )
        XCTAssertEqual(
            NeedsMeCountWatchPresentation(count: 0, updatedAt: fresh, state: .live, now: now)
                .circularSymbolName,
            "rectangle.stack.badge.person.crop"
        )
    }

    // MARK: - circularSymbolTone

    func testCircularSymbolToneIsWarningForErrorStates() {
        for state in [NeedsMeCountState.notAuthenticated, .offline, .unknownError] {
            let presentation = NeedsMeCountWatchPresentation(
                count: 0, updatedAt: fresh, state: state, now: now
            )
            XCTAssertEqual(presentation.circularSymbolTone, .warning, "state=\(state)")
        }
    }

    func testCircularSymbolToneIsStaleAccentForCachedState() {
        let presentation = NeedsMeCountWatchPresentation(count: 0, updatedAt: fresh, state: .cached, now: now)
        XCTAssertEqual(presentation.circularSymbolTone, .staleAccent)
    }

    func testCircularSymbolToneIsStaleAccentForStaleLive() {
        let presentation = NeedsMeCountWatchPresentation(count: 0, updatedAt: stale, state: .live, now: now)
        XCTAssertEqual(presentation.circularSymbolTone, .staleAccent)
    }

    func testCircularSymbolToneIsPrimaryForFreshLive() {
        let presentation = NeedsMeCountWatchPresentation(count: 0, updatedAt: fresh, state: .live, now: now)
        XCTAssertEqual(presentation.circularSymbolTone, .primary)
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
            let presentation = NeedsMeCountWatchPresentation(
                count: 1, updatedAt: fresh, state: state, now: now
            )
            XCTAssertEqual(presentation.rectangularTopLabel, expected, "state=\(state)")
        }
    }

    // MARK: - rectangularHeadline

    func testHeadlinePluralizesPerCount() {
        XCTAssertEqual(
            NeedsMeCountWatchPresentation(count: 1, updatedAt: fresh, state: .live, now: now)
                .rectangularHeadline,
            "1 review"
        )
        XCTAssertEqual(
            NeedsMeCountWatchPresentation(count: 5, updatedAt: fresh, state: .live, now: now)
                .rectangularHeadline,
            "5 reviews"
        )
    }

    func testHeadlineForNoDataNotAuthenticated() {
        let presentation = NeedsMeCountWatchPresentation(
            count: 0, updatedAt: nil, state: .notAuthenticated, now: now
        )
        XCTAssertEqual(presentation.rectangularHeadline, "Sign in")
    }

    func testHeadlineForNoDataOffline() {
        let presentation = NeedsMeCountWatchPresentation(count: 0, updatedAt: nil, state: .offline, now: now)
        XCTAssertEqual(presentation.rectangularHeadline, "No data")
    }

    func testHeadlineForNoDataLive() {
        let presentation = NeedsMeCountWatchPresentation(count: 0, updatedAt: nil, state: .live, now: now)
        XCTAssertEqual(presentation.rectangularHeadline, "-- reviews")
    }

    // MARK: - rectangularSubtitle

    func testSubtitleForNotAuthenticatedIsConstant() {
        let presentation = NeedsMeCountWatchPresentation(
            count: 0, updatedAt: fresh, state: .notAuthenticated, now: now
        )
        XCTAssertEqual(presentation.rectangularSubtitle, "Open the Mac app to refresh")
    }

    func testSubtitleForOfflineWithoutDataPromptsRetry() {
        let presentation = NeedsMeCountWatchPresentation(count: 0, updatedAt: nil, state: .offline, now: now)
        XCTAssertEqual(presentation.rectangularSubtitle, "Connect to retry")
    }

    func testSubtitleForOfflineWithStaleDataAddsStalenessHint() {
        let presentation = NeedsMeCountWatchPresentation(
            count: 0, updatedAt: stale, state: .offline, now: now
        )
        XCTAssertTrue(
            presentation.rectangularSubtitle.hasPrefix("May be outdated · "),
            "got \(presentation.rectangularSubtitle)"
        )
    }

    func testSubtitleForCachedAlwaysAddsStalenessHint() {
        let presentation = NeedsMeCountWatchPresentation(count: 0, updatedAt: fresh, state: .cached, now: now)
        XCTAssertTrue(
            presentation.rectangularSubtitle.hasPrefix("May be outdated · "),
            "got \(presentation.rectangularSubtitle)"
        )
    }

    func testSubtitleForFreshLiveOmitsStalenessHint() {
        let presentation = NeedsMeCountWatchPresentation(count: 0, updatedAt: fresh, state: .live, now: now)
        XCTAssertFalse(
            presentation.rectangularSubtitle.hasPrefix("May be outdated"),
            "got \(presentation.rectangularSubtitle)"
        )
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
        let presentation = NeedsMeCountWatchPresentation(count: 3, updatedAt: fresh, state: .cached, now: now)
        XCTAssertTrue(presentation.inlineText.hasPrefix("~"), "got \(presentation.inlineText)")
    }

    func testInlinePrefixesTildeForStaleLive() {
        let presentation = NeedsMeCountWatchPresentation(count: 3, updatedAt: stale, state: .live, now: now)
        XCTAssertTrue(presentation.inlineText.hasPrefix("~"), "got \(presentation.inlineText)")
    }

    func testInlineNoPrefixForFreshLive() {
        let presentation = NeedsMeCountWatchPresentation(count: 3, updatedAt: fresh, state: .live, now: now)
        XCTAssertFalse(presentation.inlineText.hasPrefix("~"), "got \(presentation.inlineText)")
    }

    func testInlineForNoDataPerState() {
        XCTAssertEqual(
            NeedsMeCountWatchPresentation(
                count: 0, updatedAt: nil, state: .notAuthenticated, now: now
            ).inlineText,
            "Sign in to iCloud"
        )
        XCTAssertEqual(
            NeedsMeCountWatchPresentation(count: 0, updatedAt: nil, state: .offline, now: now).inlineText,
            "-- reviews (offline)"
        )
        XCTAssertEqual(
            NeedsMeCountWatchPresentation(
                count: 0, updatedAt: nil, state: .unknownError, now: now
            ).inlineText,
            "-- reviews (offline)"
        )
        XCTAssertEqual(
            NeedsMeCountWatchPresentation(count: 0, updatedAt: nil, state: .live, now: now).inlineText,
            "-- reviews need you"
        )
    }
}
