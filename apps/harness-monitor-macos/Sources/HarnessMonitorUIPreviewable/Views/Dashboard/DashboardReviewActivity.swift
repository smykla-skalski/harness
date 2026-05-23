import Foundation
import HarnessMonitorKit
import SwiftUI

struct DashboardReviewActivityEntry: Codable, Equatable, Identifiable, Sendable {
  enum Outcome: String, Codable, Equatable, Sendable {
    case success
    case failure
  }

  let id: String
  let title: String
  let summary: String
  let outcome: Outcome
  let messages: [String]
  let recordedAt: Date

  init(
    id: String = UUID().uuidString,
    title: String,
    summary: String,
    outcome: Outcome,
    messages: [String] = [],
    recordedAt: Date = Date()
  ) {
    self.id = id
    self.title = title
    self.summary = summary
    self.outcome = outcome
    self.messages = messages
    self.recordedAt = recordedAt
  }

  static func success(
    title: String,
    response: ReviewsActionResponse,
    results: [ReviewActionResult],
    recordedAt: Date = Date()
  ) -> Self {
    let outcome: Outcome = results.contains { $0.outcome == .failed } ? .failure : .success
    return Self(
      title: title,
      summary: response.summary,
      outcome: outcome,
      messages: results.compactMap(\.activityMessage),
      recordedAt: recordedAt
    )
  }

  static func failure(title: String, error: Error, recordedAt: Date = Date()) -> Self {
    Self(
      title: title,
      summary: error.localizedDescription,
      outcome: .failure,
      recordedAt: recordedAt
    )
  }
}

struct DashboardReviewActivitySnapshot: Equatable, Sendable {
  let pullRequestID: String
  let isRefreshing: Bool
  let actionTitle: String?
  let fetchedAt: String
  let fromCache: Bool
  let lastAction: DashboardReviewActivityEntry?
  let missingCheckRunURLCount: Int
  let totalCheckCount: Int
  let capabilities: ReviewsCapabilitiesResponse

  var cacheLabel: String {
    fromCache ? "Cached data" : "Live data"
  }

  var checkLinkLabel: String? {
    guard totalCheckCount > 0 else { return nil }
    if missingCheckRunURLCount == 0 {
      return "All check links available"
    }
    return "\(missingCheckRunURLCount)/\(totalCheckCount) check links missing"
  }

  var diagnosticsText: String {
    var lines = [
      "Pull request ID: \(pullRequestID)",
      "Data: \(cacheLabel)",
    ]
    if !fetchedAt.isEmpty {
      lines.append("Fetched at: \(fetchedAt)")
    }
    if let checkLinkLabel {
      lines.append("Check links: \(checkLinkLabel)")
    }
    lines.append("Review schema: \(capabilities.schemaVersion)")
    lines.append("Action preview: \(capabilities.supportsActionPreview ? "supported" : "fallback")")
    if let actionTitle {
      lines.append("Current action: \(actionTitle)")
    }
    if let lastAction {
      lines.append("Last action: \(lastAction.title)")
      lines.append("Outcome: \(lastAction.outcome.diagnosticsLabel)")
      lines.append("Summary: \(lastAction.summary)")
      lines.append(contentsOf: lastAction.messages.map { "Message: \($0)" })
    } else {
      lines.append("Last action: none")
    }
    return lines.joined(separator: "\n")
  }
}

struct DashboardReviewActivitySummary: View {
  let snapshot: DashboardReviewActivitySnapshot

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      metadataLine

