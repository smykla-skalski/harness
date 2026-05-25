import HarnessMonitorCore
import SwiftUI

struct ReviewsView: View {
  @Environment(MobileMonitorStore.self)
  private var store
  @State private var formAction: MobileReviewFormAction?

  var body: some View {
    NavigationStack {
      List {
        Section {
          StationPicker()
        }
        Section("Needs Me") {
          if reviewsNeedingMe.isEmpty {
            if let reviewMirrorAttention {
              AttentionRow(item: reviewMirrorAttention)
            } else {
              ContentUnavailableView(
                "No reviews need you",
                systemImage: "checkmark.circle",
                description: Text("Live mirrored pull requests will appear here.")
              )
            }
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

  private var reviewMirrorAttention: MobileAttentionItem? {
    store.snapshot.sortedAttention.first {
      (store.selectedStationID.isEmpty || $0.stationID == store.selectedStationID)
        && $0.commandPayload["scope"] == "reviews"
    }
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
        Text(verbatim: "#\(review.number)")
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
      ReviewMetadataStrip(review: review)
      if !review.checks.isEmpty {
        MobileReviewSnippetGroup(title: "Checks") {
          ForEach(review.checks.prefix(3)) { check in
            MobileReviewCheckSnippetRow(check: check)
          }
        }
      }
      if !review.files.isEmpty {
        MobileReviewSnippetGroup(title: "Files") {
          ForEach(review.files.prefix(4)) { file in
            MobileReviewFileSnippetRow(file: file)
          }
          if review.filePaginationComplete == false {
            Text("More files on Mac")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
      }
      if !review.activity.isEmpty {
        MobileReviewSnippetGroup(title: "Activity") {
          ForEach(review.activity.prefix(3)) { activity in
            MobileReviewActivitySnippetRow(activity: activity)
          }
        }
      }
      if canQueueCommands && review.viewerCanUpdate {
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
      } else if canQueueCommands {
        Label("Actions unavailable for your GitHub permissions", systemImage: "lock")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 4)
  }
}

struct ReviewMetadataStrip: View {
  let review: MobileReviewSummary

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Label("+\(review.additions)", systemImage: "plus")
          .foregroundStyle(.green)
        Label("-\(review.deletions)", systemImage: "minus")
          .foregroundStyle(.red)
        if review.isDraft == true {
          Text("Draft")
            .foregroundStyle(.orange)
        }
        if review.policyBlocked == true {
          Text("Policy blocked")
            .foregroundStyle(.red)
        }
      }
      .font(.caption2.weight(.semibold))
      if !review.labels.isEmpty {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 6) {
            ForEach(review.labels.prefix(6), id: \.self) { label in
              Text(label)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.blue.opacity(0.12), in: Capsule())
                .foregroundStyle(.blue)
            }
          }
        }
      }
      if !review.requiredFailedCheckNames.isEmpty {
        Text(
          "Required failures: \(review.requiredFailedCheckNames.prefix(3).joined(separator: ", "))"
        )
        .font(.caption2)
        .foregroundStyle(.red)
      }
    }
  }
}

struct MobileReviewSnippetGroup<Content: View>: View {
  let title: String
  let content: Content

  init(title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
      content
    }
  }
}

struct MobileReviewCheckSnippetRow: View {
  let check: MobileReviewCheckSnippet

  var body: some View {
    Label {
      HStack {
        Text(check.name)
          .lineLimit(1)
        Spacer(minLength: 8)
        Text(statusText)
          .foregroundStyle(.secondary)
      }
      .font(.caption)
    } icon: {
      Image(systemName: iconName)
        .foregroundStyle(iconColor)
    }
  }

  private var statusText: String {
    if check.conclusion != "none" {
      return check.conclusion
    }
    return check.status
  }

  private var iconName: String {
    switch check.conclusion {
    case "success":
      "checkmark.circle.fill"
    case "failure", "timed_out", "cancelled":
      "xmark.octagon.fill"
    default:
      check.status == "completed" ? "circle" : "clock.fill"
    }
  }

  private var iconColor: Color {
    switch check.conclusion {
    case "success":
      .green
    case "failure", "timed_out", "cancelled":
      .red
    default:
      .orange
    }
  }
}

struct MobileReviewFileSnippetRow: View {
  let file: MobileReviewFileSnippet

  var body: some View {
    HStack(spacing: 6) {
      Text(file.changeType)
        .font(.caption2.weight(.bold))
        .foregroundStyle(changeColor)
        .frame(width: 34, alignment: .leading)
      Text(file.path)
        .font(.caption)
        .lineLimit(1)
      Spacer(minLength: 8)
      Text("+\(file.additions) -\(file.deletions)")
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
    }
  }

  private var changeColor: Color {
    switch file.changeType {
    case "added":
      .green
    case "deleted":
      .red
    case "renamed", "copied":
      .blue
    default:
      .secondary
    }
  }
}

struct MobileReviewActivitySnippetRow: View {
  let activity: MobileReviewActivitySnippet

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "clock")
        .foregroundStyle(.secondary)
      Text(activity.actor.map { "\($0) " } ?? "")
        .font(.caption.weight(.semibold))
      Text(activity.summary)
        .font(.caption)
        .lineLimit(1)
      Spacer(minLength: 8)
      Text(activity.recordedAt.formatted(.relative(presentation: .numeric)))
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
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
