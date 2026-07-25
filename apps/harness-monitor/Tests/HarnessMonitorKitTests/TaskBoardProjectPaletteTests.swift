import Foundation
import HarnessMonitorKit
import Testing

@testable import HarnessMonitorUIPreviewable

/// The palette's whole promise is that two projects on one board look
/// different. That is a measurable claim, so measure it: CIE76 distance in Lab,
/// over every pair, in both appearances.
///
/// The threshold is deliberately not the just-noticeable difference. Two marks
/// seven points across and several rows apart need far more separation than two
/// large patches side by side, and the theme tokens this palette replaced sat
/// at dE 10 while looking identical on a card.
@Suite("Task board project palette")
struct TaskBoardProjectPaletteTests {
  private static let minimumSeparation = 15.0

  @Test("Every pair of palette entries stays apart in both appearances")
  func everyPairStaysApart() {
    for appearance in [Appearance.light, .dark] {
      var worst = (distance: Double.greatestFiniteMagnitude, pair: "")
      let entries = TaskBoardProjectColor.allCases
      for (index, first) in entries.enumerated() {
        for second in entries.dropFirst(index + 1) {
          let distance = Self.distance(first, second, in: appearance)
          if distance < worst.distance {
            worst = (distance, "\(first.rawValue) vs \(second.rawValue)")
          }
        }
      }
      #expect(
        worst.distance >= Self.minimumSeparation,
        "\(appearance) palette's closest pair is \(worst.pair) at dE \(worst.distance)"
      )
    }
  }

  /// A mark is a mark in both appearances. An entry that only exists in light
  /// would leave a dark board a project short.
  @Test("Every palette entry defines both appearances inside the gamut")
  func everyEntryDefinesBothAppearances() {
    for color in TaskBoardProjectColor.allCases {
      let light = color.components.light
      let dark = color.components.dark
      let sameInBothModes = light == dark
      #expect(!sameInBothModes, "\(color.rawValue) is the same in both modes")

      var channels: [Double] = [light.red, light.green, light.blue]
      channels.append(contentsOf: [dark.red, dark.green, dark.blue])
      let outside = channels.filter { $0 < 0 || $0 > 1 }.count
      #expect(outside == 0, "\(color.rawValue) leaves the sRGB gamut")
    }
  }

  @Test("Every palette entry and shape carries a spoken name")
  func everyEntryCarriesASpokenName() {
    let colorTitles = Set(TaskBoardProjectColor.allCases.map(\.title))
    let colorsNamed = colorTitles.count == TaskBoardProjectColor.allCases.count
    #expect(colorsNamed, "two palette entries share a spoken name")

    let blankTitles = colorTitles.filter { $0.isEmpty }.count
    #expect(blankTitles == 0, "a palette entry has nothing to speak")

    let shapeTitles = Set(TaskBoardProjectShape.allCases.map(\.title))
    let shapesNamed = shapeTitles.count == TaskBoardProjectShape.allCases.count
    #expect(shapesNamed, "two outlines share a spoken name")
  }

  private enum Appearance: String {
    case light
    case dark
  }

  private static func distance(
    _ first: TaskBoardProjectColor,
    _ second: TaskBoardProjectColor,
    in appearance: Appearance
  ) -> Double {
    let lhs = lab(of: first, in: appearance)
    let rhs = lab(of: second, in: appearance)
    let lightness = lhs.lightness - rhs.lightness
    let green = lhs.green - rhs.green
    let blue = lhs.blue - rhs.blue
    let sum = lightness * lightness + green * green + blue * blue
    return sum.squareRoot()
  }

  private static func lab(
    of color: TaskBoardProjectColor,
    in appearance: Appearance
  ) -> (lightness: Double, green: Double, blue: Double) {
    let components = appearance == .light ? color.components.light : color.components.dark
    let red = linear(components.red)
    let green = linear(components.green)
    let blue = linear(components.blue)

    var x = 0.4124 * red
    x += 0.3576 * green
    x += 0.1805 * blue
    var y = 0.2126 * red
    y += 0.7152 * green
    y += 0.0722 * blue
    var z = 0.0193 * red
    z += 0.1192 * green
    z += 0.9505 * blue

    let fx = pivot(x / 0.95047)
    let fy = pivot(y)
    let fz = pivot(z / 1.08883)
    return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
  }

  private static func linear(_ channel: Double) -> Double {
    guard channel > 0.04045 else {
      return channel / 12.92
    }
    return pow((channel + 0.055) / 1.055, 2.4)
  }

  private static func pivot(_ value: Double) -> Double {
    guard value > 0.008856 else {
      return 7.787 * value + 16.0 / 116.0
    }
    return pow(value, 1.0 / 3.0)
  }
}
