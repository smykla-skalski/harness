import Foundation
import SwiftData

public enum HarnessMonitorModelContainer {
  private static let unknownModelVersionErrorCode = 134_504

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
    let config = ModelConfiguration(
      "HarnessMonitorStore",
      schema: schema,
      url: url,
      cloudKitDatabase: .none
    )

    #if HARNESS_FEATURE_OTEL
      return try HarnessMonitorTelemetry.shared.withSQLiteOperation(
        operation: "open_cache_store",
        access: "maintenance",
        database: "monitor-cache",
        databasePath: url.path
      ) {
        try makeContainer(schema: schema, config: config, storeURL: url)
      }
    #else
      return try makeContainer(schema: schema, config: config, storeURL: url)
    #endif
  }

  public static func preview() throws -> ModelContainer {
    let schema = Schema(versionedSchema: HarnessMonitorCurrentSchema.self)
    let config = ModelConfiguration(
      "HarnessMonitorPreview",
      schema: schema,
      isStoredInMemoryOnly: true,
      cloudKitDatabase: .none
    )
    return try ModelContainer(for: schema, configurations: [config])
  }

  private static func makeContainer(
    schema: Schema,
    config: ModelConfiguration,
    storeURL: URL
  ) throws -> ModelContainer {
    do {
      return try makeMigratingContainer(schema: schema, config: config)
    } catch {
      guard isRecoverableCacheStoreLoadError(error) else {
        throw error
      }
      let quarantineURL = try quarantineIncompatibleStore(at: storeURL)
      HarnessMonitorLogger.store.warning(
        """
        Rebuilt incompatible SwiftData cache store after container load failure; \
        quarantined_at=\(quarantineURL?.path ?? "none", privacy: .private) \
        error=\(error.localizedDescription, privacy: .public)
        """
      )
      return try makeMigratingContainer(schema: schema, config: config)
    }
  }

  private static func makeMigratingContainer(
    schema: Schema,
    config: ModelConfiguration
  ) throws -> ModelContainer {
    try ModelContainer(
      for: schema,
      migrationPlan: HarnessMonitorMigrationPlan.self,
      configurations: [config]
    )
  }

  private static func isRecoverableCacheStoreLoadError(_ error: any Error) -> Bool {
    let nsError = error as NSError
    if nsError.domain == NSCocoaErrorDomain && nsError.code == unknownModelVersionErrorCode {
      return true
    }
    if nsError.localizedDescription.localizedCaseInsensitiveContains("unknown model version") {
      return true
    }
    if String(reflecting: error).contains("loadIssueModelContainer") {
      return true
    }
    if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? any Error {
      return isRecoverableCacheStoreLoadError(underlying)
    }
    let detailedErrors = nsError.userInfo["NSDetailedErrors"] as? [any Error] ?? []
    return detailedErrors.contains(where: isRecoverableCacheStoreLoadError)
  }

  @discardableResult
  private static func quarantineIncompatibleStore(
    at storeURL: URL,
    fileManager: FileManager = .default,
    now: Date = .now
  ) throws -> URL? {
    let quarantineRoot =
      storeURL
      .deletingLastPathComponent()
      .appendingPathComponent("incompatible-cache-stores", isDirectory: true)
    try fileManager.createDirectory(
      at: quarantineRoot,
      withIntermediateDirectories: true,
      attributes: nil
    )
    let stamp = String(Int(now.timeIntervalSince1970))
    let destinationRoot =
      quarantineRoot
      .appendingPathComponent("harness-cache.store-\(stamp)", isDirectory: true)
    try fileManager.createDirectory(
      at: destinationRoot,
      withIntermediateDirectories: true,
      attributes: nil
    )

    var movedAnyFile = false
    for suffix in ["", "-wal", "-shm"] {
      let sourceURL = URL(fileURLWithPath: storeURL.path + suffix)
      guard fileManager.fileExists(atPath: sourceURL.path) else {
        continue
      }
      let destinationURL = destinationRoot.appendingPathComponent(sourceURL.lastPathComponent)
      if fileManager.fileExists(atPath: destinationURL.path) {
        try fileManager.removeItem(at: destinationURL)
      }
      try fileManager.moveItem(at: sourceURL, to: destinationURL)
      movedAnyFile = true
    }

    if movedAnyFile {
      return destinationRoot
    }
    try? fileManager.removeItem(at: destinationRoot)
    return nil
  }
}
