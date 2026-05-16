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

extension TaskBoardOperationsPanel {
  func controlRows<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingMD) {
        content()
      }
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        content()
      }
    }
  }

  func actionRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: HarnessMonitorTheme.spacingSM) {
        content()
      }
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
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
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Text(title)
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      Picker(title, selection: selection) {
        content()
      }
      .pickerStyle(.menu)
      .labelsHidden()
      .harnessNativeFormControl()
      .accessibilityLabel(title)
      .accessibilityIdentifier(accessibilityIdentifier)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  func textField(
    _ title: String,
    text: Binding<String>,
    prompt: String,
    accessibilityIdentifier: String
  ) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Text(title)
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      TextField(prompt, text: text)
        .textFieldStyle(.roundedBorder)
        .harnessNativeTextField()
        .accessibilityLabel(title)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  func toggleField(
    _ title: String,
    isOn: Binding<Bool>,
    accessibilityIdentifier: String
  ) -> some View {
    Toggle(isOn: isOn) {
      Text(title)
        .scaledFont(.caption.weight(.semibold))
    }
    .harnessNativeFormControl()
    .accessibilityIdentifier(accessibilityIdentifier)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  func actionButton(
    _ descriptor: TaskBoardActionButtonDescriptor,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Label(descriptor.title, systemImage: descriptor.systemImage)
        .scaledFont(.caption.weight(.semibold))
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
    let reference = operation.boardItemId ?? operation.externalId ?? "Unlinked"
    keyedSummaryRow(
      title: "\(operation.provider.title) \(operation.action.rawValue.capitalized) · \(reference)",
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
        .scaledFont(.caption.weight(.semibold))
        .lineLimit(1)
      Text(subtitle)
        .scaledFont(.caption)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .lineLimit(2)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 2)
    .accessibilityElement(children: .combine)
  }

  func inventoryBlock<Content: View>(
    title: String,
    systemImage: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Label(title, systemImage: systemImage)
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .accessibilityAddTraits(.isHeader)
      content()
    }
  }

  func placeholderText(_ text: String) -> some View {
    Text(text)
      .scaledFont(.caption)
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

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Label(title, systemImage: systemImage)
        .scaledFont(.subheadline.weight(.semibold))
        .accessibilityAddTraits(.isHeader)
      content
    }
    .padding(HarnessMonitorTheme.spacingMD)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      .background.opacity(0.56),
      in: .rect(cornerRadius: metrics.managementPanelCornerRadius)
    )
    .overlay(
      RoundedRectangle(cornerRadius: metrics.managementPanelCornerRadius)
        .stroke(HarnessMonitorTheme.controlBorder.opacity(0.62), lineWidth: 1)
    )
  }
}

extension String {
  var taskBoardNilIfEmpty: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
