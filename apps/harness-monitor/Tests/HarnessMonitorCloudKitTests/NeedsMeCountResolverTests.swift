import Foundation
@testable import HarnessMonitorCloudKit
import XCTest

final class NeedsMeCountResolverTests: XCTestCase {
    private let timestamp = Date(timeIntervalSince1970: 1_700_000_000)

    func testPrimarySnapshotProducesLiveResolution() {
        let primary = NeedsMeSnapshot(count: 4, updatedAt: timestamp, revision: 2)
        let resolution = NeedsMeCountResolver.resolve(primary: primary, fallback: nil, error: nil)
        XCTAssertEqual(resolution.count, 4)
        XCTAssertEqual(resolution.updatedAt, timestamp)
        XCTAssertEqual(resolution.state, .live)
    }

    func testNoPrimaryAndNoErrorWithFallbackProducesCachedResolution() {
        let fallback = NeedsMeSnapshot(count: 7, updatedAt: timestamp, revision: 3)
        let resolution = NeedsMeCountResolver.resolve(
            primary: nil, fallback: fallback, error: nil
        )
        XCTAssertEqual(resolution.count, 7)
        XCTAssertEqual(resolution.updatedAt, timestamp)
        XCTAssertEqual(resolution.state, .cached)
    }

    func testNoPrimaryNoFallbackNoErrorProducesLiveZero() {
        let resolution = NeedsMeCountResolver.resolve(primary: nil, fallback: nil, error: nil)
        XCTAssertEqual(resolution.count, 0)
        XCTAssertNil(resolution.updatedAt)
        XCTAssertEqual(resolution.state, .live)
    }

    func testNotAuthenticatedWithoutFallbackProducesNotAuthenticated() {
        let resolution = NeedsMeCountResolver.resolve(
            primary: nil, fallback: nil, error: .notAuthenticated
        )
        XCTAssertEqual(resolution.count, 0)
        XCTAssertNil(resolution.updatedAt)
        XCTAssertEqual(resolution.state, .notAuthenticated)
    }

    func testNotAuthenticatedWithFallbackKeepsCountAndStateRemains() {
        let fallback = NeedsMeSnapshot(count: 9, updatedAt: timestamp, revision: 4)
        let resolution = NeedsMeCountResolver.resolve(
            primary: nil, fallback: fallback, error: .notAuthenticated
        )
        XCTAssertEqual(resolution.count, 9)
        XCTAssertEqual(resolution.updatedAt, timestamp)
        XCTAssertEqual(
            resolution.state,
            .notAuthenticated,
            "Stale value preserved but state still signals the sign-in problem"
        )
    }

    func testNetworkUnavailableWithoutFallbackProducesOffline() {
        let resolution = NeedsMeCountResolver.resolve(
            primary: nil, fallback: nil, error: .networkUnavailable
        )
        XCTAssertEqual(resolution.state, .offline)
        XCTAssertEqual(resolution.count, 0)
        XCTAssertNil(resolution.updatedAt)
    }

    func testNetworkUnavailableWithFallbackProducesCached() {
        let fallback = NeedsMeSnapshot(count: 11, updatedAt: timestamp, revision: 5)
        let resolution = NeedsMeCountResolver.resolve(
            primary: nil, fallback: fallback, error: .networkUnavailable
        )
        XCTAssertEqual(resolution.state, .cached)
        XCTAssertEqual(resolution.count, 11)
        XCTAssertEqual(resolution.updatedAt, timestamp)
    }

    func testQuotaExceededAndUnderlyingMapToUnknownError() {
        let q = NeedsMeCountResolver.resolve(primary: nil, fallback: nil, error: .quotaExceeded)
        XCTAssertEqual(q.state, .unknownError)
        let u = NeedsMeCountResolver.resolve(
            primary: nil, fallback: nil, error: .underlying("boom")
        )
        XCTAssertEqual(u.state, .unknownError)
    }

    func testUnknownErrorWithFallbackKeepsCount() {
        let fallback = NeedsMeSnapshot(count: 2, updatedAt: timestamp, revision: 1)
        let resolution = NeedsMeCountResolver.resolve(
            primary: nil, fallback: fallback, error: .underlying("xxx")
        )
        XCTAssertEqual(resolution.state, .unknownError)
        XCTAssertEqual(resolution.count, 2)
        XCTAssertEqual(resolution.updatedAt, timestamp)
    }

    // MARK: - Staleness

    func testStalenessReturnsFalseForNilDate() {
        XCTAssertFalse(NeedsMeStalenessClassifier.isStale(updatedAt: nil))
    }

    func testStalenessUnderThresholdIsFresh() {
        let now = Date()
        let recent = now.addingTimeInterval(-30 * 60)  // 30 min old
        XCTAssertFalse(NeedsMeStalenessClassifier.isStale(updatedAt: recent, now: now))
    }

    func testStalenessOverThresholdIsStale() {
        let now = Date()
        let old = now.addingTimeInterval(-90 * 60)  // 90 min old
        XCTAssertTrue(NeedsMeStalenessClassifier.isStale(updatedAt: old, now: now))
    }

    func testStalenessExactlyAtThresholdIsNotStale() {
        let now = Date()
        let edge = now.addingTimeInterval(-NeedsMeStalenessClassifier.defaultThreshold)
        XCTAssertFalse(
            NeedsMeStalenessClassifier.isStale(updatedAt: edge, now: now),
            "Edge: > threshold is stale; == is not"
        )
    }

    func testStalenessUsesProvidedThreshold() {
        let now = Date()
        let twoMinutes = now.addingTimeInterval(-120)
        XCTAssertTrue(
            NeedsMeStalenessClassifier.isStale(updatedAt: twoMinutes, now: now, threshold: 60)
        )
        XCTAssertFalse(
            NeedsMeStalenessClassifier.isStale(updatedAt: twoMinutes, now: now, threshold: 300)
        )
    }
}
