import HarnessMonitorKit
import SwiftUI

public struct WelcomeRecentsView: View {
  public let store: HarnessMonitorStore
  @Environment(\.openWindow)
  private var openWindow
  @Environment(\.harnessDateTimeConfiguration)
  private var dateTimeConfiguration

  public init(store: HarnessMonitorStore) {
    self.store = store
  }

  private var groups: [WelcomeRecentsProjectGroup] {
    WelcomeRecentsProjectGroup.groups(
      from: store.sessionIndex.catalog.recentSessions,
      bookmarkedSessionIDs: store.sidebarUI.bookmarkedSessionIds
    )
  }

  public var body: some View {
    NavigationStack {
      List {
        if groups.isEmpty {
          ContentUnavailableView(
            "No Recent Sessions",
            systemImage: "clock",
            description: Text("Start or attach a session to make it available here.")
          )
        } else {
          ForEach(groups) { group in
            Section(group.projectName) {
              ForEach(group.sessions) { item in
                WelcomeRecentSessionRow(
                  item: item,
                  dateTimeConfiguration: dateTimeConfiguration,
                  openSession: openSession
                )
              }
            }
          }
        }
      }
      .listStyle(.inset)
      .navigationTitle("Welcome Recents")
      .accessibilityIdentifier(HarnessMonitorAccessibility.welcomeRecentsProjectList)
      .toolbar {
        ToolbarItemGroup {
          Button {
            Task { await store.manualRefresh() }
          } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
          }
          Button {
            store.openFolderRequest += 1
          } label: {
            Label("Open Folder", systemImage: "folder")
          }
        }
      }
    }
    .backgroundExtensionEffect()
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.welcomeRecentsRoot)
  }

  private func openSession(_ sessionID: String) {
    openWindow(
      id: HarnessMonitorWindowID.session,
      value: SessionWindowToken(sessionID: sessionID)
    )
  }
}

private struct WelcomeRecentSessionRow: View {
  let item: WelcomeRecentsSessionItem
  let dateTimeConfiguration: HarnessMonitorDateTimeConfiguration
  let openSession: (String) -> Void

  var body: some View {
    Button {
      openSession(item.session.sessionId)
    } label: {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Image(systemName: sessionStatusSymbol(item.session.status))
          .foregroundStyle(statusColor(for: item.session.status))
          .frame(width: 18)
        VStack(alignment: .leading, spacing: 3) {
          HStack(alignment: .firstTextBaseline) {
            Text(item.session.displayTitle)
              .lineLimit(1)
            if item.isBookmarked {
              Image(systemName: "bookmark.fill")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Bookmarked")
            }
          }
          Text(metadata)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer(minLength: 16)
        Text(item.stateText)
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      .contentShape(Rectangle())
    }
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.welcomeRecentSessionRow(item.session.sessionId)
    )
  }

  private var metadata: String {
    let timestamp = formatTimestamp(
      item.session.lastActivityAt,
      configuration: dateTimeConfiguration
    )
    return "\(item.session.worktreeDisplayName) - \(timestamp)"
  }
}

private func sessionStatusSymbol(_ status: SessionStatus) -> String {
  switch status {
  case .active: "play.circle"
  case .awaitingLeader: "person.crop.circle.badge.clock"
  case .leaderlessDegraded: "exclamationmark.triangle"
  case .paused: "pause.circle"
  case .ended: "checkmark.circle"
  }
}

private struct WelcomeRecentsProjectGroup: Identifiable {
  let id: String
  let projectName: String
  let sessions: [WelcomeRecentsSessionItem]

  static func groups(
    from sessions: [SessionSummary],
    bookmarkedSessionIDs: Set<String>
  ) -> [Self] {
    let grouped = Dictionary(grouping: sessions) { $0.projectId }
    return grouped.values.map { projectSessions in
      let sortedSessions = projectSessions.map {
        WelcomeRecentsSessionItem(
          session: $0,
          isBookmarked: bookmarkedSessionIDs.contains($0.sessionId)
        )
      }
      let first = projectSessions[0]
      return Self(
        id: first.projectId,
        projectName: first.projectName,
        sessions: sortedSessions
      )
    }
    .sorted { $0.projectName.localizedCaseInsensitiveCompare($1.projectName) == .orderedAscending }
  }
}

private struct WelcomeRecentsSessionItem: Identifiable {
  let session: SessionSummary
  let isBookmarked: Bool

  var id: String { session.sessionId }

  var stateText: String {
    if session.externalOrigin != nil {
      return "Attached"
    }
    if session.adoptedAt != nil {
      return "Adopted"
    }
    return session.status.title
  }
}
