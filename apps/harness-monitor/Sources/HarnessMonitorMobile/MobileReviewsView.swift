import HarnessMonitorCore
import SwiftUI

struct ReviewsView: View {
  @Environment(MobileMonitorStore.self) private var store
  @State private var formAction: MobileReviewFormAction?

  var body: some View {
    NavigationStack {
      List {
        Section {
          StationPicker()
        }
        Section("Needs Me") {
          if reviewsNeedingMe.isEmpty {
            ContentUnavailableView(
              "No reviews need you",
              systemImage: "checkmark.circle",
              description: Text("Live mirrored pull requests will appear here.")
            )
          } else {
            ForEach(reviewsNeedingMe) { review in
              ReviewRow(
                review: review,
                canQueueCommands: store.canQueueCommand(stationID: review.stationID),
                onQueue: queueImmediateAction,
                onForm: { formAction = $0 }
              )
            }
          }
        }
        Section("Activity") {
          if activityReviews.isEmpty {
            ContentUnavailableView(
              "No review activity",
              systemImage: "tray",
              description: Text("Configured repositories have no mirrored activity.")
            )
          } else {
            ForEach(activityReviews) { review in
              ReviewRow(
                review: review,
                canQueueCommands: store.canQueueCommand(stationID: review.stationID),
                onQueue: queueImmediateAction,
                onForm: { formAction = $0 }
              )
            }
          }
        }
      }
      .navigationTitle("Reviews")
      .sheet(item: $formAction) { action in
        MobileReviewCommandForm(action: action) { submittedAction in
          formAction = nil
          Task {
            await queueFormAction(submittedAction)
          }
        }
      }
    }
  }

  private var stationReviews: [MobileReviewSummary] {
    store.snapshot.reviews
      .filter { store.selectedStationID.isEmpty || $0.stationID == store.selectedStationID }
      .sorted { $0.updatedAt > $1.updatedAt }
  }

  private var reviewsNeedingMe: [MobileReviewSummary] {
    stationReviews.filter(\.needsYou)
  }

  private var activityReviews: [MobileReviewSummary] {
    stationReviews.filter { !$0.needsYou }
  }

  private func queueImmediateAction(_ action: MobileReviewImmediateAction) {
    Task {
      switch action {
      case .approve(let review):
        await store.queueReviewCommand(review, kind: .pullRequestApprove)
      case .rerunChecks(let review):
        await store.queueReviewCommand(review, kind: .pullRequestRerunChecks)
      }
    }
  }

  private func queueFormAction(_ action: MobileReviewFormSubmission) async {
    switch action {
    case .label(let review, let label):
      await store.queueReviewCommand(
        review,
        kind: .pullRequestLabel,
        label: label
      )
    case .merge(let review, let method, let auditReason):
      await store.queueReviewCommand(
        review,
        kind: .pullRequestMerge,
        mergeMethod: method,
        auditReason: auditReason
      )
    }
  }
}

struct ReviewRow: View {
  let review: MobileReviewSummary
  let canQueueCommands: Bool
  let onQueue: (MobileReviewImmediateAction) -> Void
  let onForm: (MobileReviewFormAction) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("#\(review.number)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        Text(review.repository)
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        if review.needsYou {
          Image(systemName: "person.crop.circle.badge.checkmark")
            .foregroundStyle(.blue)
        }
      }
      Text(review.title)
        .font(.headline)
      Text("\(review.author)  \(review.state)  \(review.checksSummary)")
        .font(.subheadline)
        .foregroundStyle(.secondary)
      if canQueueCommands {
        HStack(spacing: 8) {
          Button {
            onQueue(.approve(review))
          } label: {
            Label("Approve", systemImage: "checkmark.seal")
          }
          .buttonStyle(.bordered)

          Button {
            onQueue(.rerunChecks(review))
          } label: {
            Label("Rerun", systemImage: "arrow.clockwise")
          }
          .buttonStyle(.bordered)

          Menu {
            Button {
              onForm(.label(review))
            } label: {
              Label("Apply Label", systemImage: "tag")
            }
            Button(role: .destructive) {
              onForm(.merge(review))
            } label: {
              Label("Merge", systemImage: "arrow.merge")
            }
          } label: {
            Label("More", systemImage: "ellipsis.circle")
          }
          .buttonStyle(.bordered)
        }
        .font(.caption)
      }
    }
    .padding(.vertical, 4)
  }
}

enum MobileReviewImmediateAction {
  case approve(MobileReviewSummary)
  case rerunChecks(MobileReviewSummary)
}

enum MobileReviewFormAction: Identifiable {
  case label(MobileReviewSummary)
  case merge(MobileReviewSummary)

  var id: String {
    "\(kind.rawValue)-\(review.id)"
  }

  var review: MobileReviewSummary {
    switch self {
    case .label(let review), .merge(let review):
      review
    }
  }

  var kind: MobileCommandKind {
    switch self {
    case .label:
      .pullRequestLabel
    case .merge:
      .pullRequestMerge
    }
  }
}

enum MobileReviewFormSubmission {
  case label(MobileReviewSummary, label: String)
  case merge(MobileReviewSummary, method: String, auditReason: String)
}

struct MobileReviewCommandForm: View {
  @Environment(\.dismiss) private var dismiss
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
          Text("#\(action.review.number) \(action.review.title)")
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
