import Foundation
import SwiftData

public enum HarnessModelContainer {
  public static func live(
    using environment: HarnessEnvironment = .current
  ) throws -> ModelContainer {
    let schema = Schema(versionedSchema: HarnessSchemaV1.self)
    let root = HarnessPaths.harnessRoot(using: environment)
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true,
      attributes: nil
    )
    let url = root.appendingPathComponent("harness-cache.store")
    let config = ModelConfiguration("HarnessStore", schema: schema, url: url)

    return try ModelContainer(
      for: schema,
      migrationPlan: HarnessMigrationPlan.self,
      configurations: [config]
    )
  }

  public static func preview() throws -> ModelContainer {
    let schema = Schema(versionedSchema: HarnessSchemaV1.self)
    let config = ModelConfiguration("HarnessPreview", schema: schema, isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [config])
  }
}
