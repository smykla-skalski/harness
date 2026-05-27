import SwiftUI

enum PolicyCanvasShortcutsDefaults {
  static let isVisibleKey = "policyCanvas.shortcuts.isVisible"
  static let isVisibleDefault = false
}

/// Bottom-right disclosure listing the canvas keyboard shortcuts. Helps
/// keyboard users discover Cmd+A / C / V / D and the arrow-nudge ladder
/// without surfacing a heavy tutorial; the panel collapses by default so
/// the canvas stays uncluttered for the common case. Uses a `keyboard`
/// system image so the affordance reads as a shortcut surface, not a
/// generic settings tray.
struct PolicyCanvasShortcutsDisclosure: View {
  @AppStorage(PolicyCanvasShortcutsDefaults.isVisibleKey)
  private var isVisible = PolicyCanvasShortcutsDefaults.isVisibleDefault
  @State private var expanded = false

  var body: some View {
    if isVisible {
      VStack(alignment: .leading, spacing: 6) {
        Button {
          expanded.toggle()
        } label: {
          Label("Shortcuts", systemImage: "keyboard")
            .scaledFont(.caption.weight(.semibold))
            .foregroundStyle(PolicyCanvasVisualStyle.secondaryText)
        }
        .harnessPlainButtonStyle()
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
      .background(
        PolicyCanvasVisualStyle.panelBackground.opacity(0.94),
        in: RoundedRectangle(cornerRadius: HarnessMonitorTheme.pillCornerRadius)
      )
      .overlay {
        RoundedRectangle(cornerRadius: HarnessMonitorTheme.pillCornerRadius)
          .stroke(PolicyCanvasVisualStyle.border, lineWidth: 1)
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasShortcuts)
    }
  }

  private func shortcutRow(label: String, chord: String) -> some View {
    HStack(spacing: 8) {
      Text(label)
        .scaledFont(.caption2)
        .foregroundStyle(PolicyCanvasVisualStyle.secondaryText)
      Spacer(minLength: 12)
      Text(chord)
        .scaledFont(.caption2.monospaced().weight(.semibold))
        .foregroundStyle(PolicyCanvasVisualStyle.tertiaryText)
    }
  }
}
