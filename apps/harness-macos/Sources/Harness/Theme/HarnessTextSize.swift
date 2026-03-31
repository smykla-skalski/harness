import SwiftUI

enum HarnessTextSize {
  static let storageKey = "harnessTextSize"
  static let defaultIndex = 3

  static let levels: [DynamicTypeSize] = [
    .xSmall, .small, .medium, .large,
    .xLarge, .xxLarge, .xxxLarge,
    .accessibility1, .accessibility2, .accessibility3,
  ]

  private static let labels: [DynamicTypeSize: String] = [
    .xSmall: "Extra small",
    .small: "Small",
    .medium: "Medium",
    .large: "Default",
    .xLarge: "Large",
    .xxLarge: "Extra large",
    .xxxLarge: "Largest",
    .accessibility1: "Accessibility 1",
    .accessibility2: "Accessibility 2",
    .accessibility3: "Accessibility 3",
  ]

  static func level(at index: Int) -> DynamicTypeSize {
    guard levels.indices.contains(index) else { return .large }
    return levels[index]
  }

  static func label(for index: Int) -> String {
    guard levels.indices.contains(index) else { return "Default" }
    return labels[levels[index]] ?? "Default"
  }

  static func label(for size: DynamicTypeSize) -> String {
    labels[size] ?? "Default"
  }

  static func canIncrease(_ index: Int) -> Bool {
    index < levels.count - 1
  }

  static func canDecrease(_ index: Int) -> Bool {
    index > 0
  }
}
