import HarnessMonitorKit
import SwiftUI

struct HarnessMonitorFeedbackToastView: View {
  let toast: ToastSlice

  var body: some View {
    HarnessMonitorGlassControlGroup(spacing: HarnessMonitorTheme.spacingSM) {
      VStack(alignment: .trailing, spacing: HarnessMonitorTheme.spacingXS) {
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
    }
    .frame(maxWidth: 420, alignment: .trailing)
    .animation(.spring(duration: 0.25, bounce: 0.18), value: toast.activeFeedback.map(\.id))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.actionToast)
    .accessibilityFrameMarker(HarnessMonitorAccessibility.actionToastFrame)
    .accessibilityTestProbe(
      HarnessMonitorAccessibility.actionToast,
      value: "count=\(toast.activeFeedback.count)"
    )
  }
}

private struct HarnessMonitorFeedbackToastRow: View {
  let feedback: ActionFeedback
  let toast: ToastSlice

  var body: some View {
    HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingMD) {
      HarnessMonitorFeedbackToastStrip(tint: tintColor)
      Text(feedback.message)
        .scaledFont(.system(.callout, design: .rounded, weight: .medium))
        .foregroundStyle(HarnessMonitorTheme.ink)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
      Button {
        toast.dismiss(id: feedback.id)
      } label: {
        Image(systemName: "xmark")
          .scaledFont(.system(.footnote, design: .rounded, weight: .bold))
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .frame(width: 28, height: 28)
          .contentShape(.circle)
          .modifier(HarnessMonitorFeedbackToastDismissGlass())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Dismiss feedback")
      .accessibilityIdentifier(HarnessMonitorAccessibility.actionToastCloseButton)
      .keyboardShortcut(.cancelAction)
    }
    .padding(.horizontal, HarnessMonitorTheme.spacingMD)
    .padding(.vertical, HarnessMonitorTheme.spacingSM)
    .harnessFloatingControlGlass(
      cornerRadius: HarnessMonitorTheme.cornerRadiusLG,
      tint: tintColor
    )
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
}

private struct HarnessMonitorFeedbackToastStrip: View {
  let tint: Color
  @ScaledMetric(relativeTo: .body) private var stripHeight = 18.0
  @ScaledMetric(relativeTo: .body) private var stripWidth = 6.0

  var body: some View {
    RoundedRectangle(cornerRadius: stripWidth / 2, style: .continuous)
      .fill(tint.opacity(0.75))
      .frame(width: stripWidth, height: stripHeight)
      .accessibilityHidden(true)
  }
}

private struct HarnessMonitorFeedbackToastDismissGlass: ViewModifier {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast

  private var fallbackFillOpacity: Double {
    if reduceTransparency {
      return colorSchemeContrast == .increased ? 0.24 : 0.16
    }
    return colorSchemeContrast == .increased ? 0.12 : 0.08
  }

  private var fallbackStrokeOpacity: Double {
    colorSchemeContrast == .increased ? 0.28 : 0.18
  }

  private var glassTintOpacity: Double {
    colorSchemeContrast == .increased ? 0.16 : 0.1
  }

  func body(content: Content) -> some View {
    if reduceTransparency {
      content
        .background {
          Circle()
            .fill(HarnessMonitorTheme.ink.opacity(fallbackFillOpacity))
        }
        .overlay {
          Circle()
            .strokeBorder(
              HarnessMonitorTheme.ink.opacity(fallbackStrokeOpacity),
              lineWidth: colorSchemeContrast == .increased ? 1.5 : 1
            )
        }
    } else {
      content
        .glassEffect(
          .regular.tint(HarnessMonitorTheme.ink.opacity(glassTintOpacity)).interactive(),
          in: .circle
        )
    }
  }
}