      if let lastAction = snapshot.lastAction {
        DashboardReviewLastActionRow(entry: lastAction)
      } else {
        emptyActionRow
      }
    }
  }

  private var metadataLine: some View {
    HarnessMonitorWrapLayout(
      spacing: HarnessMonitorTheme.spacingSM,
      lineSpacing: HarnessMonitorTheme.spacingSM
    ) {
      if snapshot.isRefreshing {
        metadataLabel(
          snapshot.actionTitle ?? "Refreshing",
          systemImage: "arrow.clockwise",
          tint: HarnessMonitorTheme.accent
        )
      }
      metadataLabel(
        snapshot.cacheLabel,
        systemImage: snapshot.fromCache ? "archivebox" : "network",
        tint: snapshot.fromCache ? HarnessMonitorTheme.caution : HarnessMonitorTheme.secondaryInk
      )
      if !snapshot.fetchedAt.isEmpty {
        metadataLabel("Fetched \(snapshot.fetchedAt)", systemImage: "clock")
      }
      if let checkLinkLabel = snapshot.checkLinkLabel {
        metadataLabel(
          checkLinkLabel,
          systemImage: snapshot.missingCheckRunURLCount == 0
            ? "link"
            : "exclamationmark.triangle",
          tint: snapshot.missingCheckRunURLCount == 0
            ? HarnessMonitorTheme.secondaryInk
            : HarnessMonitorTheme.caution
        )
      }
    }
  }

  private var emptyActionRow: some View {
    HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingSM) {
      Image(systemName: "clock")
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      Text("No monitor action has run for this pull request.")
        .scaledFont(.callout)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      Spacer(minLength: HarnessMonitorTheme.spacingSM)
      Button {
        HarnessMonitorClipboard.copy(snapshot.diagnosticsText)
      } label: {
        Label("Copy diagnostics", systemImage: "doc.on.doc")
      }
      .controlSize(.small)
    }
  }

  private func metadataLabel(
    _ title: String,
    systemImage: String,
    tint: Color = HarnessMonitorTheme.secondaryInk
  ) -> some View {
    Label(title, systemImage: systemImage)
      .scaledFont(.caption.weight(.semibold))
      .foregroundStyle(tint)
      .lineLimit(1)
  }
}

private struct DashboardReviewLastActionRow: View {
  let entry: DashboardReviewActivityEntry

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      HStack(spacing: HarnessMonitorTheme.spacingSM) {
        DashboardReviewStatusPill(
          label: entry.outcome.label,
          tint: entry.outcome.tint,
          systemImage: entry.outcome.systemImage
        )
        Text(entry.title)
          .scaledFont(.callout.weight(.semibold))
          .foregroundStyle(HarnessMonitorTheme.ink)
        Text(entry.recordedAt, style: .relative)
          .scaledFont(.caption.weight(.semibold))
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
      Text(entry.summary)
        .scaledFont(.callout)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .fixedSize(horizontal: false, vertical: true)
      ForEach(entry.messages, id: \.self) { message in
        Text(message)
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

extension DashboardReviewActivityEntry.Outcome {
  fileprivate var label: String {
    switch self {
    case .success: "Last action succeeded"
    case .failure: "Last action failed"
    }
  }

  fileprivate var tint: Color {
    switch self {
    case .success: HarnessMonitorTheme.success
    case .failure: HarnessMonitorTheme.danger
    }
  }

  fileprivate var systemImage: String {
    switch self {
    case .success: "checkmark.circle.fill"
    case .failure: "exclamationmark.triangle.fill"
    }
  }

  var diagnosticsLabel: String {
    switch self {
    case .success: "success"
    case .failure: "failure"
    }
  }
}

extension ReviewActionResult {
  fileprivate var activityMessage: String? {
    if let message, !message.isEmpty {
      return message
    }
    return "\(action.activityLabel): \(outcome.activityLabel)"
  }
}

extension ReviewActionKind {
  fileprivate var activityLabel: String {
    switch self {
    case .approve: "Approve"
    case .merge: "Merge"
    case .rerunChecks: "Rerun checks"
    case .addLabel: "Add label"
    case .autoApprove: "Auto approve"
    case .autoMerge: "Auto merge"
    case .comment: "Comment"
    case .unknown(let raw): raw
    }
  }
}

extension ReviewActionOutcome {
  fileprivate var activityLabel: String {
    switch self {
    case .applied: "applied"
    case .skipped: "skipped"
    case .failed: "failed"
    case .unknown(let raw): raw
    }
  }
}
