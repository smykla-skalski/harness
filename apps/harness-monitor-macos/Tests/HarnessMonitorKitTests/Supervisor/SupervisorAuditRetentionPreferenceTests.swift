import SwiftData
import XCTest

@testable import HarnessMonitorKit

/// Exercises the retention preference contract on `SupervisorAuditRetention.forceCompaction`.
/// Each test installs a value (or an intentionally invalid value) into a private
/// `UserDefaults` suite, lets the scheduler compute its cutoff, and inspects which fixture
/// rows survived.
@MainActor
final class SupervisorAuditRetentionPreferenceTests: XCTestCase {
  func test_forceCompaction_honorsCustomRetentionPreference() async throws {
    let container = try makeContainer()
    let now = Date.fixed
    let custom: TimeInterval = 3 * 24 * 60 * 60  // 3 days
    let defaults = try makeDefaults()
    defaults.set(custom, forKey: SupervisorSettingsDefaults.auditRetentionSecondsKey)
    try insertEvent(
      id: "older-than-custom",
      createdAt: now.addingTimeInterval(-custom - 1),
      into: container
    )
    try insertEvent(
      id: "younger-than-custom",
      createdAt: now.addingTimeInterval(-custom + 60),
      into: container
    )

    let retention = SupervisorAuditRetention(
      container: container,
      clock: { now },
      userDefaults: defaults
    )

    XCTAssertEqual(retention.configuredRetention, custom)
    let result = try await retention.forceCompaction()

    XCTAssertEqual(result.deletedEvents, 1)
    XCTAssertEqual(try fetchEventIDs(container), ["younger-than-custom"])
  }

  func test_forceCompaction_clampsBelowOneDayToMinimum() async throws {
    let container = try makeContainer()
    let now = Date.fixed
    let defaults = try makeDefaults()
    defaults.set(
      SupervisorSettingsDefaults.minAuditRetentionSeconds - 100,
      forKey: SupervisorSettingsDefaults.auditRetentionSecondsKey
    )
    let justInsideMinimum =
      SupervisorSettingsDefaults.minAuditRetentionSeconds - 30
    let justOutsideMinimum =
      SupervisorSettingsDefaults.minAuditRetentionSeconds + 30
    try insertEvent(
      id: "inside-clamped-window",
      createdAt: now.addingTimeInterval(-justInsideMinimum),
      into: container
    )
    try insertEvent(
      id: "outside-clamped-window",
      createdAt: now.addingTimeInterval(-justOutsideMinimum),
      into: container
    )

    let retention = SupervisorAuditRetention(
      container: container,
      clock: { now },
      userDefaults: defaults
    )

    XCTAssertEqual(
      retention.configuredRetention,
      SupervisorSettingsDefaults.minAuditRetentionSeconds
    )
    let result = try await retention.forceCompaction()

    XCTAssertEqual(result.deletedEvents, 1)
    XCTAssertEqual(try fetchEventIDs(container), ["inside-clamped-window"])
  }

  func test_forceCompaction_clampsAboveNinetyDaysToMaximum() async throws {
    let container = try makeContainer()
    let now = Date.fixed
    let defaults = try makeDefaults()
    defaults.set(
      SupervisorSettingsDefaults.maxAuditRetentionSeconds + 86_400,
      forKey: SupervisorSettingsDefaults.auditRetentionSecondsKey
    )
    let justInsideMaximum =
      SupervisorSettingsDefaults.maxAuditRetentionSeconds - 30
    let justOutsideMaximum =
      SupervisorSettingsDefaults.maxAuditRetentionSeconds + 30
    try insertEvent(
      id: "inside-clamped-window",
      createdAt: now.addingTimeInterval(-justInsideMaximum),
      into: container
    )
    try insertEvent(
      id: "outside-clamped-window",
      createdAt: now.addingTimeInterval(-justOutsideMaximum),
      into: container
    )

    let retention = SupervisorAuditRetention(
      container: container,
      clock: { now },
      userDefaults: defaults
    )

    XCTAssertEqual(
      retention.configuredRetention,
      SupervisorSettingsDefaults.maxAuditRetentionSeconds
    )
    let result = try await retention.forceCompaction()

    XCTAssertEqual(result.deletedEvents, 1)
    XCTAssertEqual(try fetchEventIDs(container), ["inside-clamped-window"])
  }

  func test_forceCompaction_fallsBackToFourteenDaysWhenPreferenceMissing() async throws {
    let container = try makeContainer()
    let now = Date.fixed
    let defaults = try makeDefaults()
    // Preference intentionally not set.
    let fallback = SupervisorSettingsDefaults.defaultAuditRetentionSeconds
    try insertEvent(
      id: "inside-default-window",
      createdAt: now.addingTimeInterval(-fallback + 60),
      into: container
    )
    try insertEvent(
      id: "outside-default-window",
      createdAt: now.addingTimeInterval(-fallback - 60),
      into: container
    )

    let retention = SupervisorAuditRetention(
      container: container,
      clock: { now },
      userDefaults: defaults
    )

    XCTAssertEqual(retention.configuredRetention, fallback)
    let result = try await retention.forceCompaction()

    XCTAssertEqual(result.deletedEvents, 1)
    XCTAssertEqual(try fetchEventIDs(container), ["inside-default-window"])
  }

  func test_forceCompaction_fallsBackToFourteenDaysWhenPreferenceNonNumeric() async throws {
    let container = try makeContainer()
    let now = Date.fixed
    let defaults = try makeDefaults()
    defaults.set("not-a-number", forKey: SupervisorSettingsDefaults.auditRetentionSecondsKey)
    let fallback = SupervisorSettingsDefaults.defaultAuditRetentionSeconds
    try insertEvent(
      id: "inside-default-window",
      createdAt: now.addingTimeInterval(-fallback + 60),
      into: container
    )
    try insertEvent(
      id: "outside-default-window",
      createdAt: now.addingTimeInterval(-fallback - 60),
      into: container
    )

    let retention = SupervisorAuditRetention(
      container: container,
      clock: { now },
      userDefaults: defaults
    )

    XCTAssertEqual(retention.configuredRetention, fallback)
    let result = try await retention.forceCompaction()

    XCTAssertEqual(result.deletedEvents, 1)
    XCTAssertEqual(try fetchEventIDs(container), ["inside-default-window"])
  }

  private func makeContainer() throws -> ModelContainer {
    try ModelContainer(
      for: SupervisorEvent.self,
      Decision.self,
      PolicyConfigRow.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
  }

  private func makeDefaults() throws -> UserDefaults {
    let suiteName = "io.harnessmonitor.tests.audit-retention.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }

  private func insertEvent(id: String, createdAt: Date, into container: ModelContainer) throws {
    let context = container.mainContext
    let event = SupervisorEvent(
      id: id,
      tickID: "tick-\(id)",
      kind: "ruleEvaluated",
      ruleID: "rule-\(id)",
      severity: .info,
      payloadJSON: "{}"
    )
    event.createdAt = createdAt
    context.insert(event)
    try context.save()
  }

  private func fetchEventIDs(_ container: ModelContainer) throws -> [String] {
    let context = container.mainContext
    return try context.fetch(FetchDescriptor<SupervisorEvent>()).map(\.id).sorted()
  }
}
