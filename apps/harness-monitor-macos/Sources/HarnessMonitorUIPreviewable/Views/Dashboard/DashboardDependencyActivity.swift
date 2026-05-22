import Foundation
import HarnessMonitorKit
import SwiftUI

struct DashboardDependencyActivityEntry: Codable, Equatable, Identifiable, Sendable {
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
    response: DependencyUpdatesActionResponse,
    results: [DependencyUpdateActionResult],
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

struct DashboardDependencyActivitySnapshot: Equatable, Sendable {
  let pullRequestID: String
  let isRefreshing: Bool
  let actionTitle: String?
  let fetchedAt: String
  let fromCache: Bool
  let lastAction: DashboardDependencyActivityEntry?
  let missingCheckRunURLCount: Int
  let totalCheckCount: Int
  let capabilities: DependencyUpdatesCapabilitiesResponse

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
    lines.append("Dependency schema: \(capabilities.schemaVersion)")
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

struct DashboardDependencyActivitySummary: View {
  let snapshot: DashboardDependencyActivitySnapshot

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      HarnessMonitorWrapLayout(
        spacing: HarnessMonitorTheme.spacingSM,
        lineSpacing: HarnessMonitorTheme.spacingSM
      ) {
        if snapshot.isRefreshing {
          DashboardDependencyStatusPill(
            label: snapshot.actionTitle ?? "Refreshing",
            tint: HarnessMonitorTheme.accent,
            systemImage: "arrow.clockwise"
          )
        }
        DashboardDependencyStatusPill(
          label: snapshot.cacheLabel,
          tint: snapshot.fromCache ? HarnessMonitorTheme.caution : HarnessMonitorTheme.success,
          systemImage: snapshot.fromCache ? "archivebox" : "network"
        )
        if !snapshot.fetchedAt.isEmpty {
          DashboardDependencyStatusPill(
            label: "Fetched \(snapshot.fetchedAt)",
            tint: HarnessMonitorTheme.secondaryInk,
            systemImage: "clock",
            isQuiet: true
          )
        }
        if let checkLinkLabel = snapshot.checkLinkLabel {
          DashboardDependencyStatusPill(
            label: checkLinkLabel,
            tint: snapshot.missingCheckRunURLCount == 0
              ? HarnessMonitorTheme.success
              : HarnessMonitorTheme.caution,
            systemImage: snapshot.missingCheckRunURLCount == 0
              ? "link"
              : "exclamationmark.triangle",
            isQuiet: snapshot.missingCheckRunURLCount == 0
          )
        }
      }

      if let lastAction = snapshot.lastAction {
        DashboardDependencyLastActionRow(entry: lastAction)
      } else {
        Text("No recent dependency action is recorded for this pull request.")
          .scaledFont(.callout)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
      Button {
        HarnessMonitorClipboard.copy(snapshot.diagnosticsText)
      } label: {
        Label("Copy action diagnostics", systemImage: "doc.on.doc")
      }
      .controlSize(.small)
    }
  }
}

private struct DashboardDependencyLastActionRow: View {
  let entry: DashboardDependencyActivityEntry

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      HStack(spacing: HarnessMonitorTheme.spacingSM) {
        DashboardDependencyStatusPill(
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

extension DashboardDependencyActivityEntry.Outcome {
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

extension DependencyUpdateActionResult {
  fileprivate var activityMessage: String? {
    if let message, !message.isEmpty {
      return message
    }
    return "\(action.activityLabel): \(outcome.activityLabel)"
  }
}

extension DependencyUpdateActionKind {
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

extension DependencyUpdateActionOutcome {
  fileprivate var activityLabel: String {
    switch self {
    case .applied: "applied"
    case .skipped: "skipped"
    case .failed: "failed"
    case .unknown(let raw): raw
    }
  }
}
