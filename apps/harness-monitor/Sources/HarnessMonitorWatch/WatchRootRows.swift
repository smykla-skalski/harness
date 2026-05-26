import HarnessMonitorCore
import HarnessMonitorMirrorStore
import SwiftUI

struct WatchSessionRow: View {
  let session: MobileSessionSummary

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Label(
        session.title,
        systemImage: session.blockedAgentCount > 0 ? "person.fill.questionmark" : "rectangle.stack"
      )
      .font(.headline)
      Text("\(session.activeAgentCount) active, \(session.blockedAgentCount) waiting")
        .font(.caption2)
        .foregroundStyle(.secondary)
      Text(session.lastActivityAt, style: .relative)
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
  }
}

struct WatchReviewRow: View {
  let review: MobileReviewSummary

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Image(systemName: review.needsYou ? "arrow.triangle.pull" : "checkmark.circle")
          .foregroundStyle(review.needsYou ? .orange : .secondary)
          .accessibilityHidden(true)
        Text(verbatim: "\(review.repository) #\(review.number)")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      Text(review.title)
        .font(.headline)
        .lineLimit(2)
      Text(review.checksSummary)
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
  }
}

struct WatchTaskBoardRow: View {
  let item: MobileTaskBoardSummary

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Label(
        item.title,
        systemImage: item.needsYou ? "exclamationmark.circle" : "list.bullet.clipboard"
      )
      .font(.headline)
      .foregroundStyle(item.needsYou ? .orange : .primary)
      Text("\(item.statusTitle) - \(item.priorityTitle)")
        .font(.caption2)
        .foregroundStyle(.secondary)
      if !item.bodyPreview.isEmpty {
        Text(item.bodyPreview)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
    }
    .accessibilityElement(children: .combine)
  }
}

struct WatchCommandRow: View {
  let command: MobileCommandRecord
  let retry: () -> Void
  let cancel: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      VStack(alignment: .leading, spacing: 6) {
        HStack(alignment: .top, spacing: 8) {
          Image(systemName: symbol)
            .foregroundStyle(color)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 2) {
            Text(command.title)
              .font(.headline)
            Text(command.status.title)
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
        if let receipt = command.receipt {
          Text(receipt.message)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
      .accessibilityElement(children: .combine)
      if command.canRetrySafely {
        Button(action: retry) {
          Label("Retry", systemImage: "arrow.clockwise")
        }
      }
      if command.status == .queued {
        Button(role: .destructive, action: cancel) {
          Label("Cancel", systemImage: "xmark")
        }
      }
    }
  }

  private var symbol: String {
    switch command.status {
    case .succeeded:
      "checkmark.circle"
    case .failed, .expired:
      "xmark.octagon"
    case .cancelled:
      "xmark.circle"
    case .running:
      "play.circle"
    case .draft, .queued, .accepted:
      "clock"
    }
  }

  private var color: Color {
    switch command.status {
    case .succeeded:
      .green
    case .failed, .expired, .cancelled:
      .red
    case .running:
      .blue
    case .draft, .queued, .accepted:
      .orange
    }
  }
}

struct WatchStatusRow: View {
  let status: MirrorSyncStatus

  var body: some View {
    Label {
      VStack(alignment: .leading, spacing: 2) {
        Text(status.title)
          .font(.headline)
        Text(status.subtitle)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    } icon: {
      Image(systemName: status.systemImage)
    }
    .accessibilityElement(children: .combine)
  }
}

struct WatchAttentionRow: View {
  let item: MobileAttentionItem
  let canSubmit: Bool
  let submit: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Image(systemName: symbol)
            .foregroundStyle(color)
            .accessibilityHidden(true)
          Text(item.title)
            .font(.headline)
        }
        Text(item.subtitle)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      .accessibilityElement(children: .combine)
      if item.commandKind != nil && canSubmit {
        Button(action: submit) {
          Label("Send", systemImage: "paperplane")
        }
      }
    }
  }

  private var symbol: String {
    switch item.kind {
    case .acpDecision: "lock.shield"
    case .pullRequest: "arrow.triangle.pull"
    case .taskBoard: "list.bullet.clipboard"
    case .blockedAgent: "person.fill.questionmark"
    case .commandFailure: "xmark.octagon"
    case .stationHealth: "desktopcomputer.trianglebadge.exclamationmark"
    }
  }

  private var color: Color {
    switch item.severity {
    case .critical: .red
    case .warning: .orange
    case .info: .secondary
    }
  }
}
