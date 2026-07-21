import AppKit
import Foundation
import HarnessMonitorKit
import SwiftUI

enum TaskBoardLaneColorToken: String, CaseIterable, Codable, Identifiable, Sendable {
  case warmAccent
  case secondaryInk
  case caution
  case success
  case accent
  case danger
  case blue
  case teal
  case purple
  case pink
  case mint

  var id: String { rawValue }

  var title: String {
    switch self {
    case .warmAccent:
      "Warm"
    case .secondaryInk:
      "Graphite"
    case .caution:
      "Amber"
    case .success:
      "Green"
    case .accent:
      "Blue"
    case .danger:
      "Red"
    case .blue:
      "Sky"
    case .teal:
      "Teal"
    case .purple:
      "Purple"
    case .pink:
      "Pink"
    case .mint:
      "Mint"
    }
  }

  var color: Color {
    switch self {
    case .warmAccent:
      HarnessMonitorTheme.warmAccent
    case .secondaryInk:
      HarnessMonitorTheme.secondaryInk
    case .caution:
      HarnessMonitorTheme.caution
    case .success:
      HarnessMonitorTheme.success
    case .accent:
      HarnessMonitorTheme.accent
    case .danger:
      HarnessMonitorTheme.danger
    case .blue:
      .blue
    case .teal:
      .teal
    case .purple:
      .purple
    case .pink:
      .pink
    case .mint:
      .mint
    }
  }
}

struct TaskBoardLaneCustomColor: Codable, Equatable, Sendable {
  var red: Double
  var green: Double
  var blue: Double
  var opacity: Double

  init(red: Double, green: Double, blue: Double, opacity: Double = 1) {
    self.red = Self.normalized(red)
    self.green = Self.normalized(green)
    self.blue = Self.normalized(blue)
    self.opacity = Self.normalized(opacity)
  }

  init?(color: Color) {
    let nsColor = NSColor(color)
    guard let rgbColor = nsColor.usingColorSpace(.sRGB) else {
      return nil
    }
    self.init(
      red: Double(rgbColor.redComponent),
      green: Double(rgbColor.greenComponent),
      blue: Double(rgbColor.blueComponent),
      opacity: Double(rgbColor.alphaComponent)
    )
  }

  var color: Color {
    Color(.sRGB, red: red, green: green, blue: blue, opacity: opacity)
  }

  private static func normalized(_ value: Double) -> Double {
    min(max((value * 1_000).rounded() / 1_000, 0), 1)
  }
}

struct TaskBoardLaneAppearanceOverride: Codable, Equatable, Sendable {
  var colorToken: TaskBoardLaneColorToken?
  var customColor: TaskBoardLaneCustomColor?
  var symbolName: String?
  var hidesSymbol: Bool?

  var isEmpty: Bool {
    colorToken == nil
      && customColor == nil
      && symbolName == nil
      && hidesSymbol != true
  }
}

struct TaskBoardLaneAppearance: Equatable {
  let overrides: [TaskBoardInboxLane: TaskBoardLaneAppearanceOverride]

  init() {
    overrides = [:]
  }

  @MainActor
  init(rawValue: String) {
    overrides = TaskBoardLaneAppearancePreferences.overrides(from: rawValue)
  }

  func colorToken(for lane: TaskBoardInboxLane) -> TaskBoardLaneColorToken {
    overrides[lane]?.colorToken ?? TaskBoardLaneAppearancePreferences.defaultColorToken(for: lane)
  }

  func color(for lane: TaskBoardInboxLane) -> Color {
    customColor(for: lane)?.color ?? colorToken(for: lane).color
  }

  func customColor(for lane: TaskBoardInboxLane) -> TaskBoardLaneCustomColor? {
    overrides[lane]?.customColor
  }

  func symbolName(for lane: TaskBoardInboxLane) -> String? {
    if hidesSymbol(for: lane) {
      return nil
    }
    return overrides[lane]?.symbolName
      ?? TaskBoardLaneAppearancePreferences.defaultSymbolName(for: lane)
  }

  func hidesSymbol(for lane: TaskBoardInboxLane) -> Bool {
    overrides[lane]?.hidesSymbol == true
  }

