import HarnessMonitorCore
import SwiftUI

struct MobileReviewCommandForm: View {
  @Environment(\.dismiss)
  private var dismiss
  let action: MobileReviewFormAction
  let onSubmit: (MobileReviewFormSubmission) -> Void

  @State private var label = ""
  @State private var mergeMethod = "squash"
  @State private var auditReason = ""

  var body: some View {
    NavigationStack {
      Form {
        Section("Pull Request") {
          Text(action.review.repository)
          Text(verbatim: "#\(action.review.number) \(action.review.title)")
        }
        switch action {
        case .label:
          Section("Label") {
            TextField("Label", text: $label)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
          }
        case .merge:
          Section("Merge") {
            Picker("Method", selection: $mergeMethod) {
              Text("Squash").tag("squash")
              Text("Merge").tag("merge")
              Text("Rebase").tag("rebase")
            }
            TextField("Audit reason", text: $auditReason, axis: .vertical)
          }
        }
      }
      .navigationTitle(action.kind.title)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            dismiss()
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(action.kind.title) {
            submit()
          }
          .disabled(!canSubmit)
        }
      }
    }
  }

  private var canSubmit: Bool {
    switch action {
    case .label:
      !trimmed(label).isEmpty
    case .merge:
      !trimmed(auditReason).isEmpty
    }
  }

  private func submit() {
    switch action {
    case .label(let review):
      onSubmit(.label(review, label: trimmed(label)))
    case .merge(let review):
      onSubmit(.merge(review, method: mergeMethod, auditReason: trimmed(auditReason)))
    }
    dismiss()
  }

  private func trimmed(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
