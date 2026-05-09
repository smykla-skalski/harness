import AppKit
import HarnessMonitorKit
import SwiftUI

struct ToastSnapBackSpring {
  let duration: TimeInterval
  let bounce: Double
  let initialVelocity: Double

  static let `default` = Self(duration: 0.25, bounce: 0.18, initialVelocity: 0)
}

struct HarnessMonitorFeedbackToastDetailRow: View {
  let row: ActionFeedbackDetailRow

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingSM) {
      Text("\(row.label):")
        .scaledFont(.caption2.weight(.semibold))
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .frame(width: 60, alignment: .leading)

      Text(row.value)
        .scaledFont(.caption.monospaced())
        .foregroundStyle(HarnessMonitorTheme.ink)
        .lineLimit(1)
        .truncationMode(.middle)
        .textSelection(.enabled)
        .help(row.value)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(Text("\(row.label): \(row.value)"))
  }
}

struct HarnessMonitorFeedbackToastPrimaryActionLabel: View {
  let action: ActionFeedbackAction
  let copied: Bool

  var body: some View {
    ZStack {
      HStack(spacing: HarnessMonitorTheme.spacingXS) {
        Image(systemName: action.systemImage)
        Text(action.title)
      }
      .hidden()
      .accessibilityHidden(true)

      HStack(spacing: HarnessMonitorTheme.spacingXS) {
        Image(systemName: copied ? "checkmark" : action.systemImage)
          .contentTransition(.symbolEffect(.replace))
        Text(copied ? "Copied" : action.title)
          .contentTransition(.opacity)
      }
    }
    .lineLimit(1)
    .scaledFont(.system(.caption, design: .rounded, weight: .semibold))
  }
}

private enum HarnessMonitorFeedbackToastPrimaryActionTiming {
  static let successHold: Duration = .milliseconds(700)
  static let dismissDuration: Duration = .milliseconds(220)
}

private enum HarnessMonitorFeedbackToastFocus {
  @MainActor
  static func clear() {
    let targetWindow = NSApp.mainWindow ?? NSApp.keyWindow ?? NSApp.windows.first
    targetWindow?.makeFirstResponder(nil)
  }
}

struct HarnessMonitorFeedbackToastPrimaryActionButton: View {
  let action: ActionFeedbackAction
  let copied: Bool
  let tint: Color
  let reduceMotion: Bool
  let onPress: () -> Void
  let onPendingDismissCancelled: () -> Void
  let onBeginDismiss: () -> Void
  let onFinishDismiss: () -> Void

  var body: some View {
    Button {
      onPress()
    } label: {
      HarnessMonitorFeedbackToastPrimaryActionLabel(action: action, copied: copied)
    }
    .harnessFlatActionButtonStyle(tint: copied ? HarnessMonitorTheme.success : tint)
    .accessibilityLabel(copied ? "Copied" : action.title)
    .accessibilityIdentifier(HarnessMonitorAccessibility.actionToastPrimaryButton)
    .task(id: copied) {
      guard copied else { return }
      try? await Task.sleep(for: HarnessMonitorFeedbackToastPrimaryActionTiming.successHold)
      guard !Task.isCancelled else {
        onPendingDismissCancelled()
        return
      }
      HarnessMonitorFeedbackToastFocus.clear()
      onBeginDismiss()
      if reduceMotion {
        onFinishDismiss()
        return
      }
      try? await Task.sleep(for: HarnessMonitorFeedbackToastPrimaryActionTiming.dismissDuration)
      guard !Task.isCancelled else { return }
      onFinishDismiss()
    }
  }
}
