import AppKit
import HarnessMonitorKit
import SwiftUI

/// The palette owns its colours instead of borrowing the theme's tokens.
///
/// Borrowing looked tidier and was wrong: `accent` and `blue` differ by dE 12,
/// `mint` and `teal` share two channels outright, and neither was chosen to be
/// told apart from the other at the size of a card mark. A theme colour answers
/// to the surface it paints; a palette entry answers only to the other
/// twenty-three, which is a property `TaskBoardProjectPaletteTests` can check
/// and a borrowed token cannot promise.
enum TaskBoardProjectPalette {
  struct Components: Equatable {
    let red: Double
    let green: Double
    let blue: Double
  }

  /// The stored name means one colour in light and another in dark, which is
  /// what lets the daemon keep storing a plain name while the mark still
  /// follows the appearance.
  static func color(light: Components, dark: Components) -> Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        let components =
          appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
          ? dark
          : light
        return NSColor(
          srgbRed: components.red,
          green: components.green,
          blue: components.blue,
          alpha: 1
        )
      }
    )
  }
}

extension TaskBoardProjectColor {
  fileprivate typealias Components = TaskBoardProjectPalette.Components

  /// Twelve hue families in two lightness tiers. Generated against a minimum
  /// pairwise distance rather than picked by eye, so the worst pair on a full
  /// board is dE 17.6 in light and 18.1 in dark.
  var components:
    (light: TaskBoardProjectPalette.Components, dark: TaskBoardProjectPalette.Components)
  {
    switch self {
    case .blue:
      (
        Components(red: 0.254, green: 0.572, blue: 0.919),
        Components(red: 0.584, green: 0.740, blue: 1.000)
      )
    case .green:
      (
        Components(red: 0.312, green: 0.629, blue: 0.331),
        Components(red: 0.536, green: 0.797, blue: 0.535)
      )
    case .purple:
      (
        Components(red: 0.635, green: 0.495, blue: 0.846),
        Components(red: 0.807, green: 0.678, blue: 0.984)
      )
    case .amber:
      (
        Components(red: 0.671, green: 0.549, blue: 0.181),
        Components(red: 0.845, green: 0.722, blue: 0.416)
      )
    case .teal:
      (
        Components(red: 0.025, green: 0.627, blue: 0.617),
        Components(red: 0.013, green: 0.818, blue: 0.806)
      )
    case .pink:
      (
        Components(red: 0.833, green: 0.419, blue: 0.677),
        Components(red: 0.981, green: 0.623, blue: 0.836)
      )
    case .mint:
      (
        Components(red: 0.030, green: 0.638, blue: 0.478),
        Components(red: 0.364, green: 0.813, blue: 0.653)
      )
    case .sky:
      (
        Components(red: 0.001, green: 0.611, blue: 0.757),
        Components(red: 0.042, green: 0.797, blue: 0.983)
      )
    case .warm:
      (
        Components(red: 0.808, green: 0.481, blue: 0.258),
        Components(red: 0.969, green: 0.666, blue: 0.472)
      )
    case .olive:
      (
        Components(red: 0.532, green: 0.592, blue: 0.206),
        Components(red: 0.719, green: 0.761, blue: 0.436)
      )
    case .graphite:
      (
        Components(red: 0.666, green: 0.666, blue: 0.665),
        Components(red: 0.629, green: 0.629, blue: 0.629)
      )
    case .red:
      (
        Components(red: 0.879, green: 0.426, blue: 0.382),
        Components(red: 1.000, green: 0.641, blue: 0.594)
      )
    case .blueDeep:
      (
        Components(red: 0.021, green: 0.393, blue: 0.677),
        Components(red: 0.230, green: 0.536, blue: 0.866)
      )
    case .greenDeep:
      (
        Components(red: 0.011, green: 0.447, blue: 0.136),
        Components(red: 0.288, green: 0.590, blue: 0.307)
      )
    case .purpleDeep:
      (
        Components(red: 0.447, green: 0.309, blue: 0.681),
        Components(red: 0.596, green: 0.462, blue: 0.796)
      )
    case .amberDeep:
      (
        Components(red: 0.469, green: 0.373, blue: 0.006),
        Components(red: 0.629, green: 0.514, blue: 0.163)
      )
    case .tealDeep:
      (
        Components(red: 0.013, green: 0.430, blue: 0.423),
        Components(red: 0.010, green: 0.588, blue: 0.578)
      )
    case .pinkDeep:
      (
        Components(red: 0.657, green: 0.198, blue: 0.504),
        Components(red: 0.784, green: 0.390, blue: 0.636)
      )
    case .mintDeep:
      (
        Components(red: 0.006, green: 0.439, blue: 0.324),
        Components(red: 0.015, green: 0.599, blue: 0.447)
      )
    case .skyDeep:
      (
        Components(red: 0.003, green: 0.419, blue: 0.522),
        Components(red: 0.035, green: 0.572, blue: 0.708)
      )
    case .warmDeep:
      (
        Components(red: 0.616, green: 0.293, blue: 0.029),
        Components(red: 0.759, green: 0.449, blue: 0.237)
      )
    case .oliveDeep:
      (
        Components(red: 0.346, green: 0.412, blue: 0.004),
        Components(red: 0.497, green: 0.555, blue: 0.188)
      )
    case .graphiteDeep:
      (
        Components(red: 0.481, green: 0.481, blue: 0.481),
        Components(red: 0.427, green: 0.427, blue: 0.427)
      )
    case .redDeep:
      (
        Components(red: 0.692, green: 0.213, blue: 0.197),
        Components(red: 0.827, green: 0.397, blue: 0.355)
      )
    }
  }

