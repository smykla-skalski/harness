import HarnessMonitorKit
import SwiftUI

struct DashboardPolicyCanvasNameSheet: View {
  let request: DashboardPolicyCanvasNameRequest
  let onSubmit: @MainActor (String) -> Void

  @Environment(\.dismiss)
  private var dismiss
  @FocusState private var titleFieldFocused: Bool
  @State private var draftTitle: String

  init(
    request: DashboardPolicyCanvasNameRequest,
    onSubmit: @escaping @MainActor (String) -> Void
  ) {
    self.request = request
    self.onSubmit = onSubmit
    _draftTitle = State(initialValue: request.initialTitle)
  }

  private var trimmedTitle: String {
    draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
      Text(request.title)
        .font(.title3.weight(.semibold))

      Text(request.message)
        .foregroundStyle(.secondary)

      TextField("Canvas title", text: $draftTitle)
        .textFieldStyle(.roundedBorder)
        .focused($titleFieldFocused)
        .onSubmit(submit)

      HStack {
        Spacer()
        Button("Cancel", role: .cancel) {
          dismiss()
        }
        Button(request.actionTitle, action: submit)
          .keyboardShortcut(.defaultAction)
          .disabled(trimmedTitle.isEmpty)
      }
    }
    .padding(HarnessMonitorTheme.spacingLG)
    .frame(width: 360)
    .task {
      titleFieldFocused = true
    }
    .harnessMCPElementTrackingEnabled(false)
  }

  @MainActor
  private func submit() {
    guard !trimmedTitle.isEmpty else {
      return
    }
    onSubmit(trimmedTitle)
    dismiss()
  }
}

struct DashboardPolicyCanvasNameRequest: Identifiable {
  enum Mode {
    case create
    case duplicate(source: PolicyCanvasSummary)
  }

  let id = UUID()
  let mode: Mode
  let initialTitle: String

  static func create(initialTitle: String) -> Self {
    Self(mode: .create, initialTitle: initialTitle)
  }

  static func duplicate(
    source: PolicyCanvasSummary,
    initialTitle: String
  ) -> Self {
    Self(mode: .duplicate(source: source), initialTitle: initialTitle)
  }

  var title: String {
    switch mode {
    case .create:
      "Create Canvas"
    case .duplicate:
      "Duplicate Canvas"
    }
  }

  var message: String {
    switch mode {
    case .create:
      "Choose a name for the new policy canvas."
    case .duplicate(let source):
      "Create a copy of “\(source.title)” with a new canvas name."
    }
  }

  var actionTitle: String {
    switch mode {
    case .create:
      "Create"
    case .duplicate:
      "Duplicate"
    }
  }
}
