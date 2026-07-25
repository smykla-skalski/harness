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
  typealias Components = (red: Double, green: Double, blue: Double)

  /// The stored name means one colour in light and another in dark, which is
  /// what lets the daemon keep storing a plain name while the mark still
  /// follows the appearance.
  static func color(light: Components, dark: Components) -> Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        let components = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
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
  /// Twelve hue families in two lightness tiers. Generated against a minimum
  /// pairwise distance rather than picked by eye, so the worst pair on a full
  /// board is dE 17.6 in light and 18.1 in dark.
  var components: (light: TaskBoardProjectPalette.Components, dark: TaskBoardProjectPalette.Components) {
    switch self {
    case .blue: ((0.254, 0.572, 0.919), (0.584, 0.740, 1.000))
    case .green: ((0.312, 0.629, 0.331), (0.536, 0.797, 0.535))
    case .purple: ((0.635, 0.495, 0.846), (0.807, 0.678, 0.984))
    case .amber: ((0.671, 0.549, 0.181), (0.845, 0.722, 0.416))
    case .teal: ((0.025, 0.627, 0.617), (0.013, 0.818, 0.806))
    case .pink: ((0.833, 0.419, 0.677), (0.981, 0.623, 0.836))
    case .mint: ((0.030, 0.638, 0.478), (0.364, 0.813, 0.653))
    case .sky: ((0.001, 0.611, 0.757), (0.042, 0.797, 0.983))
    case .warm: ((0.808, 0.481, 0.258), (0.969, 0.666, 0.472))
    case .olive: ((0.532, 0.592, 0.206), (0.719, 0.761, 0.436))
    case .graphite: ((0.666, 0.666, 0.665), (0.629, 0.629, 0.629))
    case .red: ((0.879, 0.426, 0.382), (1.000, 0.641, 0.594))
    case .blueDeep: ((0.021, 0.393, 0.677), (0.230, 0.536, 0.866))
    case .greenDeep: ((0.011, 0.447, 0.136), (0.288, 0.590, 0.307))
    case .purpleDeep: ((0.447, 0.309, 0.681), (0.596, 0.462, 0.796))
    case .amberDeep: ((0.469, 0.373, 0.006), (0.629, 0.514, 0.163))
    case .tealDeep: ((0.013, 0.430, 0.423), (0.010, 0.588, 0.578))
    case .pinkDeep: ((0.657, 0.198, 0.504), (0.784, 0.390, 0.636))
    case .mintDeep: ((0.006, 0.439, 0.324), (0.015, 0.599, 0.447))
    case .skyDeep: ((0.003, 0.419, 0.522), (0.035, 0.572, 0.708))
    case .warmDeep: ((0.616, 0.293, 0.029), (0.759, 0.449, 0.237))
    case .oliveDeep: ((0.346, 0.412, 0.004), (0.497, 0.555, 0.188))
    case .graphiteDeep: ((0.481, 0.481, 0.481), (0.427, 0.427, 0.427))
    case .redDeep: ((0.692, 0.213, 0.197), (0.827, 0.397, 0.355))
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
    switch shape {
    case .circle:
      Path(ellipseIn: rect)
    case .square:
      Path(roundedRect: rect.insetBy(dx: rect.width * 0.06, dy: rect.height * 0.06), cornerRadius: rect.width * 0.16)
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

/// The project mark itself. Small, and deliberately not the only thing naming
/// the project: the footer prints the name right beside it, so this is
/// decorative to VoiceOver rather than a second, colour-only label.
struct TaskBoardProjectMark: View {
  let style: TaskBoardProjectMarkStyle
  /// The text style the mark sits beside. A mark carries no baseline of its
  /// own, so it borrows this font's x-height to find the middle of the
  /// lowercase letters. A plain centre guide lands on the middle of the line
  /// box instead, which the descenders drag a quarter point below where the eye
  /// reads the row, and the mark then floats above the name it belongs to.
  var alignsWith: NSFont.TextStyle = .body
  @Environment(\.fontScale)
  private var fontScale

  private var diameter: CGFloat { 7 * fontScale }

  var body: some View {
    // Read outside the guide: its closure is `@Sendable`, so it cannot reach
    // back into the view's MainActor state.
    let diameter = diameter
    let baseline = diameter / 2
      + NSFont.preferredFont(forTextStyle: alignsWith).xHeight * fontScale / 2
    let outline = TaskBoardProjectMarkOutline(shape: style.shape)
    return outline
      .fill(style.color.color)
      .overlay {
        // Keeps a light mark from vanishing on the card's own light fill.
        outline.strokeBorder(HarnessMonitorTheme.ink.opacity(0.18), lineWidth: 0.5)
      }
      .frame(width: diameter, height: diameter)
      .alignmentGuide(.firstTextBaseline) { _ in baseline }
      .accessibilityHidden(true)
  }
}