  var color: Color {
    let components = components
    return TaskBoardProjectPalette.color(light: components.light, dark: components.dark)
  }

  /// Spoken and shown wherever the swatch alone would be the only difference
  /// between two controls.
  var title: String {
    switch self {
    case .blue: "Blue"
    case .green: "Green"
    case .purple: "Purple"
    case .amber: "Amber"
    case .teal: "Teal"
    case .pink: "Pink"
    case .mint: "Mint"
    case .sky: "Sky"
    case .warm: "Warm"
    case .olive: "Olive"
    case .graphite: "Graphite"
    case .red: "Red"
    case .blueDeep: "Deep Blue"
    case .greenDeep: "Deep Green"
    case .purpleDeep: "Deep Purple"
    case .amberDeep: "Deep Amber"
    case .tealDeep: "Deep Teal"
    case .pinkDeep: "Deep Pink"
    case .mintDeep: "Deep Mint"
    case .skyDeep: "Deep Sky"
    case .warmDeep: "Deep Warm"
    case .oliveDeep: "Deep Olive"
    case .graphiteDeep: "Deep Graphite"
    case .redDeep: "Deep Red"
    }
  }
}

extension TaskBoardProjectShape {
  var title: String {
    switch self {
    case .circle: "Circle"
    case .square: "Square"
    case .triangle: "Triangle"
    case .diamond: "Diamond"
    case .pentagon: "Pentagon"
    case .hexagon: "Hexagon"
    }
  }
}

/// Both halves of a project's mark. They travel together because they answer
/// one question between them, and a card that resolved the colour but not the
/// outline would show a circle that means something it does not.
struct TaskBoardProjectMarkStyle: Equatable, Sendable {
  let color: TaskBoardProjectColor
  let shape: TaskBoardProjectShape
}

/// The outline half of the mark. A regular polygon covers every case except the
/// circle and the square, and the square is a polygon with its corners softened
/// so it does not read as a diamond that failed to rotate.
struct TaskBoardProjectMarkOutline: InsettableShape {
  let shape: TaskBoardProjectShape
  var inset: CGFloat = 0

  func inset(by amount: CGFloat) -> Self {
    var copy = self
    copy.inset += amount
    return copy
  }

