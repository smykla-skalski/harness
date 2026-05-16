import HarnessMonitorKit
import SwiftUI

struct TaskBoardActionButtonDescriptor {
  let title: String
  let systemImage: String
  let tint: Color?
  let prominent: Bool
  let accessibilityIdentifier: String
  let help: String
}

/// Shared capability surface for the Operations sub-cards (Sync, Dispatch).
/// Each card is its own `View` struct so a `@State` change inside one card
/// (Sync's status filter, Dispatch's dry-run toggle, etc.) does not
/// invalidate the others. Helpers that all cards rely on (action buttons,
/// summary rows, fonts) live on this protocol's extension so we share the
/// implementation without re-routing through the panel.
protocol TaskBoardOperationsHost {
  var store: HarnessMonitorStore { get }
  var metrics: TaskBoardOverviewMetrics { get }
  var captionFont: Font { get }
  var captionSemibold: Font { get }
}

extension TaskBoardOperationsHost {
  func controlRows<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    content()
  }

  func actionRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    HarnessMonitorGlassControlGroup(spacing: HarnessMonitorTheme.itemSpacing) {
      HarnessMonitorWrapLayout(
        spacing: HarnessMonitorTheme.itemSpacing,
        lineSpacing: HarnessMonitorTheme.itemSpacing
      ) {
        content()
      }
    }
  }

  func summaryPillRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: HarnessMonitorTheme.spacingXS) {
        content()
      }
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
        content()
      }
    }
  }

  func pickerField<SelectionValue: Hashable, Content: View>(
    _ title: String,
    selection: Binding<SelectionValue>,
    accessibilityIdentifier: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    Picker(title, selection: selection) {
      content()
    }
    .pickerStyle(.menu)
    .harnessNativeFormControl()
    .accessibilityIdentifier(accessibilityIdentifier)
  }

  func staticField(
    _ title: String,
    value: String,
    accessibilityIdentifier: String
  ) -> some View {
    LabeledContent(title) {
      Text(value)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
    .accessibilityValue(value)
  }

  func textField(
    _ title: String,
    text: Binding<String>,
    prompt: String,
    accessibilityIdentifier: String
  ) -> some View {
    LabeledContent(title) {
      TextField(prompt, text: text)
        .harnessNativeTextField()
        .accessibilityIdentifier(accessibilityIdentifier)
    }
  }

  func toggleField(
    _ title: String,
    isOn: Binding<Bool>,
    accessibilityIdentifier: String
  ) -> some View {
    Toggle(title, isOn: isOn)
      .accessibilityIdentifier(accessibilityIdentifier)
  }

  func actionButton(
    _ descriptor: TaskBoardActionButtonDescriptor,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Label(descriptor.title, systemImage: descriptor.systemImage)
        .lineLimit(1)
    }
    .frame(minHeight: metrics.controlMinHeight)
    .harnessActionButtonStyle(
      variant: descriptor.prominent ? .prominent : .bordered,
      tint: descriptor.tint
    )
    .controlSize(HarnessMonitorControlMetrics.compactControlSize)
    .disabled(store.isDaemonActionInFlight)
    .help(descriptor.help)
    .accessibilityIdentifier(descriptor.accessibilityIdentifier)
  }

  func providerSummaryRow(_ provider: TaskBoardProviderSyncSummary) -> some View {
    keyedSummaryRow(
      title: provider.provider.title,
      subtitle:
        "Linked \(provider.linked) · Pushable \(provider.pushable) · Blocked \(provider.blocked)"
    )
  }

  func operationSummaryRow(_ operation: TaskBoardExternalSyncOperation) -> some View {
    keyedSummaryRow(
      title:
        "\(operation.provider.title) \(operation.action.rawValue.capitalized) · "
        + "\(operation.boardItemId ?? operation.externalId ?? "Unlinked")",
      subtitle:
        operation.applied ? "Applied" : (operation.dryRun ? "Preview only" : "Pending apply")
    )
  }

  func appliedSummaryRow(_ applied: TaskBoardDispatchAppliedTask) -> some View {
    keyedSummaryRow(
      title: applied.item.title,
      subtitle: "\(applied.sessionId) · \(applied.workItemId)"
    )
  }

  func planSummaryRow(_ plan: TaskBoardDispatchPlan) -> some View {
    keyedSummaryRow(
      title: plan.task.title,
      subtitle: dispatchReadinessSubtitle(for: plan)
    )
  }

  func keyedSummaryRow(title: String, subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(captionSemibold)
        .lineLimit(1)
      Text(subtitle)
        .font(captionFont)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .lineLimit(2)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 2)
    .accessibilityElement(children: .combine)
  }

  func placeholderText(_ text: String) -> some View {
    Text(text)
      .font(captionFont)
      .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  func dispatchReadinessSubtitle(for plan: TaskBoardDispatchPlan) -> String {
    if plan.readiness.isReady {
      return "\(plan.worker.mode.title) · \(plan.session.kind.capitalized)"
    }
    guard let reason = plan.readiness.reason else {
      return "Blocked"
    }
    if let approvalReason = reason.reason {
      return approvalReason.rawValue.replacingOccurrences(of: "_", with: " ")
    }
    return reason.kind.replacingOccurrences(of: "_", with: " ")
  }
}

struct TaskBoardOperationsCard<Content: View>: View {
  let title: String
  let systemImage: String
  let metrics: TaskBoardOverviewMetrics
  let content: Content

  @Environment(\.fontScale)
  private var fontScale

  init(
    title: String,
    systemImage: String,
    metrics: TaskBoardOverviewMetrics,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.systemImage = systemImage
    self.metrics = metrics
    self.content = content()
  }

  // Lightweight VStack chrome (no Form / .formStyle(.grouped) machinery).
  // See commit 65cac5448 for the trace-driven rationale.
  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text(title)
        .harnessNativeFormSectionHeader()

      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        content
      }
      .padding(HarnessMonitorTheme.spacingMD)
      .background(
        RoundedRectangle(
          cornerRadius: HarnessMonitorTheme.cornerRadiusMD,
          style: .continuous
        )
        .fill(.background.opacity(0.5))
      )
      .overlay {
        RoundedRectangle(
          cornerRadius: HarnessMonitorTheme.cornerRadiusMD,
          style: .continuous
        )
        .strokeBorder(HarnessMonitorTheme.controlBorder.opacity(0.4), lineWidth: 0.5)
      }
    }
    .font(HarnessMonitorTextSize.scaledFont(.body, by: fontScale))
    .frame(
      maxWidth: .infinity,
      minHeight: metrics.managementPanelMinHeight,
      alignment: .leading
    )
  }
}

extension String {
  var taskBoardNilIfEmpty: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
