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
}
