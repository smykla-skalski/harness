import Foundation
import SwiftUI

public enum HarnessMonitorThemeDefaults {
  public static let modeKey = "harnessThemeMode"
}

public enum HarnessMonitorBackdropDefaults {
  public static let modeKey = "harnessBackdropMode"
}

public enum HarnessMonitorBackgroundDefaults {
  public static let imageKey = "harnessBackgroundImage"
  public static let recentKey = "harnessRecentBackgrounds"
}

public struct HarnessMonitorBackgroundSelection: Equatable, Identifiable, Sendable {
  public enum Source: Equatable, Sendable {
    case bundled(HarnessMonitorBackgroundImage)
    case system(HarnessMonitorSystemWallpaper)
  }

  public let source: Source
  public let storageValue: String
  public let label: String
  public let subtitle: String
  public let accessibilityKey: String
  public let preferencesStateValue: String

  public static let defaultSelection = Self.bundled(.defaultSelection)
  public static let bundledLibrary = HarnessMonitorBackgroundImage.allCases.map(Self.bundled)
  public static let systemLibrary = HarnessMonitorSystemWallpaper.available.map(Self.system)

  public var id: String { storageValue }

  public static func decode(_ rawValue: String) -> Self {
    if let image = HarnessMonitorBackgroundImage(rawValue: rawValue) {
      return .bundled(image)
    }

    if
      let bundledRawValue = rawValue.removingPrefix("bundle:"),
      let image = HarnessMonitorBackgroundImage(rawValue: bundledRawValue)
    {
      return .bundled(image)
    }

    if let wallpaper = HarnessMonitorSystemWallpaper.wallpaper(for: rawValue) {
      return .system(wallpaper)
    }

    return defaultSelection
  }

  public static func bundled(_ image: HarnessMonitorBackgroundImage) -> Self {
    Self(
      source: .bundled(image),
      storageValue: image.rawValue,
      label: image.label,
      subtitle: image.subtitle,
      accessibilityKey: image.rawValue,
      preferencesStateValue: image.rawValue
    )
  }

  public static func system(_ wallpaper: HarnessMonitorSystemWallpaper) -> Self {
    Self(
      source: .system(wallpaper),
      storageValue: wallpaper.selectionToken,
      label: wallpaper.label,
      subtitle: wallpaper.subtitle,
      accessibilityKey: wallpaper.selectionToken,
      preferencesStateValue: wallpaper.selectionToken
    )
  }
}

public struct HarnessMonitorSystemWallpaper: Equatable, Identifiable, Sendable {
  public let id: String
  public let label: String
  public let subtitle: String
  public let imagePath: String

  public var selectionToken: String {
    "system:\(id)"
  }

  public static let available: [Self] = loadAvailable()

  public static func wallpaper(for selectionToken: String) -> Self? {
    available.first { $0.selectionToken == selectionToken }
  }

  private static func loadAvailable() -> [Self] {
    let desktopPicturesURL = URL(fileURLWithPath: "/System/Library/Desktop Pictures", isDirectory: true)
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
      subtitle: isDynamic || isSolar ? "Built-in macOS dynamic wallpaper" : "Built-in macOS wallpaper",
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

private extension String {
  func removingPrefix(_ prefix: String) -> String? {
    guard hasPrefix(prefix) else {
      return nil
    }

    return String(dropFirst(prefix.count))
  }

  var nonEmpty: String? {
    isEmpty ? nil : self
  }
}

public enum HarnessMonitorThemeMode: String, CaseIterable, Identifiable {
  case auto
  case light
  case dark

  public var id: String { rawValue }

  public var colorScheme: ColorScheme? {
    switch self {
    case .auto: nil
    case .light: .light
    case .dark: .dark
    }
  }

  public var label: String {
    switch self {
    case .auto: "Auto"
    case .light: "Light"
    case .dark: "Dark"
    }
  }
}

public enum HarnessMonitorBackgroundImage: String, CaseIterable, Identifiable, Sendable {
  case auroraVeil
  case blueMarble
  case aleutianCloudbreak
  case andesRelief
  case eastCaicos
  case gangesDelta
  case turksAndCaicos
  case canaryCaldera
  case icefallAntarctica
  case spiralGalaxy

  public static let defaultSelection: Self = .auroraVeil

  public var id: String { rawValue }

  public var label: String {
    switch self {
    case .auroraVeil: "Aurora Veil"
    case .blueMarble: "Blue Marble"
    case .aleutianCloudbreak: "Cloudbreak"
    case .andesRelief: "Andes Relief"
    case .eastCaicos: "East Caicos"
    case .gangesDelta: "River Delta"
    case .turksAndCaicos: "Turks & Caicos"
    case .canaryCaldera: "Canary Caldera"
    case .icefallAntarctica: "Icefall"
    case .spiralGalaxy: "Spiral Galaxy"
    }
  }

  public var subtitle: String {
    switch self {
    case .auroraVeil: "Red-green atmospheric horizon"
    case .blueMarble: "Planet-scale deep blue"
    case .aleutianCloudbreak: "Silver cloud bands over Alaska"
    case .andesRelief: "Snow ridges and glacial lakes"
    case .eastCaicos: "Shallow turquoise coastal shelf"
    case .gangesDelta: "Braided estuary channels"
    case .turksAndCaicos: "Turquoise cays in deep blue"
    case .canaryCaldera: "Volcanic island relief"
    case .icefallAntarctica: "Abstract Antarctic ice texture"
    case .spiralGalaxy: "Luminous deep-space spiral"
    }
  }

  public var assetName: String {
    switch self {
    case .auroraVeil: "BackgroundAuroraVeil"
    case .blueMarble: "BackgroundBlueMarble"
    case .aleutianCloudbreak: "BackgroundAleutianCloudbreak"
    case .andesRelief: "BackgroundAndesRelief"
    case .eastCaicos: "BackgroundEastCaicos"
    case .gangesDelta: "BackgroundGangesDelta"
    case .turksAndCaicos: "BackgroundTurksAndCaicos"
    case .canaryCaldera: "BackgroundCanaryCaldera"
    case .icefallAntarctica: "BackgroundIcefallAntarctica"
    case .spiralGalaxy: "BackgroundSpiralGalaxy"
    }
  }
}

public enum HarnessMonitorBackdropMode: String, CaseIterable, Identifiable {
  case none
  case window
  case content

  public var id: String { rawValue }

  public var label: String {
    switch self {
    case .none: "None"
    case .window: "Window"
    case .content: "Content"
    }
  }
}
