import AppKit
import HarnessMonitorKit
import SwiftUI

public struct OpenRecentView: View {
  public let store: HarnessMonitorStore
  public let refresh: (() -> Void)?
  @Environment(\.openWindow)
  private var openWindow
  @Environment(\.dismiss)
  private var dismiss
  @Environment(\.harnessDateTimeConfiguration)
  private var dateTimeConfiguration
  @Environment(\.fontScale)
  private var fontScale
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion
  @AppStorage(OpenRecentCloseAfterPickDefaults.storageKey)
  private var closeAfterPick = OpenRecentCloseAfterPickDefaults.defaultValue
  @State private var refreshActivationCount = 0
  @State private var openFolderActivationCount = 0

  public init(
    store: HarnessMonitorStore,
    refresh: (() -> Void)? = nil
  ) {
    self.store = store
    self.refresh = refresh
  }

  private var groups: [OpenRecentProjectGroup] {
    OpenRecentProjectGroup.groups(
      from: store.sessionIndex.catalog.recentSessions,
      bookmarkedSessionIDs: store.sidebarUI.bookmarkedSessionIds
    )
  }

  public var body: some View {
    ZStack {
      Color.clear.accessibilityHidden(true)
      VStack(spacing: 0) {
        Spacer(minLength: 96 * layoutScale)
        OpenRecentStartPanel(
          groups: groups,
          dateTimeConfiguration: dateTimeConfiguration,
          refresh: refreshAction,
          openFolder: openFolderAction,
          openSession: openSession,
          closeAfterPick: $closeAfterPick
        )
        .transition(reduceMotion ? .identity : .opacity)
        Spacer(minLength: 132 * layoutScale)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      actionStateMarker
    }
    .backgroundExtensionEffect()
    .task {
      await store.prepareOpenRecentSessions()
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.openRecentRoot)
  }

  private var layoutScale: CGFloat {
    min(max(fontScale, 0.88), 1.18)
  }

  private func refreshAction() {
    refreshActivationCount += 1
    HarnessMonitorLogger.swiftui.info("Open Recent refresh action activated")
    if let refresh {
      refresh()
    } else {
      Task { await store.refreshOpenRecentSessions() }
    }
  }

  private func openFolderAction() {
    openFolderActivationCount += 1
    HarnessMonitorLogger.swiftui.info("Open Recent open folder action activated")
    store.requestOpenFolder()
  }

  private func openSession(_ sessionID: String) {
    openWindow(
      id: HarnessMonitorWindowID.main,
      value: SessionWindowToken(sessionID: sessionID)
    )
    NSApp.activate(ignoringOtherApps: true)
    if closeAfterPick {
      dismiss()
    }
  }

  @ViewBuilder private var actionStateMarker: some View {
    if HarnessMonitorUITestEnvironment.accessibilityMarkersEnabled {
      AccessibilityTextMarker(
        identifier: HarnessMonitorAccessibility.openRecentActionState,
        text: "refresh=\(refreshActivationCount);openFolder=\(openFolderActivationCount)"
      )
    }
  }
}

private struct OpenRecentStartPanel: View {
  let groups: [OpenRecentProjectGroup]
  let dateTimeConfiguration: HarnessMonitorDateTimeConfiguration
  let refresh: () -> Void
  let openFolder: () -> Void
  let openSession: (String) -> Void
  @Binding var closeAfterPick: Bool
  @Environment(\.fontScale)
  private var fontScale

  private var recentSessions: [OpenRecentSessionItem] {
    Array(groups.flatMap(\.sessions).prefix(8))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 22 * layoutScale) {
      header
      section(title: "Get Started") {
        actionButton(
          "Refresh",
          systemImage: "arrow.clockwise",
          shortcut: "⌘R",
          accessibilityID: HarnessMonitorAccessibility.openRecentRefreshButton,
          action: refresh
        )
        actionButton(
          "Open Folder",
          systemImage: "folder",
          shortcut: "⌘O",
          accessibilityID: HarnessMonitorAccessibility.openRecentOpenFolderButton,
          action: openFolder
        )
      }
      section(title: "Recent Sessions") {
        if recentSessions.isEmpty {
          Label("No recent sessions", systemImage: "clock")
            .scaledFont(.body)
            .foregroundStyle(.secondary)
            .padding(.vertical, 3)
        } else {
          ForEach(recentSessions) { item in
            OpenRecentSessionRow(
              item: item,
              dateTimeConfiguration: dateTimeConfiguration,
              openSession: openSession
            )
          }
        }
      }
      .accessibilityIdentifier(HarnessMonitorAccessibility.openRecentProjectList)
      Toggle("Close after opening a session", isOn: $closeAfterPick)
        .toggleStyle(.checkbox)
        .scaledFont(.caption)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Close Open Recent after picking a session")
        .accessibilityHint("When enabled, this welcome window closes after a session opens.")
    }
    .frame(width: panelWidth)
  }

