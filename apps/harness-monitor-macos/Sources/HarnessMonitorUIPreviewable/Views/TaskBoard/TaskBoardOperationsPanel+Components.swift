import HarnessMonitorKit
import SwiftUI

extension EnvironmentValues {
  @Entry var taskBoardOperationsRowLabelFont: Font = .body
  @Entry var taskBoardOperationsRowLabelWidth: CGFloat = 112
}

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
///
/// `@MainActor` so the helpers can call MainActor-isolated SwiftUI APIs
/// (`harnessNativeFormControl`, `harnessNativeTextField`, glass control
/// group, etc.) without a hop - every conformer is a `View`, which is
/// already MainActor-isolated under Swift 6.2 strict concurrency.
@MainActor
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

  func actionRow<Content: View>(
    showsSeparator: Bool = true,
    @ViewBuilder content: () -> Content
  ) -> some View {
    TaskBoardOperationsFormRow("Actions", showsSeparator: showsSeparator) {
      HarnessMonitorGlassControlGroup(spacing: HarnessMonitorTheme.itemSpacing) {
        HStack(spacing: HarnessMonitorTheme.itemSpacing) {
          content()
        }
        .fixedSize(horizontal: true, vertical: false)
      }
      .frame(maxWidth: .infinity, alignment: .trailing)
    }
  }

  func summaryPillRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    // One-tree wrap-flow layout. The previous `ViewThatFits` built both an
    // HStack and a VStack candidate subtree on every body update; in the
    // operations cards this fanned out across multiple pill rows, so a
    // single live-resize tick rebuilt the AttributeGraph for every pill
    // twice. `HarnessMonitorWrapLayout` measures the same subviews once
    // and flows them onto rows as width permits.
    HarnessMonitorWrapLayout(
      spacing: HarnessMonitorTheme.spacingXS,
      lineSpacing: HarnessMonitorTheme.spacingXS
    ) {
      content()
    }
    .padding(.top, HarnessMonitorTheme.spacingSM)
  }

  func pickerField<SelectionValue: Hashable, Content: View>(
    _ title: String,
    selection: Binding<SelectionValue>,
    accessibilityIdentifier: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    TaskBoardOperationsFormRow(title) {
      Picker("", selection: selection) {
        content()
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .harnessNativeFormControl()
      .accessibilityLabel(title)
      .accessibilityIdentifier(accessibilityIdentifier)
    }
  }

  func staticField(
    _ title: String,
    value: String,
    accessibilityIdentifier: String
  ) -> some View {
    TaskBoardOperationsFormRow(title) {
      Text(value)
        .lineLimit(1)
        .truncationMode(.middle)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
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
    TaskBoardOperationsFormRow(title) {
      TextField("", text: text, prompt: Text(prompt))
        .harnessNativeTextField(alignment: .trailing)
        .accessibilityLabel(title)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
  }

  func toggleField(
    _ title: String,
    isOn: Binding<Bool>,
    accessibilityIdentifier: String
  ) -> some View {
    TaskBoardOperationsFormRow(title) {
      Toggle("", isOn: isOn)
        .toggleStyle(.switch)
        .labelsHidden()
        .controlSize(.small)
        .accessibilityLabel(title)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
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
    let status = operation.applied ? "Applied" : (operation.dryRun ? "Preview only" : "Pending")
    let item = operation.boardItemId ?? operation.externalId ?? "Unlinked"
    return keyedSummaryRow(
      title: "\(operation.provider.title) \(operation.action.rawValue.capitalized)",
      subtitle: "\(status) · \(item)"
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
    TaskBoardOperationsFormRow(title) {
      Text(subtitle)
        .font(captionFont)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
    .accessibilityElement(children: .combine)
  }

  func placeholderText(_ text: String) -> some View {
    Text(text)
      .font(captionFont)
      .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, HarnessMonitorTheme.spacingSM)
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
  let metrics: TaskBoardOverviewMetrics
  let footer: String?
  let content: Content

  init(
    title: String,
    metrics: TaskBoardOverviewMetrics,
    footer: String? = nil,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.metrics = metrics
    self.footer = footer
    self.content = content()
  }

  var body: some View {
    TaskBoardOperationsFormSection(
      title: title,
      metrics: metrics,
      footer: footer
    ) {
      content
    }
  }
}

struct TaskBoardOperationsFormSection<Content: View>: View {
  let title: String
  let metrics: TaskBoardOverviewMetrics
  let footer: String?
  let content: Content

  init(
    title: String,
    metrics: TaskBoardOverviewMetrics,
    footer: String? = nil,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.metrics = metrics
    self.footer = footer
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text(title)
        .harnessNativeFormSectionHeader()
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .padding(.leading, TaskBoardOperationsFormMetrics.textInset)

      VStack(alignment: .leading, spacing: 0) {
        content
      }
      .padding(.horizontal, TaskBoardOperationsFormMetrics.sectionPadding)
      .padding(.bottom, TaskBoardOperationsFormMetrics.sectionPadding)
      .background(
        sectionShape.fill(TaskBoardOperationsFormMetrics.sectionSurface)
      )
      .overlay {
        sectionShape.strokeBorder(HarnessMonitorTheme.controlBorder.opacity(0.24), lineWidth: 0.5)
      }

      if let footer {
        Text(footer)
          .harnessNativeFormSectionFooter()
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.leading, TaskBoardOperationsFormMetrics.textInset)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .frame(
      maxWidth: .infinity,
      minHeight: metrics.managementPanelMinHeight,
      alignment: .leading
    )
  }

  private var sectionShape: RoundedRectangle {
    RoundedRectangle(
      cornerRadius: TaskBoardOperationsFormMetrics.sectionCornerRadius,
      style: .continuous
    )
  }

}

private enum TaskBoardOperationsFormMetrics {
  static let sectionPadding: CGFloat = HarnessMonitorTheme.spacingMD
  static let rowHorizontalPadding: CGFloat = HarnessMonitorTheme.spacingSM
  static let textInset: CGFloat = sectionPadding + rowHorizontalPadding
  static let sectionCornerRadius: CGFloat = 10
  static let contentMaxWidth: CGFloat = 420
  static let rowMinHeight: CGFloat = 34
  static let rowVerticalPadding: CGFloat = 5
  static let sectionSurface = Color.primary.opacity(0.045)
}

struct TaskBoardOperationsFormRow<Content: View>: View {
  let title: String
  let showsSeparator: Bool
  let content: Content
  @Environment(\.taskBoardOperationsRowLabelFont)
  private var labelFont
  @Environment(\.taskBoardOperationsRowLabelWidth)
  private var labelWidth

  init(
    _ title: String,
    showsSeparator: Bool = true,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.showsSeparator = showsSeparator
    self.content = content()
  }

  var body: some View {
    HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingMD) {
      Text(title)
        .font(labelFont)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .lineLimit(2)
        .multilineTextAlignment(.leading)
        .frame(width: labelWidth, alignment: .leading)

      content
        .frame(
          maxWidth: TaskBoardOperationsFormMetrics.contentMaxWidth,
          alignment: .trailing
        )
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
    .padding(.vertical, TaskBoardOperationsFormMetrics.rowVerticalPadding)
    .padding(.horizontal, TaskBoardOperationsFormMetrics.rowHorizontalPadding)
    .frame(
      maxWidth: .infinity,
      minHeight: TaskBoardOperationsFormMetrics.rowMinHeight,
      alignment: .leading
    )
    .overlay(alignment: .bottom) {
      if showsSeparator {
        Rectangle()
          .fill(Color(nsColor: .separatorColor))
          .frame(height: 0.5)
      }
    }
  }
}

extension String {
  var taskBoardNilIfEmpty: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
