import SwiftUI

/// Bottom-right disclosure listing the canvas keyboard shortcuts. Helps
/// keyboard users discover Cmd+A / C / V / D and the arrow-nudge ladder
/// without surfacing a heavy tutorial; the panel collapses by default so
/// the canvas stays uncluttered for the common case. Uses a `keyboard`
/// system image so the affordance reads as a shortcut surface, not a
/// generic settings tray.
struct PolicyCanvasShortcutsDisclosure: View {
  @State private var expanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Button {
        expanded.toggle()
      } label: {
        Label("Shortcuts", systemImage: "keyboard")
          .scaledFont(.caption.weight(.semibold))
          .foregroundStyle(.white.opacity(0.86))
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasShortcutsToggle)

      if expanded {
        VStack(alignment: .leading, spacing: 3) {
          shortcutRow(label: "Select all", chord: "Cmd A")
          shortcutRow(label: "Copy", chord: "Cmd C")
          shortcutRow(label: "Paste", chord: "Cmd V")
          shortcutRow(label: "Duplicate", chord: "Cmd D")
          shortcutRow(label: "Nudge", chord: "Arrows")
          shortcutRow(label: "Nudge x10", chord: "Shift Arrows")
          shortcutRow(label: "Snap to grid", chord: "Cmd Arrows")
        }
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(Color.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 8))
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .stroke(Color.white.opacity(0.12), lineWidth: 1)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasShortcuts)
  }

  private func shortcutRow(label: String, chord: String) -> some View {
    HStack(spacing: 8) {
      Text(label)
        .scaledFont(.caption2)
        .foregroundStyle(.white.opacity(0.86))
      Spacer(minLength: 12)
      Text(chord)
        .scaledFont(.caption2.monospaced().weight(.semibold))
        .foregroundStyle(.white.opacity(0.7))
    }
  }
}
