import HarnessMonitorCore
import HarnessMonitorMirrorStore
import SwiftUI

/// Typed navigation route for opening a mirrored pull request's detail.
struct MobileReviewDetailRoute: Hashable {
  let reviewID: String
}

/// Full detail for a single mirrored pull request: every mirrored check, file,
/// and activity entry (the Reviews list rows cap these at two), plus the review
/// actions and an Open-on-GitHub link. Reached from a "Needs You" pull-request
/// item or a Reviews-tab row.
struct MobileReviewDetailView: View {
  @Environment(MirrorStore.self)
  private var store
  let reviewID: String
  let zoom: Namespace.ID

  @State private var formAction: MobileReviewFormAction?
  @State private var pendingConfirmation: PendingCommandConfirmation?
  @Namespace private var sheetZoom

  private var review: MobileReviewSummary? {
    store.snapshot.reviews.first { $0.id == reviewID }
  }

  var body: some View {
    List {
      if let review {
        header(review)
        snippets(review)
        actions(review)
      } else {
        ContentUnavailableView(
          "Pull request no longer mirrored",
          systemImage: "arrow.triangle.pull",
          description: Text("Refresh to load the latest station state")
        )
      }
    }
    .harnessMonitorListChrome()
    .navigationTitle("Pull Request")
    .navigationTransition(.zoom(sourceID: "detail-\(reviewID)", in: zoom))
    .sheet(item: $formAction) { action in
      MobileReviewCommandForm(action: action) { submittedAction in
        formAction = nil
        Task { await queueFormAction(submittedAction) }
      }
      .navigationTransition(.zoom(sourceID: action.review.id, in: sheetZoom))
    }
    .commandConfirmation($pendingConfirmation)
    .toolbar {
      if let review, let address = review.url, let url = URL(string: address) {
        ToolbarItem(placement: .topBarTrailing) {
          Link(destination: url) {
            Label("Open on GitHub", systemImage: "arrow.up.right.square")
          }
        }
      }
    }
  }

  @ViewBuilder
  private func header(_ review: MobileReviewSummary) -> some View {
    Section {
      VStack(alignment: .leading, spacing: 8) {
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
          .font(.title3.weight(.semibold))
        Text("\(review.author)  \(review.state)  \(review.checksSummary)")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      .accessibilityElement(children: .combine)
      ReviewMetadataStrip(review: review)
    }
  }

  @ViewBuilder
  private func snippets(_ review: MobileReviewSummary) -> some View {
    if !review.checks.isEmpty {
      Section("Checks") {
        ForEach(review.checks) { check in
          MobileReviewCheckSnippetRow(check: check)
        }
      }
    }
    if !review.files.isEmpty {
      Section("Files") {
        ForEach(review.files) { file in
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
      Section("Activity") {
        ForEach(review.activity) { activity in
          MobileReviewActivitySnippetRow(activity: activity)
        }
      }
    }
  }

  @ViewBuilder
  private func actions(_ review: MobileReviewSummary) -> some View {
    if store.canQueueCommand(stationID: review.stationID) {
      Section {
        if review.viewerCanUpdate {
          HarnessMonitorMobileGlassControlGroup(spacing: 8) {
            HStack(spacing: 8) {
              if canQuickApprove(review) {
                Button {
                  approve(review)
                } label: {
                  Label("Approve", systemImage: "checkmark.seal")
                }
                .harnessActionButtonStyle(prominent: true, tint: .green)
              }

              Button {
                rerun(review)
              } label: {
                Label("Rerun", systemImage: "arrow.clockwise")
              }
              .harnessActionButtonStyle(tint: .blue)

              Menu {
                Button {
                  formAction = .label(review)
                } label: {
                  Label("Apply Label", systemImage: "tag")
                }
                Button(role: .destructive) {
                  formAction = .merge(review)
                } label: {
                  Label("Merge", systemImage: "arrow.merge")
                }
              } label: {
                Label("More", systemImage: "ellipsis.circle")
              }
              .harnessActionButtonStyle(tint: .gray)
              .matchedTransitionSource(id: review.id, in: sheetZoom)
            }
          }
        } else {
          Label("Actions unavailable for your GitHub permissions", systemImage: "lock")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  private func canQuickApprove(_ review: MobileReviewSummary) -> Bool {
    review.isDraft != true && !review.checksSummary.localizedCaseInsensitiveContains("running")
  }

  private func approve(_ review: MobileReviewSummary) {
    confirmCommandIfNeeded(
      kind: .pullRequestApprove,
      message: confirmationMessage(review),
      pending: $pendingConfirmation
    ) {
      Task { await store.queueReviewCommand(review, kind: .pullRequestApprove) }
    }
  }

  private func rerun(_ review: MobileReviewSummary) {
    confirmCommandIfNeeded(
      kind: .pullRequestRerunChecks,
      message: confirmationMessage(review),
      pending: $pendingConfirmation
    ) {
      Task { await store.queueReviewCommand(review, kind: .pullRequestRerunChecks) }
    }
  }

  private func confirmationMessage(_ review: MobileReviewSummary) -> String {
    "#\(review.number) \(review.title)"
  }

  private func queueFormAction(_ action: MobileReviewFormSubmission) async {
    switch action {
    case .label(let review, let label):
      await store.queueReviewCommand(review, kind: .pullRequestLabel, label: label)
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
