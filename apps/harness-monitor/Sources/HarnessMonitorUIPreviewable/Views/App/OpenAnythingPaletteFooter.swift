import SwiftUI

/// Keyboard-hints strip rendered at the bottom of the Open Anything palette.
/// Communicates the four navigation chords (Navigate, Open, Section jump,
/// Cancel) so first-time users don't have to discover them through trial.
struct OpenAnythingPaletteFooter: View {
  let recordCount: Int

  var body: some View {
    HStack(spacing: 14) {
      chord(symbol: "↑↓", label: "Navigate")
      chord(symbol: "⏎", label: "Open")
      chord(symbol: "⌘1-8", label: "Section")
      Spacer(minLength: 8)
      chord(symbol: "⎋", label: "Cancel")
      if recordCount > 0 {
        Text("·")
          .foregroundStyle(HarnessMonitorTheme.tertiaryInk)
        Text("\(recordCount) items")
          .scaledFont(.caption2)
          .foregroundStyle(HarnessMonitorTheme.tertiaryInk)
      }
    }
    .scaledFont(.callout.monospaced())
    .foregroundStyle(HarnessMonitorTheme.tertiaryInk)
    .padding(.horizontal, OpenAnythingPaletteConstants.footerHorizontalPadding)
    .padding(.vertical, OpenAnythingPaletteConstants.footerVerticalPadding)
    .frame(maxWidth: .infinity)
  }

  private func chord(symbol: String, label: String) -> some View {
    HStack(spacing: 6) {
      Text(symbol)
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(
          RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(.secondary.opacity(0.12))
        )
        .accessibilityHidden(true)
      Text(label)
        .scaledFont(.caption)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(symbol) to \(label)")
  }
}
