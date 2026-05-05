import AppKit
import HarnessMonitorKit
import SwiftUI

public struct HarnessMonitorFeedbackToastView: View {
  public let toast: ToastSlice
  private let detailsInitiallyExpanded: Bool

  public init(toast: ToastSlice, detailsInitiallyExpanded: Bool = false) {
    self.toast = toast
    self.detailsInitiallyExpanded = detailsInitiallyExpanded
  }

  public var body: some View {
    HarnessMonitorGlassControlGroup(spacing: HarnessMonitorTheme.spacingSM) {
      VStack(alignment: .trailing, spacing: HarnessMonitorTheme.spacingXS) {
        ForEach(toast.activeFeedback) { feedback in
          HarnessMonitorFeedbackToastRow(
            feedback: feedback,
            toast: toast,
            detailsInitiallyExpanded: detailsInitiallyExpanded
          )
          .transition(
            .asymmetric(
              insertion: .move(edge: .top).combined(with: .opacity),
              removal: .opacity.combined(with: .scale(scale: 0.95))
            )
          )
        }
      }
    }
    .frame(maxWidth: 540, alignment: .trailing)
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

private struct HarnessMonitorFeedbackToastDetailRow: View {
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

private struct HarnessMonitorFeedbackToastRow: View {
  let feedback: ActionFeedback
  let toast: ToastSlice
  @State private var showsDetails: Bool
  @State private var copiedPrimaryAction = false
  @ScaledMetric(relativeTo: .callout)
  private var dismissButtonSize: CGFloat = 28

  init(feedback: ActionFeedback, toast: ToastSlice, detailsInitiallyExpanded: Bool) {
    self.feedback = feedback
    self.toast = toast
    _showsDetails = State(initialValue: detailsInitiallyExpanded)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingMD) {
        content
        Button {
          toast.dismiss(id: feedback.id)
        } label: {
          Image(systemName: "xmark")
            .scaledFont(.system(.footnote, design: .rounded, weight: .bold))
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .frame(width: dismissButtonSize, height: dismissButtonSize)
            .contentShape(.circle)
            .harnessToastDismissGlass()
        }
        .harnessDismissButtonStyle()
        .accessibilityLabel("Dismiss feedback")
        .accessibilityIdentifier(HarnessMonitorAccessibility.actionToastCloseButton)
        .keyboardShortcut(.cancelAction)
      }

      if showsDetails, let details = feedback.details {
        detailsView(details)
      }
    }
    .padding(.horizontal, HarnessMonitorTheme.spacingMD)
    .padding(.vertical, HarnessMonitorTheme.spacingSM)
    .background(alignment: .bottomTrailing) {
      backgroundGlyph
    }
    .clipShape(toastShape)
    .harnessFeedbackToastGlass(
      cornerRadius: HarnessMonitorTheme.cornerRadiusLG,
      tint: tintColor
    )
    .accessibilityIdentifier(
      feedback.accessibilityIdentifier ?? HarnessMonitorAccessibility.actionToast
    )
  }

  private var toastShape: some Shape {
    RoundedRectangle(
      cornerRadius: HarnessMonitorTheme.cornerRadiusLG,
      style: .continuous
    )
  }

  @ViewBuilder private var backgroundGlyph: some View {
    if feedback.severity == .warning {
      Image(systemName: iconName)
        .font(.system(size: backgroundGlyphSize, weight: .black, design: .rounded))
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(tintColor.opacity(0.52))
        .rotationEffect(.degrees(-8))
        .offset(x: 48, y: backgroundGlyphOffsetY)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
  }

  private var backgroundGlyphSize: CGFloat {
    showsDetails ? 190 : 168
  }

  private var backgroundGlyphOffsetY: CGFloat {
    showsDetails ? 42 : 62
  }

  private var content: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      titleAndMessage
      if hasActions {
        actionRow
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(feedback.announcementText)
  }

  @ViewBuilder private var titleAndMessage: some View {
    if let title = feedback.title {
      VStack(alignment: .leading, spacing: 2) {
        HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingSM) {
          Text(title)
            .scaledFont(.system(.callout, design: .rounded, weight: .semibold))
            .foregroundStyle(HarnessMonitorTheme.ink)
          repeatBadge
        }
        Text(feedback.message)
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
      .multilineTextAlignment(.leading)
    } else {
      HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingSM) {
        Text(feedback.message)
          .scaledFont(.system(.callout, design: .rounded, weight: .medium))
          .foregroundStyle(HarnessMonitorTheme.ink)
          .multilineTextAlignment(.leading)
          .frame(maxWidth: .infinity, alignment: .leading)
        repeatBadge
      }
    }
  }

  @ViewBuilder private var repeatBadge: some View {
    if feedback.repeatCount > 1 {
      Text("\(feedback.repeatCount)")
        .scaledFont(.caption.weight(.semibold))
        .monospacedDigit()
        .foregroundStyle(HarnessMonitorTheme.ink)
        .padding(.horizontal, HarnessMonitorTheme.spacingSM)
        .padding(.vertical, HarnessMonitorTheme.spacingXS)
        .background {
          Capsule(style: .continuous)
            .fill(tintColor.opacity(0.16))
        }
        .accessibilityLabel("Repeated \(feedback.repeatCount) times")
    }
  }

  private var actionRow: some View {
    HarnessMonitorWrapLayout(
      spacing: HarnessMonitorTheme.spacingSM,
      lineSpacing: HarnessMonitorTheme.spacingXS
    ) {
      if let action = feedback.primaryAction {
        Button {
          perform(action)
        } label: {
          Label(
            copiedPrimaryAction ? action.successAnnouncement : action.title,
            systemImage: copiedPrimaryAction ? "checkmark" : action.systemImage
          )
          .labelStyle(.titleAndIcon)
          .lineLimit(1)
          .scaledFont(.system(.caption, design: .rounded, weight: .semibold))
        }
        .harnessFlatActionButtonStyle(tint: tintColor)
        .accessibilityIdentifier(HarnessMonitorAccessibility.actionToastPrimaryButton)
      }

      if let details = feedback.details {
        Button {
          showsDetails.toggle()
        } label: {
          Label(
            detailsDisclosureTitle(details),
            systemImage: showsDetails ? "chevron.up" : "chevron.down"
          )
          .labelStyle(.titleAndIcon)
          .lineLimit(1)
          .scaledFont(.system(.caption, design: .rounded, weight: .semibold))
        }
        .harnessFlatActionButtonStyle(tint: HarnessMonitorTheme.secondaryInk)
        .accessibilityIdentifier(HarnessMonitorAccessibility.actionToastDetailsButton)
      }

      if feedback.severity == .undoable, toast.hasUndoAction(id: feedback.id) {
        Button("Undo") {
          toast.invokeUndo(id: feedback.id)
        }
        .scaledFont(.system(.caption, design: .rounded, weight: .semibold))
        .harnessFlatActionButtonStyle(tint: HarnessMonitorTheme.accent)
        .accessibilityLabel("Undo")
        .accessibilityIdentifier(HarnessMonitorAccessibility.actionToastUndoButton)
      }
    }
    .padding(.top, 2)
  }

  private func detailsView(_ details: ActionFeedbackDetails) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Divider()
      if let summary = details.summary {
        Text(summary)
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
      ForEach(details.rows, id: \.self) { row in
        HarnessMonitorFeedbackToastDetailRow(row: row)
      }
      if let command = details.command {
        CopyableCommandBox(
          command: command,
          accessibilityIdentifier: HarnessMonitorAccessibility.actionToastCommandCopyButton
        )
      }
    }
    .padding(.top, HarnessMonitorTheme.spacingXS)
  }

  private var hasActions: Bool {
    feedback.primaryAction != nil
      || feedback.details != nil
      || (feedback.severity == .undoable && toast.hasUndoAction(id: feedback.id))
  }

  private func perform(_ action: ActionFeedbackAction) {
    switch action.kind {
    case .copy(let text):
      HarnessMonitorClipboard.copy(text)
      copiedPrimaryAction = true
      AccessibilityNotification.Announcement(action.successAnnouncement).post()
    }
  }

  private func detailsDisclosureTitle(_ details: ActionFeedbackDetails) -> String {
    let verb = showsDetails ? "Hide" : "Show"
    return "\(verb) \(details.disclosureLabel)"
  }

  private var iconName: String {
    switch feedback.severity {
    case .success: "checkmark.circle.fill"
    case .warning: "exclamationmark.triangle.fill"
    case .failure: "xmark.octagon.fill"
    case .undoable: "arrow.uturn.backward.circle.fill"
    }
  }

  private var tintColor: Color {
    switch feedback.severity {
    case .success: HarnessMonitorTheme.success
    case .warning: HarnessMonitorTheme.caution
    case .failure: HarnessMonitorTheme.danger
    case .undoable: HarnessMonitorTheme.accent
    }
  }
}
