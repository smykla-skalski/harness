import Foundation
import SwiftUI

public struct HarnessMonitorSystemWallpaper: Equatable, Identifiable, Sendable {
  public let id: String
  public let label: String
  public let subtitle: String
  public let imagePath: String

  public var selectionToken: String {
    "system:\(id)"
  }

  public static var available: [Self] {
    HarnessMonitorSystemWallpaperCache.shared.snapshot()
  }

  public static func loadAvailable() async -> [Self] {
    await HarnessMonitorSystemWallpaperLoader.shared.available()
  }

  public static func wallpaper(for selectionToken: String) -> Self? {
    available.first { $0.selectionToken == selectionToken }
  }

  fileprivate static func loadAvailableFromDisk() -> [Self] {
    let desktopPicturesURL = URL(
      fileURLWithPath: "/System/Library/Desktop Pictures", isDirectory: true)
    guard
      let urls = try? FileManager.default.contentsOfDirectory(
        at: desktopPicturesURL,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
      )
    else {
      return []
    }

    let wallpapers = urls.compactMap(Self.wallpaper(from:)).sorted {
      $0.label.localizedStandardCompare($1.label) == .orderedAscending
    }

    var identifierCounts: [String: Int] = [:]
    return wallpapers.map { wallpaper in
      let nextCount = identifierCounts[wallpaper.id, default: 0] + 1
      identifierCounts[wallpaper.id] = nextCount

      guard nextCount > 1 else {
        return wallpaper
      }

      return Self(
        id: "\(wallpaper.id)-\(nextCount)",
        label: wallpaper.label,
        subtitle: wallpaper.subtitle,
        imagePath: wallpaper.imagePath
      )
    }
  }

  private static func wallpaper(from url: URL) -> Self? {
    switch url.pathExtension.lowercased() {
    case "heic", "jpg", "jpeg", "png":
      return directWallpaper(from: url)
    case "madesktop":
      return manifestWallpaper(from: url)
    default:
      return nil
    }
  }

  private static func directWallpaper(from url: URL) -> Self? {
    let label = url.deletingPathExtension().lastPathComponent
    return Self(
      id: slug(label),
      label: label,
      subtitle: "Built-in macOS wallpaper",
      imagePath: url.path
    )
  }

  private static func manifestWallpaper(from url: URL) -> Self? {
    guard
      let data = try? Data(contentsOf: url),
      let rawPlist = try? PropertyListSerialization.propertyList(from: data, format: nil),
      let plist = rawPlist as? [String: Any]
    else {
      return nil
    }

    guard
      let thumbnailPath = plist["thumbnailPath"] as? String,
      FileManager.default.fileExists(atPath: thumbnailPath)
    else {
      return nil
    }

    let label =
      (plist["mobileAssetID"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
      .nonEmpty ?? url.deletingPathExtension().lastPathComponent
    let isDynamic = plist["isDynamic"] as? Bool ?? false
    let isSolar = plist["isSolar"] as? Bool ?? false

    return Self(
      id: slug(label),
      label: label,
      subtitle: isDynamic || isSolar
        ? "Built-in macOS dynamic wallpaper" : "Built-in macOS wallpaper",
      imagePath: thumbnailPath
    )
  }

  private static func slug(_ value: String) -> String {
    let lowercased = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let allowed = CharacterSet.alphanumerics
    let mapped = lowercased.unicodeScalars.map { scalar in
      allowed.contains(scalar) ? String(scalar) : "-"
    }.joined()
    let collapsed = mapped.replacingOccurrences(of: "--+", with: "-", options: .regularExpression)
    return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
  }
}

private final class HarnessMonitorSystemWallpaperCache: @unchecked Sendable {
  static let shared = HarnessMonitorSystemWallpaperCache()

  private let lock = NSLock()
  private var wallpapers: [HarnessMonitorSystemWallpaper] = []

  func snapshot() -> [HarnessMonitorSystemWallpaper] {
    lock.withLock { wallpapers }
  }

  func replace(with nextWallpapers: [HarnessMonitorSystemWallpaper]) {
    lock.withLock {
      wallpapers = nextWallpapers
    }
  }
}

public actor HarnessMonitorSystemWallpaperLoader {
  public static let shared = HarnessMonitorSystemWallpaperLoader()

  private var loadedWallpapers: [HarnessMonitorSystemWallpaper]?

  public func available() -> [HarnessMonitorSystemWallpaper] {
    if let loadedWallpapers {
      return loadedWallpapers
    }

    let loaded = HarnessMonitorSystemWallpaper.loadAvailableFromDisk()
    loadedWallpapers = loaded
    HarnessMonitorSystemWallpaperCache.shared.replace(with: loaded)
    return loaded
  }

  public func waitForIdle() {}
}
