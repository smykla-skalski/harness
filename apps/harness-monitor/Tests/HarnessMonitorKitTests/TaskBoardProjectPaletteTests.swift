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
  @Test("Every palette entry defines both appearances")
  func everyEntryDefinesBothAppearances() {
    for color in TaskBoardProjectColor.allCases {
      let components = color.components
      #expect(components.light != components.dark, "\(color.rawValue) is the same in both modes")
      for channel in [components.light.red, components.light.green, components.light.blue]
        + [components.dark.red, components.dark.green, components.dark.blue] {
        #expect(channel >= 0 && channel <= 1, "\(color.rawValue) leaves the sRGB gamut")
      }
    }
  }

  @Test("Every palette entry and shape carries a spoken name")
  func everyEntryCarriesASpokenName() {
    let colorTitles = Set(TaskBoardProjectColor.allCases.map(\.title))
    #expect(colorTitles.count == TaskBoardProjectColor.allCases.count)
    #expect(!colorTitles.contains(where: \.isEmpty))

    let shapeTitles = Set(TaskBoardProjectShape.allCases.map(\.title))
    #expect(shapeTitles.count == TaskBoardProjectShape.allCases.count)
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
    return ((lhs.0 - rhs.0) * (lhs.0 - rhs.0) + (lhs.1 - rhs.1) * (lhs.1 - rhs.1)
      + (lhs.2 - rhs.2) * (lhs.2 - rhs.2)).squareRoot()
  }

  private static func lab(
    of color: TaskBoardProjectColor,
    in appearance: Appearance
  ) -> (Double, Double, Double) {
    let components = appearance == .light ? color.components.light : color.components.dark
    let linear = [components.red, components.green, components.blue].map { channel in
      channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }
    let x = (0.4124 * linear[0] + 0.3576 * linear[1] + 0.1805 * linear[2]) / 0.95047
    let y = 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    let z = (0.0193 * linear[0] + 0.1192 * linear[1] + 0.9505 * linear[2]) / 1.08883
    let (fx, fy, fz) = (pivot(x), pivot(y), pivot(z))
    return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
  }

  private static func pivot(_ value: Double) -> Double {
    value > 0.008856 ? pow(value, 1.0 / 3.0) : 7.787 * value + 16.0 / 116.0
  }
}
