import AppKit
import HarnessMonitorKit
import SwiftUI

/// The daemon stores a plain color name; the theme decides what that looks like
/// here. Keeping the translation on this side is what lets the mark follow
/// light and dark mode without the stored value changing.
extension TaskBoardProjectColor {
  var color: Color {
    switch self {
    case .blue:
      HarnessMonitorTheme.accent
    case .green:
      HarnessMonitorTheme.success
    case .purple:
      HarnessMonitorTheme.purple
    case .amber:
      HarnessMonitorTheme.caution
    case .teal:
      HarnessMonitorTheme.teal
    case .pink:
      HarnessMonitorTheme.pink
    case .red:
      HarnessMonitorTheme.danger
    case .mint:
      HarnessMonitorTheme.mint
    case .sky:
      HarnessMonitorTheme.blue
    case .warm:
      HarnessMonitorTheme.warmAccent
    case .graphite:
      HarnessMonitorTheme.secondaryInk
    }
  }

  /// Spoken and shown wherever the swatch alone would be the only difference
  /// between two controls.
  var title: String {
    switch self {
    case .blue:
      "Blue"
    case .green:
      "Green"
    case .purple:
      "Purple"
    case .amber:
      "Amber"
    case .teal:
      "Teal"
    case .pink:
      "Pink"
    case .red:
      "Red"
    case .mint:
      "Mint"
    case .sky:
      "Sky"
    case .warm:
      "Warm"
    case .graphite:
      "Graphite"
    }
  }
}

/// The project mark itself. Small, and deliberately not the only thing naming
/// the project: the footer prints the name right beside it, so this is
/// decorative to VoiceOver rather than a second, colour-only label.
struct TaskBoardProjectColorMark: View {
  let color: TaskBoardProjectColor
  /// The text style the mark sits beside. A dot carries no baseline of its own,
  /// so it borrows this font's x-height to find the middle of the lowercase
  /// letters. A plain centre guide lands on the middle of the line box instead,
  /// which the descenders drag a quarter point below where the eye reads the
  /// row, and the dot then floats above the name it belongs to.
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
    return Circle()
      .fill(color.color)
      .overlay {
        // Keeps a light mark from vanishing on the card's own light fill.
        Circle().strokeBorder(HarnessMonitorTheme.ink.opacity(0.18), lineWidth: 0.5)
      }
      .frame(width: diameter, height: diameter)
      .alignmentGuide(.firstTextBaseline) { _ in baseline }
      .accessibilityHidden(true)
  }
}
