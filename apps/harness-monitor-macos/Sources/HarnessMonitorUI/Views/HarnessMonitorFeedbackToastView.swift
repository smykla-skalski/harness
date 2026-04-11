import HarnessMonitorKit
import SwiftUI

struct HarnessMonitorFeedbackToastView: View {
  let toast: ToastSlice

  var body: some View {
    VStack(spacing: HarnessMonitorTheme.spacingXS) {
      ForEach(toast.activeFeedback) { feedback in
        HarnessMonitorFeedbackToastRow(feedback: feedback, toast: toast)
          .transition(
            .asymmetric(
              insertion: .move(edge: .top).combined(with: .opacity),
              removal: .opacity.combined(with: .scale(scale: 0.95))
            )
          )
      }
    }
    .padding(.horizontal, HarnessMonitorTheme.spacingMD)
    .padding(.vertical, HarnessMonitorTheme.spacingSM)
    .frame(maxWidth: .infinity, alignment: .top)
    .animation(.spring(duration: 0.25, bounce: 0.18), value: toast.activeFeedback.map(\.id))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.actionToast)
  }
}

private struct HarnessMonitorFeedbackToastRow: View {
  let feedback: ActionFeedback
  let toast: ToastSlice
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingSM) {
      Image(systemName: iconName)
        .scaledFont(.system(.callout, design: .rounded, weight: .semibold))
        .foregroundStyle(tintColor)
        .accessibilityHidden(true)
      Text(feedback.message)
        .scaledFont(.system(.callout, design: .rounded, weight: .medium))
        .foregroundStyle(HarnessMonitorTheme.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
      Button {
        toast.dismiss(id: feedback.id)
      } label: {
        Image(systemName: "xmark.circle.fill")
          .scaledFont(.system(.callout, design: .rounded, weight: .semibold))
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
      .buttonStyle(.borderless)
      .accessibilityLabel("Dismiss feedback")
      .keyboardShortcut(.cancelAction)
    }
    .padding(.horizontal, HarnessMonitorTheme.spacingMD)
    .padding(.vertical, HarnessMonitorTheme.spacingSM)
    .background(toastBackground)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(announcementLabel)
    .accessibilityAddTraits(.isStaticText)
  }

  private var iconName: String {
    switch feedback.severity {
    case .success: "checkmark.circle.fill"
    case .failure: "exclamationmark.triangle.fill"
    }
  }

  private var tintColor: Color {
    switch feedback.severity {
    case .success: HarnessMonitorTheme.success
    case .failure: HarnessMonitorTheme.danger
    }
  }

  private var announcementLabel: String {
    switch feedback.severity {
    case .success: "Success. \(feedback.message)"
    case .failure: "Action failed. \(feedback.message)"
    }
  }

  @ViewBuilder
  private var toastBackground: some View {
    let shape = RoundedRectangle(
      cornerRadius: HarnessMonitorTheme.cornerRadiusMD,
      style: .continuous
    )
    if reduceTransparency {
      shape
        .fill(Color(nsColor: .windowBackgroundColor))
        .overlay { shape.stroke(tintColor.opacity(0.4), lineWidth: 1) }
    } else {
      shape
        .fill(.regularMaterial)
        .overlay { shape.stroke(tintColor.opacity(0.4), lineWidth: 1) }
    }
  }
}
