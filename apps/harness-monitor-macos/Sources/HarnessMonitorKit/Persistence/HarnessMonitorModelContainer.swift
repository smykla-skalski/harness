import Foundation
import SwiftData

public enum HarnessMonitorModelContainer {
  public static func live(
    using environment: HarnessMonitorEnvironment = .current
  ) throws -> ModelContainer {
    let schema = Schema(versionedSchema: HarnessMonitorSchemaV3.self)
    let root = HarnessMonitorPaths.harnessRoot(using: environment)
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true,
      attributes: nil
    )
    let url = root.appendingPathComponent("harness-cache.store")
    let config = ModelConfiguration("HarnessMonitorStore", schema: schema, url: url)

    return try makeContainer(schema: schema, config: config)
  }

  public static func preview() throws -> ModelContainer {
    let schema = Schema(versionedSchema: HarnessMonitorSchemaV3.self)
    let config = ModelConfiguration(
      "HarnessMonitorPreview", schema: schema, isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [config])
  }

  private static func makeContainer(
    schema: Schema,
    config: ModelConfiguration
  ) throws -> ModelContainer {
    try ModelContainer(
      for: schema,
      migrationPlan: HarnessMonitorMigrationPlan.self,
      configurations: [config]
    )
  }
}