  func path(in bounds: CGRect) -> Path {
    let rect = bounds.insetBy(dx: inset, dy: inset)
    return switch shape {
    case .circle:
      Path(ellipseIn: rect)
    case .square:
      Path(
        roundedRect: rect.insetBy(dx: rect.width * 0.06, dy: rect.height * 0.06),
        cornerRadius: rect.width * 0.16)
    case .triangle:
      Self.polygon(sides: 3, in: rect)
    case .diamond:
      Self.polygon(sides: 4, in: rect)
    case .pentagon:
      Self.polygon(sides: 5, in: rect)
    case .hexagon:
      Self.polygon(sides: 6, in: rect)
    }
  }

  private static func polygon(sides: Int, in rect: CGRect) -> Path {
    let center = CGPoint(x: rect.midX, y: rect.midY)
    // Fewer sides leave more of the circle empty, so a triangle drawn to the
    // same radius as a hexagon reads as the smaller mark. Growing the radius as
    // the sides drop keeps the filled area about even across the set.
    let coverage = 1.0 + (6.0 - Double(sides)) * 0.06
    let radius = min(rect.width, rect.height) / 2 * coverage
    var path = Path()
    for corner in 0..<sides {
      // Start at the top so every outline has a point or an edge facing up,
      // which is what makes two of them comparable at a glance.
      let angle = -Double.pi / 2 + 2 * Double.pi * Double(corner) / Double(sides)
      let point = CGPoint(
        x: center.x + radius * cos(angle),
        y: center.y + radius * sin(angle)
      )
      if corner == 0 {
        path.move(to: point)
      } else {
        path.addLine(to: point)
      }
    }
    path.closeSubpath()
    return path
  }
}

/// Cap heights for the handful of text styles a mark sits beside. The metric is
/// a property of the style's font, so it is resolved once instead of on every
/// card's every render; the caller still scales it, which is the part that moves.
@MainActor
private enum TaskBoardProjectMarkCapHeights {
  private static var resolved: [NSFont.TextStyle: CGFloat] = [:]

  static func capHeight(for style: NSFont.TextStyle) -> CGFloat {
    if let known = resolved[style] {
      return known
    }
    let height = NSFont.preferredFont(forTextStyle: style).capHeight
    resolved[style] = height
    return height
  }
}

/// The project mark itself. Small, and deliberately not the only thing naming
/// the project: the footer prints the name right beside it, so this is
/// decorative to VoiceOver rather than a second, colour-only label.
struct TaskBoardProjectMark: View {
  let style: TaskBoardProjectMarkStyle
  /// The text style the mark sits beside. A mark carries no baseline of its
  /// own, so it borrows this font's cap height and sits on the middle of the
  /// band between the baseline and the top of a capital. That is where the eye
  /// reads the line: centring on the line box puts the mark high, because the
  /// descenders stretch the box below anything actually drawn, and centring on
  /// the x-height puts it low the moment the label starts with a capital, which
  /// a project name usually does.
  var alignsWith: NSFont.TextStyle = .body
  @Environment(\.fontScale)
  private var fontScale
  @Environment(\.colorSchemeContrast)
  private var colorSchemeContrast

  private var diameter: CGFloat { 7 * fontScale }

  var body: some View {
    // Read outside the guide: its closure is `@Sendable`, so it cannot reach
    // back into the view's MainActor state.
    let diameter = diameter
    let baseline =
      diameter / 2
      + TaskBoardProjectMarkCapHeights.capHeight(for: alignsWith) * fontScale / 2
    let outline = TaskBoardProjectMarkOutline(shape: style.shape)
    // The border keeps a light mark from vanishing on the card's own light
    // fill, and past the palette it is also what makes the shape readable, so
    // Increased Contrast gets a border that can carry that on its own.
    let increased = colorSchemeContrast == .increased
    return
      outline
      .fill(style.color.color)
      .overlay {
        outline.strokeBorder(
          HarnessMonitorTheme.ink.opacity(increased ? 0.65 : 0.18),
          lineWidth: increased ? 1 : 0.5
        )
      }
      .frame(width: diameter, height: diameter)
      .alignmentGuide(.firstTextBaseline) { _ in baseline }
      .accessibilityHidden(true)
  }
}
