import SwiftUI

extension OpenAnythingPaletteView {
  /// A corpus rebuild can lag the first present by a frame or two. Surfacing a
  /// tiny "Loading..." instead of "Start typing" keeps the user from thinking
  /// the palette is empty.
  var skeletonState: some View {
    HStack(spacing: 8) {
      ProgressView()
        .controlSize(.small)
      Text("Loading...")
        .scaledFont(.callout)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 32)
    .accessibilityIdentifier(HarnessMonitorAccessibility.openAnythingEmptyState)
  }

  /// When there's only one hit on screen, prompt the user to press Return
  /// rather than reach for the mouse. The hint sits below the results list so
  /// it never collides with the visual selection rectangle.
  var singleResultHint: some View {
    HStack(spacing: 6) {
      Text("Press")
      Text("⏎")
        .scaledFont(.caption.monospaced())
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(
          RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(.secondary.opacity(0.12))
        )
      Text("to open")
    }
    .scaledFont(.caption)
    .foregroundStyle(HarnessMonitorTheme.tertiaryInk)
    .padding(.horizontal, 14)
    .padding(.vertical, 6)
  }

  func emptyState(text: String) -> some View {
    Text(text)
      .scaledFont(.callout)
      .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      .multilineTextAlignment(.center)
      .frame(maxWidth: .infinity)
      .padding(.horizontal, 24)
      .padding(.vertical, 32)
      .accessibilityIdentifier(HarnessMonitorAccessibility.openAnythingEmptyState)
  }
}
