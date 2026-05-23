import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard reviews resolved preferences cache")
struct DashboardReviewsResolvedPreferencesCacheTests {
  @Test("repeated identical stored values skip the JSON decode")
  func repeatedIdenticalStoredValuesSkipDecode() {
    let stored = #"{"authorsText":"renovate[bot]","refreshIntervalSeconds":300}"#
    let hash = stored.hashValue

    let firstDecision = dashboardReviewsResolvedPreferencesCacheDecision(
      lastHash: nil,
      nextHash: hash
    )
    #expect(firstDecision == .decode)

    let secondDecision = dashboardReviewsResolvedPreferencesCacheDecision(
      lastHash: hash,
      nextHash: hash
    )
    #expect(
      secondDecision == .skipDecode,
      "second sync of an identical stored payload must skip the JSON decode"
    )
  }

  @Test("changing the stored value invalidates the cache")
  func changingStoredValueInvalidatesCache() {
    let first = #"{"authorsText":"renovate[bot]"}"#
    let second = #"{"authorsText":"dependabot[bot]"}"#

    let decision = dashboardReviewsResolvedPreferencesCacheDecision(
      lastHash: first.hashValue,
      nextHash: second.hashValue
    )
    #expect(decision == .decode)
  }

  @Test("route source wires the hash-gated cache for stored preferences")
  func routeSourceWiresTheHashGatedCacheForStoredPreferences() throws {
    let routeViewSource = try routeSource(named: "DashboardReviewsRouteView.swift")
    let stateSyncSource = try routeSource(named: "DashboardReviewsRouteView+StateSync.swift")

    #expect(routeViewSource.contains("@State private var lastStoredPreferencesHash: Int?"))
    #expect(
      routeViewSource.contains("var routeLastStoredPreferencesHash: Int?"),
      "the hash field must be exposed via a nonmutating accessor so +StateSync can update it"
    )
    #expect(
      stateSyncSource.contains("dashboardReviewsResolvedPreferencesCacheDecision("),
      "+StateSync must consult the cache decision helper before decoding"
    )
    #expect(
      stateSyncSource.contains("if decision == .skipDecode { return }"),
      "the gate must skip the decode when the cache decision allows it"
    )
  }

  @Test("identical decoded preferences hash to the same cache key")
  func identicalStoredStringsResolveEqualPreferences() {
    let stored = #"{"authorsText":"renovate[bot]","cacheMaxAgeSeconds":600}"#
    let first = DashboardReviewsResolvedPreferences(storedValue: stored)
    let second = DashboardReviewsResolvedPreferences(storedValue: stored)
    #expect(first == second)
    #expect(first.cacheHash == second.cacheHash)
  }

  private func routeSource(named fileName: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceURL =
      repoRoot
      .appendingPathComponent(
        "apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable/Views/Dashboard"
      )
      .appendingPathComponent(fileName)
    return try String(contentsOf: sourceURL, encoding: .utf8)
  }
}