  private var header: some View {
    HStack(spacing: 14 * layoutScale) {
      Image(systemName: "rectangle.stack.badge.play")
        .scaledFont(.system(size: 34, weight: .regular))
        .frame(width: 44 * layoutScale, height: 44 * layoutScale)
        .symbolRenderingMode(.hierarchical)
      VStack(alignment: .leading, spacing: 2) {
        Text("Open Recent Session")
          .scaledFont(.title3.weight(.semibold))
        Text("Return to active harness work")
          .scaledFont(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .center)
  }

  private func section<Content: View>(
    title: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 10 * layoutScale) {
      HStack(spacing: 10 * layoutScale) {
        Text(title.uppercased())
          .scaledFont(.caption2.weight(.semibold))
          .foregroundStyle(.tertiary)
        Rectangle()
          .fill(Color(nsColor: .separatorColor).opacity(0.45))
          .frame(height: 1)
          .accessibilityHidden(true)
      }
      content()
    }
  }

  private func actionButton(
    _ title: String,
    systemImage: String,
    shortcut: String,
    accessibilityID: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 10 * layoutScale) {
        Image(systemName: systemImage)
          .frame(width: 16 * layoutScale)
        Text(title)
        Spacer()
        OpenRecentShortcutLabel(shortcut: shortcut)
      }
      .padding(.horizontal, 6 * layoutScale)
      .padding(.vertical, 3 * layoutScale)
      .frame(maxWidth: .infinity, minHeight: 28 * layoutScale, alignment: .leading)
      .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    .scaledFont(.body)
    .harnessPlainButtonStyle()
    .foregroundStyle(.secondary)
    .background {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(.primary.opacity(0.001))
    }
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .keyboardShortcut(keyEquivalent(for: title), modifiers: .command)
    .help(title)
    .accessibilityIdentifier(accessibilityID)
  }

  private func keyEquivalent(for title: String) -> KeyEquivalent {
    title == "Refresh" ? "r" : "o"
  }

  private var layoutScale: CGFloat {
    min(max(fontScale, 0.88), 1.18)
  }

  private var panelWidth: CGFloat {
    500 * layoutScale
  }
}

private struct OpenRecentShortcutLabel: View {
  let shortcut: String

  var body: some View {
    HStack(spacing: 2) {
      ForEach(Array(shortcut.enumerated()), id: \.offset) { _, character in
        Text(String(character))
          .scaledFont(.caption.monospaced())
      }
    }
    .foregroundStyle(.tertiary)
    .accessibilityLabel(shortcut)
  }
}

private struct OpenRecentSessionRow: View {
  let item: OpenRecentSessionItem
  let dateTimeConfiguration: HarnessMonitorDateTimeConfiguration
  let openSession: (String) -> Void
  @Environment(\.fontScale)
  private var fontScale

  var body: some View {
    Button {
      openSession(item.session.sessionId)
    } label: {
      HStack(alignment: .firstTextBaseline, spacing: 10 * layoutScale) {
        Image(systemName: sessionStatusSymbol(item.session.status))
          .scaledFont(.body)
          .foregroundStyle(statusColor(for: item.session.status))
          .frame(width: 18 * layoutScale)
        VStack(alignment: .leading, spacing: 3) {
          HStack(alignment: .firstTextBaseline) {
            Text(item.session.displayTitle)
              .scaledFont(.body)
              .lineLimit(1)
            if item.isBookmarked {
              Image(systemName: "bookmark.fill")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Bookmarked")
            }
          }
          Text(metadata)
            .scaledFont(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer(minLength: 16)
        Text(item.stateText)
          .scaledFont(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 6 * layoutScale)
      .padding(.vertical, 3 * layoutScale)
      .frame(maxWidth: .infinity, minHeight: 28 * layoutScale, alignment: .leading)
      .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    .harnessPlainButtonStyle()
    .foregroundStyle(.secondary)
    .background {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(.primary.opacity(0.001))
    }
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.openRecentSessionRow(item.session.sessionId)
    )
  }

  private var metadata: String {
    let timestamp = formatTimestamp(
      item.session.lastActivityAt,
      configuration: dateTimeConfiguration
    )
    return "\(item.session.worktreeDisplayName) - \(timestamp)"
  }

  private var layoutScale: CGFloat {
    min(max(fontScale, 0.88), 1.18)
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

private struct OpenRecentProjectGroup: Identifiable {
  let id: String
  let projectName: String
  let sessions: [OpenRecentSessionItem]

  static func groups(
    from sessions: [SessionSummary],
    bookmarkedSessionIDs: Set<String>
  ) -> [Self] {
    let grouped = Dictionary(grouping: sessions) { $0.projectId }
    return grouped.values.map { projectSessions in
      let sortedSessions = projectSessions.map {
        OpenRecentSessionItem(
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

private struct OpenRecentSessionItem: Identifiable {
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
