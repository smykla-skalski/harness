import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Reviews UserDefaults migration")
struct HarnessMonitorReviewsUserDefaultsMigrationTests {
  @Test("Copies every old prefix family onto its new prefix and clears the source")
  func happyPathRenamesAllSupportedPrefixes() throws {
    let defaults = try makeEmptyDefaults()
    defaults.set(
      "PR list",
      forKey: "dashboard.reviews.lastSelectedRoute"
    )
    defaults.set(7, forKey: "reviews.summaryRefreshSeconds")
    defaults.set(true, forKey: "settingsReviewsShowDescriptions")

    HarnessMonitorReviewsUserDefaultsMigration.runIfNeeded(defaults: defaults)

    #expect(
      defaults.string(forKey: "dashboard.reviews.lastSelectedRoute") == "PR list"
    )
    #expect(defaults.integer(forKey: "reviews.summaryRefreshSeconds") == 7)
    #expect(defaults.bool(forKey: "settingsReviewsShowDescriptions"))

    #expect(defaults.object(forKey: "dashboard.reviews.lastSelectedRoute") == nil)
    #expect(defaults.object(forKey: "reviews.summaryRefreshSeconds") == nil)
    #expect(defaults.object(forKey: "settingsReviewsShowDescriptions") == nil)

    #expect(
      defaults.bool(
        forKey: HarnessMonitorReviewsUserDefaultsMigration.completedFlagKey
      )
    )
  }

  @Test("Second invocation no-ops when the completion flag is already set")
  func secondRunDoesNotDoubleWrite() throws {
    let defaults = try makeEmptyDefaults()
    defaults.set("first", forKey: "reviews.original")

    HarnessMonitorReviewsUserDefaultsMigration.runIfNeeded(defaults: defaults)
    #expect(defaults.string(forKey: "reviews.original") == "first")
    #expect(defaults.object(forKey: "reviews.original") == nil)

    // Seed an old-prefix key after the first run; a properly gated migration
    // must leave it alone because the completion flag is already set.
    defaults.set("second", forKey: "reviews.added-after-first-run")
    HarnessMonitorReviewsUserDefaultsMigration.runIfNeeded(defaults: defaults)

    #expect(defaults.string(forKey: "reviews.added-after-first-run") == "second")
    #expect(defaults.object(forKey: "reviews.added-after-first-run") == nil)
  }

  @Test("Empty defaults still records the completion flag")
  func emptyDefaultsSetsCompletionFlag() throws {
    let defaults = try makeEmptyDefaults()

    HarnessMonitorReviewsUserDefaultsMigration.runIfNeeded(defaults: defaults)

    #expect(
      defaults.bool(
        forKey: HarnessMonitorReviewsUserDefaultsMigration.completedFlagKey
      )
    )
  }

  private func makeEmptyDefaults() throws -> UserDefaults {
    let suite = "harness.reviews-migration.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
    return defaults
  }
}
