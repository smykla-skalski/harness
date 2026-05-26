import HarnessMonitorCore
import HarnessMonitorMirrorStore
import SwiftUI

/// Typed navigation route for opening a mirrored session on the watch. `sourceID`
/// names the tapped row's zoom-transition source so two attention items pointing at
/// one session do not collide on a shared id.
struct WatchSessionDetailRoute: Hashable {
  let sessionID: String
  let sourceID: String
}

/// Compact detail for a mirrored session reached from a blocked-agent or ACP
/// "Needs You" item: the session context plus the same canned response the
/// attention row's Send button queued, so the watch keeps that quick action.
struct WatchSessionDetailView: View {
  @Environment(MirrorStore.self)
  private var store
  let sessionID: String
  let sourceID: String
  let zoom: Namespace.ID

  @State private var pendingRespond = false

  private var session: MobileSessionSummary? {
    store.snapshot.sessions.first { $0.id == sessionID }
  }

  /// The blocked-agent or ACP attention this session is waiting on, if still live.
  private var relatedAttention: MobileAttentionItem? {
    store.snapshot.sortedAttention.first {
      ($0.kind == .blockedAgent || $0.kind == .acpDecision)
        && $0.target?.sessionID == sessionID
    }
  }

  var body: some View {
    List {
      if let session {
        header(session)
        actions
      } else {
        ContentUnavailableView(
          "Session no longer mirrored",
          systemImage: "rectangle.stack"
        )
      }
    }
    .navigationTitle("Session")
    .navigationTransition(.zoom(sourceID: sourceID, in: zoom))
    .confirmationDialog(
      relatedAttention?.commandKind?.title ?? "Confirm",
      isPresented: $pendingRespond,
      titleVisibility: .visible
    ) {
      Button("Confirm") {
        guard let item = relatedAttention else {
          return
        }
        Task { await store.queueCommand(from: item) }
        pendingRespond = false
      }
      Button("Cancel", role: .cancel) { pendingRespond = false }
    } message: {
      Text(relatedAttention?.confirmationMessage ?? "")
    }
  }

  @ViewBuilder
  private func header(_ session: MobileSessionSummary) -> some View {
    Section {
      VStack(alignment: .leading, spacing: 4) {
        Text(session.title)
          .font(.headline)
        Text(verbatim: "\(session.projectName)  \(session.branch)")
          .font(.caption2)
          .foregroundStyle(.secondary)
        Text(session.status)
          .font(.caption2)
          .foregroundStyle(.secondary)
        Text("\(session.activeAgentCount) active, \(session.blockedAgentCount) waiting")
          .font(.caption2)
          .foregroundStyle(session.blockedAgentCount > 0 ? .orange : .secondary)
        if !session.summary.isEmpty {
          Text(session.summary)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(3)
        }
        Text(session.lastActivityAt, style: .relative)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      .accessibilityElement(children: .combine)
    }
  }

  @ViewBuilder
  private var actions: some View {
    if let item = relatedAttention, item.commandKind != nil,
      store.canQueueCommand(stationID: item.stationID) {
      Section {
        Button {
          pendingRespond = true
        } label: {
          Label("Send", systemImage: "paperplane")
        }
      }
    }
  }
}
