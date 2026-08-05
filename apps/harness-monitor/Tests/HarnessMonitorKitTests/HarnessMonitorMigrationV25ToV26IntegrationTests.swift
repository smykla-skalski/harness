import Foundation
import SwiftData
import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("V25 -> V26 Session window persistence retirement")
struct HarnessMonitorMigrationV25ToV26IntegrationTests {
  @Test("V25 migration drops Session window state and preserves unrelated data")
  func migrationRetiresOnlySessionWindowState() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    try seedV25Fixture(at: fixture.storeURL)

    let firstSnapshot = try migratedSnapshot(using: fixture.environment)
    let secondSnapshot = try migratedSnapshot(using: fixture.environment)

    #expect(firstSnapshot == .expected)
    #expect(secondSnapshot == firstSnapshot)
    #expect(HarnessMonitorCurrentSchema.versionIdentifier == Schema.Version(26, 0, 0))
    #expect(
      !HarnessMonitorCurrentSchema.models.contains {
        String(describing: $0) == "CachedSessionWindowState"
      }
    )
  }

  @Test("V26 changes only the Session window restoration model set")
  func currentModelSetRetiresOnlySessionWindowState() {
    let priorModels = Set(HarnessMonitorSchemaV25.models.map { String(describing: $0) })
    let currentModels = Set(HarnessMonitorSchemaV26.models.map { String(describing: $0) })

    #expect(
      currentModels == priorModels.subtracting(["CachedSessionWindowState"])
    )
  }

  @Test("Every registered historical schema opens through the current migration plan")
  func everyHistoricalSchemaOpens() throws {
    for schemaType in HarnessMonitorMigrationPlan.schemas.dropLast() {
      let fixture = try makeFixture()
      defer { try? FileManager.default.removeItem(at: fixture.root) }

      do {
        try createEmptyStore(schemaType: schemaType, at: fixture.storeURL)
        _ = try HarnessMonitorModelContainer.live(using: fixture.environment)
      } catch {
        Issue.record(
          "Schema \(schemaType.versionString) failed to migrate: \(error)"
        )
      }
    }
  }
}

@MainActor
private func createEmptyStore(
  schemaType: any VersionedSchema.Type,
  at storeURL: URL
) throws {
  try autoreleasepool {
    let schema = Schema(versionedSchema: schemaType)
    let configuration = ModelConfiguration(
      "HarnessMonitorStore",
      schema: schema,
      url: storeURL
    )
    let container = try ModelContainer(for: schema, configurations: [configuration])
    try container.mainContext.save()
  }
}

private struct MigrationFixture {
  let root: URL
  let environment: HarnessMonitorEnvironment
  let storeURL: URL
}

private struct MigratedSnapshot: Equatable {
  let transcriptEntryIDs: [String]
  let decisionIDs: [String]
  let filterProjectIDs: [String]
  let reviewHashes: [String]

  static let expected = Self(
    transcriptEntryIDs: ["entry-v25"],
    decisionIDs: ["decision-v25"],
    filterProjectIDs: ["project-v25"],
    reviewHashes: ["reviews-v25"]
  )
}

@MainActor
private func makeFixture() throws -> MigrationFixture {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  let environment = HarnessMonitorEnvironment(
    values: ["XDG_DATA_HOME": root.path],
    homeDirectory: root
  )
  let harnessRoot = HarnessMonitorPaths.harnessRoot(using: environment)
  try FileManager.default.createDirectory(
    at: harnessRoot,
    withIntermediateDirectories: true
  )
  return MigrationFixture(
    root: root,
    environment: environment,
    storeURL: harnessRoot.appendingPathComponent("harness-cache.store")
  )
}

@MainActor
private func seedV25Fixture(at storeURL: URL) throws {
  let schema = Schema(versionedSchema: HarnessMonitorSchemaV25.self)
  let configuration = ModelConfiguration(
    "HarnessMonitorStore",
    schema: schema,
    url: storeURL
  )
  let container = try ModelContainer(for: schema, configurations: [configuration])
  let context = container.mainContext

  context.insert(
    HarnessMonitorSchemaV10.CachedSessionWindowState(
      sessionId: "session-window-v25",
      wasOpenAtQuit: true,
      tabGroupOrdinal: 0,
      tabPosition: 0,
      wasForegroundTab: true
    )
  )
  context.insert(
    HarnessMonitorSchemaV12.CachedSessionTranscriptEntry(
      sessionId: "session-v25",
      entryId: "entry-v25",
      recordedAt: "2026-08-05T10:00:00Z",
      kind: "assistant_message",
      agentId: "agent-v25",
      taskId: nil,
      summary: "Preserved agent history",
      payloadData: Data("{}".utf8),
      sourceRaw: "direct"
    )
  )
  context.insert(
    Decision(
      id: "decision-v25",
      severity: .warn,
      ruleID: "migration-fixture",
      sessionID: "session-v25",
      agentID: "agent-v25",
      taskID: nil,
      summary: "Preserved decision",
      contextJSON: "{}",
      suggestedActionsJSON: "[]"
    )
  )
  context.insert(
    ProjectFilterPreference(
      projectId: "project-v25",
      sessionFilterRaw: "active",
      sessionFocusFilterRaw: "all"
    )
  )
  context.insert(
    CachedReviewsSnapshot(
      preferencesHash: "reviews-v25",
      responseData: Data("cached remote data".utf8)
    )
  )

  try context.save()
}

@MainActor
private func migratedSnapshot(
  using environment: HarnessMonitorEnvironment
) throws -> MigratedSnapshot {
  let container = try HarnessMonitorModelContainer.live(using: environment)
  let context = container.mainContext
  return MigratedSnapshot(
    transcriptEntryIDs: try context.fetch(
      FetchDescriptor<CachedSessionTranscriptEntry>()
    ).map(\.entryId),
    decisionIDs: try context.fetch(FetchDescriptor<Decision>()).map(\.id),
    filterProjectIDs: try context.fetch(
      FetchDescriptor<ProjectFilterPreference>()
    ).map(\.projectId),
    reviewHashes: try context.fetch(FetchDescriptor<CachedReviewsSnapshot>()).map(
      \.preferencesHash
    )
  )
}
