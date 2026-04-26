import HarnessMonitorKit
import SwiftUI

struct CreateTaskSheet: View {
  let store: HarnessMonitorStore
  let sessionID: String
  @Environment(\.dismiss)
  private var dismiss

  @State private var createTitle = ""
  @State private var createContext = ""
  @State private var createSeverity: TaskSeverity = .medium
  @FocusState private var focusedField: Field?

  private enum Field: Hashable {
    case title
    case context
  }

  private var areSessionActionsAvailable: Bool {
    store.areSelectedSessionActionsAvailable
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
          if let banner = store.selectedSessionActionBannerMessage {
            Text(banner)
              .scaledFont(.system(.footnote, design: .rounded, weight: .medium))
              .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          }
          TextField("Title", text: $createTitle)
            .harnessNativeFormControl()
            .focused($focusedField, equals: .title)
            .submitLabel(.next)
            .onSubmit { focusedField = .context }
            .accessibilityIdentifier(HarnessMonitorAccessibility.createTaskTitleField)
          TextField("Context", text: $createContext, axis: .vertical)
            .harnessNativeFormControl()
            .focused($focusedField, equals: .context)
            .lineLimit(4, reservesSpace: true)
            .submitLabel(.done)
          Picker("Severity", selection: $createSeverity) {
            ForEach(TaskSeverity.allCases, id: \.self) { severity in
              Text(severity.title).tag(severity)
            }
          }
          .harnessNativeFormControl()
          HarnessInlineActionButton(
            title: "Create Task",
            actionID: .createTask(sessionID: sessionID),
            store: store,
            variant: .prominent,
            tint: nil,
            isExternallyDisabled: !canSubmit,
            accessibilityIdentifier: HarnessMonitorAccessibility.createTaskButton,
            action: submitCreateTask
          )
        }
        .padding(HarnessMonitorTheme.spacingLG)
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(!areSessionActionsAvailable)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.createTaskSheet)
    .onAppear { focusedField = .title }
  }

  private var canSubmit: Bool {
    !createTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && areSessionActionsAvailable
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
        Text("New Task")
          .scaledFont(.caption.bold())
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        Text("Create Task")
          .scaledFont(.system(.title3, design: .rounded, weight: .bold))
      }
      Spacer()
      Button("Done") { dismiss() }
        .keyboardShortcut(.cancelAction)
        .accessibilityIdentifier(HarnessMonitorAccessibility.createTaskSheetDismiss)
    }
    .padding(HarnessMonitorTheme.spacingLG)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func submitCreateTask() {
    Task { await createTask() }
  }

  private func createTask() async {
    let title = createTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    let context = createContext.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { return }

    let success = await store.createTask(
      title: title,
      context: context.isEmpty ? nil : context,
      severity: createSeverity
    )
    if success {
      dismiss()
    }
  }
}

#Preview("Create task sheet") {
  CreateTaskSheet(
    store: HarnessMonitorPreviewStoreFactory.makeStore(for: .cockpitLoaded),
    sessionID: PreviewFixtures.summary.sessionId
  )
  .frame(width: 480, height: 560)
}
