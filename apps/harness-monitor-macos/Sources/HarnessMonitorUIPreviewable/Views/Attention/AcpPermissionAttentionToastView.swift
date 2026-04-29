import HarnessMonitorKit
import SwiftUI

public struct AcpPermissionAttentionToastView: View {
  let attention: AcpPermissionAttentionEvent
  let openDecisions: @MainActor @Sendable () -> Void
  let dismiss: @MainActor @Sendable () -> Void

  @ScaledMetric(relativeTo: .callout)
  private var dismissButtonSize: CGFloat = 28

  private var requestSummary: String {
    if attention.requestCount == 1 {
      return "1 permission request is waiting."
    }
    return "\(attention.requestCount) permission requests are waiting."
  }

  private var stateMarkerText: String {
    [
      "batch=\(attention.batchID)",
      "decision=\(attention.decisionID)",
      "agent=\(attention.agentID)",
    ].joined(separator: " ")
  }

  public init(
    attention: AcpPermissionAttentionEvent,
    openDecisions: @escaping @MainActor @Sendable () -> Void,
    dismiss: @escaping @MainActor @Sendable () -> Void
  ) {
    self.attention = attention
    self.openDecisions = openDecisions
    self.dismiss = dismiss
  }

  public var body: some View {
    HarnessMonitorGlassControlGroup(spacing: HarnessMonitorTheme.spacingSM) {
      HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingMD) {
        Image(systemName: "hand.raised.fill")
          .scaledFont(.system(.body, design: .rounded, weight: .semibold))
          .foregroundStyle(HarnessMonitorTheme.caution)
          .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
          Text(attention.toastMessage)
            .scaledFont(.system(.callout, design: .rounded, weight: .semibold))
            .foregroundStyle(HarnessMonitorTheme.ink)
            .multilineTextAlignment(.leading)
          Text(requestSummary)
            .scaledFont(.caption)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        Button("Open Decisions") {
          openDecisions()
        }
        .harnessActionButtonStyle(variant: .prominent)
        .controlSize(HarnessMonitorControlMetrics.compactControlSize)
        .contentShape(Rectangle())
        .accessibilityIdentifier(HarnessMonitorAccessibility.acpPermissionToastActionButton)
        .accessibilityFrameMarker("\(HarnessMonitorAccessibility.acpPermissionToastActionButton).frame")

        Button {
          dismiss()
        } label: {
          Image(systemName: "xmark")
            .scaledFont(.system(.footnote, design: .rounded, weight: .bold))
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .frame(width: dismissButtonSize, height: dismissButtonSize)
            .contentShape(.circle)
            .harnessToastDismissGlass()
        }
        .harnessDismissButtonStyle()
        .accessibilityLabel("Dismiss permission alert")
        .accessibilityIdentifier(HarnessMonitorAccessibility.acpPermissionToastCloseButton)
      }
      .padding(.horizontal, HarnessMonitorTheme.spacingMD)
      .padding(.vertical, HarnessMonitorTheme.spacingSM)
      .harnessFeedbackToastGlass(
        cornerRadius: HarnessMonitorTheme.cornerRadiusLG,
        tint: HarnessMonitorTheme.caution
      )
    }
    .frame(maxWidth: 520, alignment: .trailing)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.acpPermissionToast)
    .accessibilityFrameMarker(HarnessMonitorAccessibility.acpPermissionToastFrame)
    .overlay {
      AccessibilityTextMarker(
        identifier: HarnessMonitorAccessibility.acpPermissionToastState,
        text: stateMarkerText
      )
    }
    .onAppear {
      AccessibilityNotification.Announcement(attention.toastMessage).post()
    }
    .onChange(of: attention.batchID) { _, _ in
      AccessibilityNotification.Announcement(attention.toastMessage).post()
    }
  }
}
