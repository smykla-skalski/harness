import Foundation
import SwiftData

public enum HarnessMonitorModelContainer {
  public static func live(
    using environment: HarnessMonitorEnvironment = .current
  ) throws -> ModelContainer {
    let schema = Schema(versionedSchema: HarnessMonitorSchemaV1.self)
    let root = HarnessMonitorPaths.harnessRoot(using: environment)
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true,
      attributes: nil
    )
    let url = root.appendingPathComponent("harness-cache.store")
    let config = ModelConfiguration("HarnessMonitorStore", schema: schema, url: url)

    return try ModelContainer(
      for: schema,
      migrationPlan: HarnessMonitorMigrationPlan.self,
      configurations: [config]
    )
  }

  public static func preview() throws -> ModelContainer {
    let schema = Schema(versionedSchema: HarnessMonitorSchemaV1.self)
    let config = ModelConfiguration("HarnessMonitorPreview", schema: schema, isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [config])
  }
}