  func hasOverride(for lane: TaskBoardInboxLane) -> Bool {
    overrides[lane]?.isEmpty == false
  }

  func hasColorOverride(for lane: TaskBoardInboxLane) -> Bool {
    let override = overrides[lane]
    return override?.customColor != nil || override?.colorToken != nil
  }

  func hasSymbolOverride(for lane: TaskBoardInboxLane) -> Bool {
    let override = overrides[lane]
    return override?.symbolName != nil || override?.hidesSymbol == true
  }
}

enum TaskBoardLaneAppearancePreferences {
  static let storageKey = "harness.task-board.lane-appearance-overrides.v1"
  static let emptyRawValue = "{}"

  /// Advances only on a memo miss, so tests can assert a repeat raw value skips the decoder.
  @MainActor private(set) static var decodeCount = 0

  @MainActor private static var memoizedRawValue: String?
  @MainActor private static var memoizedOverrides:
    [TaskBoardInboxLane: TaskBoardLaneAppearanceOverride] = [:]

  @MainActor
  static func overrides(
    from rawValue: String
  ) -> [TaskBoardInboxLane: TaskBoardLaneAppearanceOverride] {
    if let memoizedRawValue, memoizedRawValue == rawValue {
      return memoizedOverrides
    }
    let decoded = decodeOverrides(from: rawValue)
    memoizedRawValue = rawValue
    memoizedOverrides = decoded
    return decoded
  }

  @MainActor
  private static func decodeOverrides(
    from rawValue: String
  ) -> [TaskBoardInboxLane: TaskBoardLaneAppearanceOverride] {
    decodeCount += 1
    guard let data = rawValue.data(using: .utf8) else {
      return [:]
    }
    let decoded =
      (try? JSONDecoder()
        .decode([String: TaskBoardLaneAppearanceOverride].self, from: data)) ?? [:]
    var overrides: [TaskBoardInboxLane: TaskBoardLaneAppearanceOverride] = [:]
    for (key, value) in decoded where key != "umbrella" && !value.isEmpty {
      guard let lane = TaskBoardInboxLane(rawValue: key) else {
        continue
      }
      overrides[lane] = value
    }
    if overrides[.backlog] == nil,
      let legacyOverride = decoded["umbrella"],
      !legacyOverride.isEmpty
    {
      overrides[.backlog] = legacyOverride
    }
    return overrides
  }

