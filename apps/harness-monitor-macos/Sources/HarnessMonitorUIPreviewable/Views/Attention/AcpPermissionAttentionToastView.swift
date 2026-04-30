import AppKit
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

  private var announcementMessage: String {
    "\(attention.toastMessage). \(requestSummary)"
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
      .padding(.leading, HarnessMonitorTheme.spacingMD)
      .padding(.trailing, HarnessMonitorTheme.spacingMD + 10)
      .padding(.vertical, HarnessMonitorTheme.spacingSM)
      .background {
        AcpPermissionToastPointerShield(cornerRadius: HarnessMonitorTheme.cornerRadiusLG)
          .accessibilityHidden(true)
      }
      .harnessFeedbackToastGlass(
        cornerRadius: HarnessMonitorTheme.cornerRadiusLG,
        tint: HarnessMonitorTheme.caution
      )
    }
    // Keep a stable, wide toast footprint so overlap with header actions includes
    // non-control surface area that the shield can absorb.
    .frame(width: 620, alignment: .trailing)
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
      guard path.contains(point) else {
        return nil
      }

      // Let interactive subviews (buttons) win first; otherwise absorb taps
      // on the remaining toast body so underlying UI cannot be activated.
      return super.hitTest(point) ?? self
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func rightMouseUp(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func otherMouseUp(with event: NSEvent) {}
  }
}
