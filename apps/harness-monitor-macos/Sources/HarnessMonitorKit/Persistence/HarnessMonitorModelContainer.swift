import Foundation
import SwiftData

public enum HarnessMonitorModelContainer {
  public static func live(
    using environment: HarnessMonitorEnvironment = .current
  ) throws -> ModelContainer {
    let schema = Schema(versionedSchema: HarnessMonitorCurrentSchema.self)
    let root = HarnessMonitorPaths.harnessRoot(using: environment)
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true,
      attributes: nil
    )
    let url = HarnessMonitorPaths.cacheStoreURL(using: environment)
    let config = ModelConfiguration("HarnessMonitorStore", schema: schema, url: url)

    #if HARNESS_FEATURE_OTEL
      return try HarnessMonitorTelemetry.shared.withSQLiteOperation(
        operation: "open_cache_store",
        access: "maintenance",
        database: "monitor-cache",
        databasePath: url.path
      ) {
        try makeContainer(schema: schema, config: config)
      }
    #else
      return try makeContainer(schema: schema, config: config)
    #endif
  }

  public static func preview() throws -> ModelContainer {
    let schema = Schema(versionedSchema: HarnessMonitorCurrentSchema.self)
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
