import HarnessMonitorCore
import HarnessMonitorMirrorStore
import SwiftUI

/// Typed navigation route for opening a mirrored pull request on the watch.
struct WatchReviewDetailRoute: Hashable {
  let reviewID: String
}

/// Compact detail for a mirrored pull request reached from a "Needs You" item:
/// the mirrored checks, files, and activity plus Approve / Rerun actions and an
/// Open-on-GitHub link. Approve confirms first; the low-risk rerun fires directly,
/// mirroring the iOS risk gate.
struct WatchReviewDetailView: View {
  @Environment(MirrorStore.self)
  private var store
  let reviewID: String
  let zoom: Namespace.ID

  @State private var pendingCommand: PendingWatchReviewCommand?

  private var review: MobileReviewSummary? {
    store.snapshot.reviews.first { $0.id == reviewID }
  }

  var body: some View {
    List {
      if let review {
        header(review)
        if !review.checks.isEmpty {
          Section("Checks") {
            ForEach(review.checks) { check in
              Label(check.name, systemImage: checkIcon(check))
                .font(.caption2)
                .foregroundStyle(checkColor(check))
            }
          }
        }
        if !review.files.isEmpty {
          Section("Files") {
            ForEach(review.files) { file in
              fileRow(file)
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
            ForEach(review.activity) { entry in
              activityRow(entry)
            }
          }
        }
        actions(review)
      } else {
        ContentUnavailableView(
          "Pull request no longer mirrored",
          systemImage: "arrow.triangle.pull"
        )
      }
    }
    .navigationTitle("Pull Request")
    .navigationTransition(.zoom(sourceID: "detail-\(reviewID)", in: zoom))
    .confirmationDialog(
      pendingCommand?.kind.title ?? "",
      isPresented: Binding(
        get: { pendingCommand != nil },
        set: { if !$0 { pendingCommand = nil } }
      ),
      titleVisibility: .visible,
      presenting: pendingCommand
    ) { pending in
      Button(pending.kind.title, role: pending.kind.risk == .destructive ? .destructive : nil) {
        Task { await store.queueReviewCommand(pending.review, kind: pending.kind) }
        pendingCommand = nil
      }
      Button("Cancel", role: .cancel) { pendingCommand = nil }
    } message: { pending in
      Text(verbatim: "#\(pending.review.number) \(pending.review.title)")
    }
  }

  @ViewBuilder
  private func header(_ review: MobileReviewSummary) -> some View {
    Section {
      VStack(alignment: .leading, spacing: 4) {
        Text(verbatim: "\(review.repository) #\(review.number)")
          .font(.caption2)
          .foregroundStyle(.secondary)
        Text(review.title)
          .font(.headline)
        Text("\(review.author)  \(review.state)")
          .font(.caption2)
          .foregroundStyle(.secondary)
        Text(review.checksSummary)
          .font(.caption2)
          .foregroundStyle(.secondary)
        HStack(spacing: 8) {
          Text(verbatim: "+\(review.additions)")
            .foregroundStyle(.green)
          Text(verbatim: "-\(review.deletions)")
            .foregroundStyle(.red)
          if review.isDraft == true {
            Text("Draft")
              .foregroundStyle(.orange)
          }
          if review.policyBlocked == true {
            Text("Blocked")
              .foregroundStyle(.red)
          }
        }
        .font(.caption2.weight(.semibold))
      }
      .accessibilityElement(children: .combine)
    }
  }

  @ViewBuilder
  private func fileRow(_ file: MobileReviewFileSnippet) -> some View {
    HStack(spacing: 6) {
      Text(URL(fileURLWithPath: file.path).lastPathComponent)
        .font(.caption2)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 6)
      Text(verbatim: "+\(file.additions) -\(file.deletions)")
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder
  private func activityRow(_ entry: MobileReviewActivitySnippet) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(entry.summary)
        .font(.caption2)
        .lineLimit(2)
      Text(entry.recordedAt.formatted(.relative(presentation: .numeric)))
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder
  private func actions(_ review: MobileReviewSummary) -> some View {
    if store.canQueueCommand(stationID: review.stationID) && review.viewerCanUpdate {
      Section {
        if canQuickApprove(review) {
          Button {
            queue(.pullRequestApprove, review)
          } label: {
            Label("Approve", systemImage: "checkmark.seal")
          }
        }
        Button {
          queue(.pullRequestRerunChecks, review)
        } label: {
          Label("Rerun Checks", systemImage: "arrow.clockwise")
        }
      }
    }
    if let address = review.url, let url = URL(string: address) {
      Section {
        Link(destination: url) {
          Label("Open on GitHub", systemImage: "arrow.up.right.square")
        }
      }
    }
  }

  private func queue(_ kind: MobileCommandKind, _ review: MobileReviewSummary) {
    guard kind.risk != .low else {
      Task { await store.queueReviewCommand(review, kind: kind) }
      return
    }
    pendingCommand = PendingWatchReviewCommand(review: review, kind: kind)
  }

  private func canQuickApprove(_ review: MobileReviewSummary) -> Bool {
    review.isDraft != true && !review.checksSummary.localizedCaseInsensitiveContains("running")
  }

  private func checkIcon(_ check: MobileReviewCheckSnippet) -> String {
    switch check.conclusion {
    case "success":
      "checkmark.circle.fill"
    case "failure", "timed_out", "cancelled":
      "xmark.octagon.fill"
    default:
      check.status == "completed" ? "circle" : "clock.fill"
    }
  }

  private func checkColor(_ check: MobileReviewCheckSnippet) -> Color {
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

private struct PendingWatchReviewCommand: Identifiable {
  let id = UUID()
  let review: MobileReviewSummary
  let kind: MobileCommandKind
}