  static func rawValue(
    for overrides: [TaskBoardInboxLane: TaskBoardLaneAppearanceOverride]
  ) -> String {
    let filtered = overrides.filter { !$0.value.isEmpty }
    guard !filtered.isEmpty else {
      return emptyRawValue
    }

    let encodable = Dictionary(
      uniqueKeysWithValues: filtered.map { ($0.key.rawValue, $0.value) }
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard
      let data = try? encoder.encode(encodable),
      let rawValue = String(data: data, encoding: .utf8)
    else {
      return emptyRawValue
    }
    return rawValue
  }

  @MainActor
  static func load(
    from userDefaults: UserDefaults = .standard
  ) -> [TaskBoardInboxLane: TaskBoardLaneAppearanceOverride] {
    overrides(from: userDefaults.string(forKey: storageKey) ?? emptyRawValue)
  }

  static func save(
    _ overrides: [TaskBoardInboxLane: TaskBoardLaneAppearanceOverride],
    to userDefaults: UserDefaults = .standard
  ) {
    userDefaults.set(rawValue(for: overrides), forKey: storageKey)
  }

  @MainActor
  static func settingColorToken(
    _ colorToken: TaskBoardLaneColorToken,
    for lane: TaskBoardInboxLane,
    rawValue: String
  ) -> String {
    var overrides = overrides(from: rawValue)
    var override = overrides[lane] ?? TaskBoardLaneAppearanceOverride()
    override.colorToken = colorToken == defaultColorToken(for: lane) ? nil : colorToken
    override.customColor = nil
    overrides[lane] = override
    return Self.rawValue(for: overrides)
  }

  @MainActor
  static func settingCustomColor(
    _ color: Color,
    for lane: TaskBoardInboxLane,
    rawValue: String
  ) -> String {
    guard let customColor = TaskBoardLaneCustomColor(color: color) else {
      return rawValue
    }
    var overrides = overrides(from: rawValue)
    var override = overrides[lane] ?? TaskBoardLaneAppearanceOverride()
    override.colorToken = nil
    override.customColor = customColor
    overrides[lane] = override
    return Self.rawValue(for: overrides)
  }

  @MainActor
  static func settingSymbolName(
    _ symbolName: String,
    for lane: TaskBoardInboxLane,
    rawValue: String
  ) -> String {
    var overrides = overrides(from: rawValue)
    var override = overrides[lane] ?? TaskBoardLaneAppearanceOverride()
    let normalized = symbolName.trimmingCharacters(in: .whitespacesAndNewlines)
    override.symbolName =
      normalized.isEmpty || normalized == defaultSymbolName(for: lane) ? nil : normalized
    override.hidesSymbol = nil
    overrides[lane] = override
    return Self.rawValue(for: overrides)
  }

  @MainActor
  static func settingSymbolVisibility(
    _ isVisible: Bool,
    for lane: TaskBoardInboxLane,
    rawValue: String
  ) -> String {
    var overrides = overrides(from: rawValue)
    var override = overrides[lane] ?? TaskBoardLaneAppearanceOverride()
    override.hidesSymbol = isVisible ? nil : true
    if !isVisible {
      override.symbolName = nil
    }
    overrides[lane] = override
    return Self.rawValue(for: overrides)
  }

  @MainActor
  static func resetColorRawValue(
    for lane: TaskBoardInboxLane,
    rawValue: String
  ) -> String {
    var overrides = overrides(from: rawValue)
    var override = overrides[lane] ?? TaskBoardLaneAppearanceOverride()
    override.colorToken = nil
    override.customColor = nil
    overrides[lane] = override
    return Self.rawValue(for: overrides)
  }

  @MainActor
  static func resetSymbolRawValue(
    for lane: TaskBoardInboxLane,
    rawValue: String
  ) -> String {
    var overrides = overrides(from: rawValue)
    var override = overrides[lane] ?? TaskBoardLaneAppearanceOverride()
    override.symbolName = nil
    override.hidesSymbol = nil
    overrides[lane] = override
    return Self.rawValue(for: overrides)
  }

  @MainActor
  static func resetRawValue(
    for lane: TaskBoardInboxLane,
    rawValue: String
  ) -> String {
    var overrides = overrides(from: rawValue)
    overrides.removeValue(forKey: lane)
    return Self.rawValue(for: overrides)
  }

  @MainActor
  static func hasOverride(
    for lane: TaskBoardInboxLane,
    rawValue: String
  ) -> Bool {
    overrides(from: rawValue)[lane]?.isEmpty == false
  }

  static func defaultColorToken(for lane: TaskBoardInboxLane) -> TaskBoardLaneColorToken {
    switch lane {
    case .umbrella:
      .purple
    case .backlog:
      .warmAccent
    case .todo:
      .secondaryInk
    case .planning:
      .warmAccent
    case .inProgress:
      .caution
    case .agenticReview:
      .success
    case .testing:
      .accent
    case .inReview:
      .accent
    case .toReview:
      .success
    case .humanRequired:
      .danger
    case .failed:
      .danger
    }
  }

  static func defaultSymbolName(for lane: TaskBoardInboxLane) -> String {
    lane.systemImage
  }
}

extension EnvironmentValues {
  @Entry var taskBoardLaneAppearance = TaskBoardLaneAppearance()
}

func taskBoardLaneColor(
  for lane: TaskBoardInboxLane,
  appearance: TaskBoardLaneAppearance = TaskBoardLaneAppearance()
) -> Color {
  appearance.color(for: lane)
}

func taskBoardLaneSystemImage(
  for lane: TaskBoardInboxLane,
  appearance: TaskBoardLaneAppearance = TaskBoardLaneAppearance()
) -> String? {
  appearance.symbolName(for: lane)
}
