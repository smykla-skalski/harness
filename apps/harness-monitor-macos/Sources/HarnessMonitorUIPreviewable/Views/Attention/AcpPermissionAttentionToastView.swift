import AppKit
import HarnessMonitorKit
import SwiftUI

public struct AcpPermissionAttentionToastView: View {
  let attention: AcpPermissionAttentionEvent
  let openDecisions: @MainActor @Sendable () -> Void
  let dismiss: @MainActor @Sendable () -> Void

  @ScaledMetric(relativeTo: .callout)
  private var dismissButtonSize: CGFloat = 30

  private var displayMessage: String {
    "Permission requested by \(attention.agentName)"
  }

  private var announcementMessage: String {
    "\(displayMessage). \(requestSummary)"
  }

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

  private var accessibilityMarkerText: String {
    [
      "live-region=assertive",
      "batch=\(attention.batchID)",
      "decision=\(attention.decisionID)",
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
    let toastShape = RoundedRectangle(
      cornerRadius: HarnessMonitorTheme.cornerRadiusLG,
      style: .continuous
    )

    HarnessMonitorGlassControlGroup(spacing: HarnessMonitorTheme.spacingSM) {
      HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingMD) {
        Image(systemName: "hand.raised.fill")
          .scaledFont(.system(.callout, design: .rounded, weight: .semibold))
          .foregroundStyle(HarnessMonitorTheme.caution)
          .accessibilityHidden(true)
          .frame(width: 18, alignment: .center)

        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
          Text(displayMessage)
            .scaledFont(.system(.callout, design: .rounded, weight: .semibold))
            .foregroundStyle(HarnessMonitorTheme.ink)
            .lineLimit(2)
            .multilineTextAlignment(.leading)

          Text(requestSummary)
            .scaledFont(.caption)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .lineLimit(1)
        }
        .frame(maxWidth: 360, alignment: .leading)
        .layoutPriority(1)

        Button {
          openDecisions()
        } label: {
          Label("Open Decisions", systemImage: "arrow.up.right.square")
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
            .scaledFont(.system(.caption, design: .rounded, weight: .semibold))
        }
        .harnessFlatActionButtonStyle(tint: HarnessMonitorTheme.ink)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel("Open Decisions")
        .accessibilityIdentifier(HarnessMonitorAccessibility.acpPermissionToastActionButton)
        .accessibilityFrameMarker(
          "\(HarnessMonitorAccessibility.acpPermissionToastActionButton).frame"
        )

        Button {
          dismiss()
        } label: {
          Image(systemName: "xmark")
            .scaledFont(.system(.caption, design: .rounded, weight: .bold))
            .foregroundStyle(HarnessMonitorTheme.secondaryInk.opacity(0.82))
            .frame(width: dismissButtonSize, height: dismissButtonSize)
            .harnessToastDismissGlass()
            .contentShape(Circle())
        }
        .harnessDismissButtonStyle()
        .accessibilityLabel("Dismiss permission alert")
        .accessibilityIdentifier(HarnessMonitorAccessibility.acpPermissionToastCloseButton)
      }
      .fixedSize(horizontal: true, vertical: false)
      .padding(.horizontal, HarnessMonitorTheme.spacingLG)
      .padding(.vertical, HarnessMonitorTheme.spacingSM)
      .background {
        AcpPermissionToastPointerShield(cornerRadius: HarnessMonitorTheme.cornerRadiusLG)
          .accessibilityHidden(true)
      }
      .harnessFeedbackToastGlass(
        cornerRadius: HarnessMonitorTheme.cornerRadiusLG,
        tint: HarnessMonitorTheme.caution
      )
      .contentShape(toastShape)
    }
    .frame(maxWidth: 680, alignment: .trailing)
    .accessibilityElement(children: .contain)
    .accessibilityLiveRegion(.assertive)
    .accessibilityIdentifier(HarnessMonitorAccessibility.acpPermissionToast)
    .accessibilityFrameMarker(HarnessMonitorAccessibility.acpPermissionToastFrame)
    .overlay {
      ZStack {
        AccessibilityTextMarker(
          identifier: HarnessMonitorAccessibility.acpPermissionToastState,
          text: stateMarkerText
        )
        AccessibilityTextMarker(
          identifier: HarnessMonitorAccessibility.acpPermissionToastAccessibilityState,
          text: accessibilityMarkerText
        )
      }
    }
    .onAppear {
      AccessibilityNotification.Announcement(announcementMessage).post()
    }
    .onChange(of: attention.batchID) { _, _ in
      AccessibilityNotification.Announcement(announcementMessage).post()
    }
  }
}

private struct AcpPermissionToastPointerShield: NSViewRepresentable {
  let cornerRadius: CGFloat

  func makeNSView(context: Context) -> ShieldView {
    let view = ShieldView()
    view.cornerRadius = cornerRadius
    view.setAccessibilityElement(false)
    return view
  }

  func updateNSView(_ nsView: ShieldView, context: Context) {
    nsView.cornerRadius = cornerRadius
  }

  final class ShieldView: NSView {
    var cornerRadius: CGFloat = 0

    override var isOpaque: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
      true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
      guard !isHidden, alphaValue > 0, bounds.contains(point) else {
        return nil
      }

      let path = NSBezierPath(
        roundedRect: bounds,
        xRadius: cornerRadius,
        yRadius: cornerRadius
      )
      return path.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func rightMouseUp(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func otherMouseUp(with event: NSEvent) {}
  }
}

#Preview("ACP Permission Attention Toast") {
  ZStack(alignment: .topTrailing) {
    Color.black.opacity(0.86)
    AcpPermissionAttentionToastView(
      attention: AcpPermissionAttentionEvent(
        batchID: "preview-acp-permission-1",
        decisionID: "acp-permission:preview-acp-permission-1",
        agentID: "worker-codex",
        agentName: "worker-codex",
        requestCount: 2,
        createdAt: "2026-04-29T19:00:00Z"
      ),
      openDecisions: {},
      dismiss: {}
    )
    .padding(.top, HarnessMonitorTheme.spacingSM)
    .padding(.trailing, HarnessMonitorTheme.spacingLG)
  }
  .frame(width: 1064, height: 144)
}
