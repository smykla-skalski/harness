import Foundation
import Testing

@testable import HarnessMonitorKit

/// Exercises the Reviews UserDefaults migration through two separate
/// `UserDefaults` instances backed by the same suite name, simulating the
/// "write old keys in build N, run migration on first launch of build N+1"
/// app-launch flow that the in-process unit test cannot model.
@Suite("Reviews UserDefaults migration cross-instance round-trip")
struct HarnessMonitorReviewsUserDefaultsMigrationIntegrationTests {
  @Test("Old keys written by one defaults instance migrate when another opens the suite")
  func crossInstanceRoundTripPreservesEveryPrefixFamily() throws {
    let suite = try makeSuiteName()
    defer { UserDefaults().removePersistentDomain(forName: suite) }

    let writer = try #require(UserDefaults(suiteName: suite))
    writer.set("PR list", forKey: "dashboard.dependencies.lastSelectedRoute")
    writer.set(42, forKey: "dependencies.summaryRefreshSeconds")
    writer.set(true, forKey: "settingsDependenciesShowDescriptions")
    writer.synchronize()

    let migrator = try #require(UserDefaults(suiteName: suite))
    HarnessMonitorReviewsUserDefaultsMigration.runIfNeeded(defaults: migrator)
    migrator.synchronize()

    let reader = try #require(UserDefaults(suiteName: suite))

    #expect(
      reader.string(forKey: "dashboard.reviews.lastSelectedRoute") == "PR list"
    )
    #expect(reader.integer(forKey: "reviews.summaryRefreshSeconds") == 42)
    #expect(reader.bool(forKey: "settingsReviewsShowDescriptions"))

    #expect(reader.object(forKey: "dashboard.dependencies.lastSelectedRoute") == nil)
    #expect(reader.object(forKey: "dependencies.summaryRefreshSeconds") == nil)
    #expect(reader.object(forKey: "settingsDependenciesShowDescriptions") == nil)

    #expect(
      reader.bool(
        forKey: HarnessMonitorReviewsUserDefaultsMigration.completedFlagKey
      )
    )
  }

  @Test("A second simulated launch leaves the suite untouched")
  func subsequentLaunchDoesNotReMigrate() throws {
    let suite = try makeSuiteName()
    defer { UserDefaults().removePersistentDomain(forName: suite) }

    let firstLaunchDefaults = try #require(UserDefaults(suiteName: suite))
    firstLaunchDefaults.set("warm", forKey: "dependencies.alreadyMigrated")
    HarnessMonitorReviewsUserDefaultsMigration.runIfNeeded(
      defaults: firstLaunchDefaults
    )
    firstLaunchDefaults.synchronize()

    let secondLaunchDefaults = try #require(UserDefaults(suiteName: suite))
    secondLaunchDefaults.set("ignored", forKey: "dependencies.addedAfterFlag")
    HarnessMonitorReviewsUserDefaultsMigration.runIfNeeded(
      defaults: secondLaunchDefaults
    )
    secondLaunchDefaults.synchronize()

    let reader = try #require(UserDefaults(suiteName: suite))

    #expect(reader.string(forKey: "reviews.alreadyMigrated") == "warm")
    #expect(reader.string(forKey: "dependencies.addedAfterFlag") == "ignored")
    #expect(reader.object(forKey: "reviews.addedAfterFlag") == nil)
  }

  private func makeSuiteName() throws -> String {
    "harness.reviews-migration.integration.\(UUID().uuidString)"
  }
}
