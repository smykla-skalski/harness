import Foundation
import SwiftData

public enum HarnessModelContainer {
  public static func live() throws -> ModelContainer {
    let schema = Schema(versionedSchema: HarnessSchemaV1.self)
    let url = HarnessPaths.harnessRoot().appendingPathComponent("harness-cache.store")
    let config = ModelConfiguration("HarnessStore", schema: schema, url: url)

    do {
      return try ModelContainer(
        for: schema,
        migrationPlan: HarnessMigrationPlan.self,
        configurations: [config]
      )
    } catch {
      try? FileManager.default.removeItem(at: url)
      try? FileManager.default.removeItem(at: url.appendingPathExtension("wal"))
      try? FileManager.default.removeItem(at: url.appendingPathExtension("shm"))
      return try ModelContainer(
        for: schema,
        migrationPlan: HarnessMigrationPlan.self,
        configurations: [config]
      )
    }
  }

  public static func preview() throws -> ModelContainer {
    let schema = Schema(versionedSchema: HarnessSchemaV1.self)
    let config = ModelConfiguration("HarnessPreview", schema: schema, isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [config])
  }
}
