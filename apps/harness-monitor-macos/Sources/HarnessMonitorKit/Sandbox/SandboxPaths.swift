import Foundation

public enum SandboxPaths {
  public static func appGroupContainerURL() -> URL? {
    FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: HarnessMonitorAppGroup.identifier
    )
  }

  public static func bookmarksFileURL(containerURL: URL) -> URL {
    containerURL.appendingPathComponent("sandbox", isDirectory: true)
      .appendingPathComponent("bookmarks.json")
  }

  #if DEBUG
    public static func debugBookmarkFallbackContainerURL() -> URL {
      let containerURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(
          "HarnessMonitorBookmarkFallback-\(ProcessInfo.processInfo.processIdentifier)",
          isDirectory: true
        )
      try? FileManager.default.createDirectory(at: containerURL, withIntermediateDirectories: true)
      return containerURL
    }
  #endif
}
