import Foundation

extension HarnessMonitorPaths {
  /// Name of the marker file Spotlight honors to skip a directory tree.
  public static let nonIndexableMarkerName = ".metadata_never_index"

  /// Ensure the monitor-owned data root is excluded from Spotlight indexing and backups.
  ///
  /// Writes an empty `.metadata_never_index` marker (idempotent) and applies
  /// `isExcludedFromBackup`. The app must not write to the app-group parent here: UI-test and
  /// unsigned debug launches can turn that into a macOS App Data privacy prompt. Generated e2e
  /// roots are marked by the e2e runner before it writes high-churn workspaces.
  public static func ensureHarnessRootNonIndexable(
    using environment: HarnessMonitorEnvironment = .current,
    fileManager: FileManager = .default
  ) throws {
    for root in Self.nonIndexableDataRoots(using: environment) {
      try Self.ensureDirectoryNonIndexable(root, fileManager: fileManager)
    }
  }

  private static func nonIndexableDataRoots(using environment: HarnessMonitorEnvironment) -> [URL] {
    Self.uniqueStandardizedDirectories([Self.harnessRoot(using: environment)])
  }

  private static func ensureDirectoryNonIndexable(
    _ directory: URL,
    fileManager: FileManager
  ) throws {
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

    var mutableRoot = directory
    var resourceValues = URLResourceValues()
    resourceValues.isExcludedFromBackup = true
    try? mutableRoot.setResourceValues(resourceValues)

    let marker = directory.appendingPathComponent(Self.nonIndexableMarkerName)
    if !fileManager.fileExists(atPath: marker.path) {
      try Data().write(to: marker, options: .atomic)
    }
  }

  private static func uniqueStandardizedDirectories(_ directories: [URL]) -> [URL] {
    var seen: Set<String> = []
    var unique: [URL] = []
    for directory in directories {
      let standardized = directory.standardizedFileURL
      guard seen.insert(standardized.path).inserted else {
        continue
      }
      unique.append(standardized)
    }
    return unique
  }
}
