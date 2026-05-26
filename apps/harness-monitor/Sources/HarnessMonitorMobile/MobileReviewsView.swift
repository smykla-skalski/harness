import HarnessMonitorCore
import SwiftUI

struct ReviewsView: View {
  @Environment(MobileMonitorStore.self)
  private var store
  @State private var formAction: MobileReviewFormAction?
  @State private var pendingConfirmation: PendingCommandConfirmation?

  var body: some View {
    NavigationStack {
      List {
        Section {
          StationPicker()
        }
        Section("Needs Me") {
          if reviewsNeedingMe.isEmpty {
            if let reviewMirrorAttention {
              AttentionRow(item: reviewMirrorAttention, onQueue: queueAttention)
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
      .harnessMonitorListChrome()
      .navigationTitle("Reviews")
      .sheet(item: $formAction) { action in
        MobileReviewCommandForm(action: action) { submittedAction in
          formAction = nil
          Task {
            await queueFormAction(submittedAction)
          }
        }
      }
      .commandConfirmation($pendingConfirmation)
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
    let kind: MobileCommandKind
    let review: MobileReviewSummary
    switch action {
    case .approve(let value):
      kind = .pullRequestApprove
      review = value
    case .rerunChecks(let value):
      kind = .pullRequestRerunChecks
      review = value
    }
    confirmCommandIfNeeded(
      kind: kind,
      message: reviewConfirmationMessage(review),
      pending: $pendingConfirmation
    ) {
      Task { await store.queueReviewCommand(review, kind: kind) }
    }
  }

  private func queueAttention(_ item: MobileAttentionItem) {
    guard let kind = item.commandKind else {
      return
    }
    confirmCommandIfNeeded(kind: kind, message: item.confirmationMessage, pending: $pendingConfirmation) {
      Task { await store.queueCommand(from: item) }
    }
  }

  private func reviewConfirmationMessage(_ review: MobileReviewSummary) -> String {
    "#\(review.number) \(review.title)"
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
              .accessibilityLabel("Needs you")
          }
        }
        Text(review.title)
          .font(.headline)
          .lineLimit(2)
        Text("\(review.author)  \(review.state)  \(review.checksSummary)")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      .accessibilityElement(children: .combine)
      ReviewMetadataStrip(review: review)
      if !review.checks.isEmpty {
        MobileReviewSnippetGroup(title: "Checks") {
          ForEach(review.checks.prefix(2)) { check in
            MobileReviewCheckSnippetRow(check: check)
          }
        }
      }
      if !review.files.isEmpty {
        MobileReviewSnippetGroup(title: "Files") {
          ForEach(review.files.prefix(2)) { file in
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
          ForEach(review.activity.prefix(2)) { activity in
            MobileReviewActivitySnippetRow(activity: activity)
          }
        }
      }
      if canQueueCommands && review.viewerCanUpdate {
        HStack(spacing: 8) {
          if canQuickApprove {
            Button {
              onQueue(.approve(review))
            } label: {
              Label("Approve", systemImage: "checkmark.seal")
            }
            .harnessActionButtonStyle(prominent: true, tint: .green)
          }

          Button {
            onQueue(.rerunChecks(review))
          } label: {
            Label("Rerun", systemImage: "arrow.clockwise")
          }
          .harnessActionButtonStyle(tint: .blue)

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
          .harnessActionButtonStyle(tint: .gray)
        }
      } else if canQueueCommands {
        Label("Actions unavailable for your GitHub permissions", systemImage: "lock")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 4)
    .harnessBalancedListSeparator()
  }

  private var canQuickApprove: Bool {
    review.isDraft != true && !review.checksSummary.localizedCaseInsensitiveContains("running")
  }
}

struct ReviewMetadataStrip: View {
  let review: MobileReviewSummary

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Text("+\(review.additions)")
          .foregroundStyle(.green)
        Text("-\(review.deletions)")
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
            ForEach(Array(review.labels.prefix(6).enumerated()), id: \.offset) { _, label in
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
    .accessibilityElement(children: .combine)
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
