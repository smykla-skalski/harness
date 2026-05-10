import HarnessMonitorKit
import SwiftUI

public struct OpenRecentView: View {
  public let store: HarnessMonitorStore
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
  @State private var openFolderActivationCount = 0
  @State private var newSessionActivationCount = 0
  @State private var showsStartPanel = true

  public init(store: HarnessMonitorStore) {
    self.store = store
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
      Group {
        if showsStartPanel {
          OpenRecentStartPanel(
            groups: groups,
            dateTimeConfiguration: dateTimeConfiguration,
            openFolder: openFolderAction,
            newSession: newSessionAction,
            openSession: openSession
          )
          .transition(OpenRecentCloseAfterPickMotionPolicy.transition(reduceMotion: reduceMotion))
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      actionStateMarker
    }
    .backgroundExtensionEffect()
    .task {
      guard !HarnessMonitorUITestEnvironment.isPerfScenarioActive else {
        return
      }
      await store.prepareOpenRecentSessions()
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.openRecentRoot)
  }

  private var layoutScale: CGFloat {
    min(max(fontScale, 0.88), 1.18)
  }

  private func openFolderAction() {
    openFolderActivationCount += 1
    HarnessMonitorLogger.swiftui.info("Open Recent open folder action activated")
    store.requestOpenFolder()
  }

  private func newSessionAction() {
    newSessionActivationCount += 1
    HarnessMonitorLogger.swiftui.info("Open Recent new session action activated")
    store.presentedSheet = .newSession
  }

  private func openSession(_ sessionID: String) {
    let shouldCloseAfterPick = closeAfterPick
    openWindow.openHarnessSessionWindow(sessionID: sessionID)
    guard shouldCloseAfterPick else {
      return
    }
    Task { @MainActor in
      // Let SwiftUI create and focus the new session window before dismissing
      // the current Open Recent window.
      await Task.yield()
      await dismissCurrentWindow()
    }
  }

  @MainActor
  private func dismissCurrentWindow() async {
    let animation = OpenRecentCloseAfterPickMotionPolicy.animation(reduceMotion: reduceMotion)
    if let animation {
      withAnimation(animation) {
        showsStartPanel = false
      }
    } else {
      showsStartPanel = false
    }
    let delay = OpenRecentCloseAfterPickMotionPolicy.dismissDelay(reduceMotion: reduceMotion)
    if delay != .zero {
      try? await Task.sleep(for: delay)
    }
    dismiss()
  }

  @ViewBuilder private var actionStateMarker: some View {
    if HarnessMonitorUITestEnvironment.accessibilityMarkersEnabled {
      AccessibilityTextMarker(
        identifier: HarnessMonitorAccessibility.openRecentActionState,
        text: "openFolder=\(openFolderActivationCount);newSession=\(newSessionActivationCount)"
      )
    }
  }
}

private struct OpenRecentStartPanel: View {
  let groups: [OpenRecentProjectGroup]
  let dateTimeConfiguration: HarnessMonitorDateTimeConfiguration
  let openFolder: () -> Void
  let newSession: () -> Void
  let openSession: (String) -> Void
  @Environment(\.fontScale)
  private var fontScale

  private var recentSessions: [OpenRecentSessionItem] {
    Array(groups.flatMap(\.sessions).prefix(8))
  }

  var body: some View {
    OpenRecentStartPanelLayout(
      topInset: 96 * layoutScale,
      bottomInset: 132 * layoutScale,
      headerSpacing: sectionSpacing
    ) {
      header
      content
    }
    .frame(width: panelWidth)
    .frame(maxHeight: .infinity, alignment: .top)
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

  private var content: some View {
    VStack(alignment: .leading, spacing: sectionSpacing) {
      section(title: "Get Started") {
        actionButton(
          "New Session",
          systemImage: "plus.square",
          shortcut: "⌘N",
          accessibilityID: HarnessMonitorAccessibility.openRecentNewSessionButton,
          action: newSession
        )
        actionButton(
          "Open Folder",
          systemImage: "folder",
          shortcut: "⌘O",
          accessibilityID: HarnessMonitorAccessibility.openRecentOpenFolderButton,
          action: openFolder
        )
      }
      section(
        title: "Recent Sessions",
        accessibilityMarkerID: HarnessMonitorAccessibility.openRecentProjectList
      ) {
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
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func section<Content: View>(
    title: String,
    accessibilityMarkerID: String? = nil,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 10 * layoutScale) {
      HStack(spacing: 10 * layoutScale) {
        Text(title.uppercased())
          .scaledFont(.caption2.weight(.semibold))
          .foregroundStyle(.tertiary)
        Rectangle()
          .fill(Color.secondary.opacity(0.18))
          .frame(height: 1)
          .accessibilityHidden(true)
      }
      content()
    }
    .overlay {
      if let accessibilityMarkerID {
        AccessibilityTextMarker(identifier: accessibilityMarkerID, text: title)
      }
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
    switch title {
    case "Open Folder": "o"
    case "New Session": "n"
    default: "o"
    }
  }

  private var layoutScale: CGFloat {
    min(max(fontScale, 0.88), 1.18)
  }

  private var panelWidth: CGFloat {
    500 * layoutScale
  }

  private var sectionSpacing: CGFloat {
    22 * layoutScale
  }
}

private struct OpenRecentStartPanelLayout: Layout {
  let topInset: CGFloat
  let bottomInset: CGFloat
  let headerSpacing: CGFloat

  func sizeThatFits(
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache _: inout ()
  ) -> CGSize {
    let width = proposal.width ?? 0
    let fittedProposal = ProposedViewSize(width: width > 0 ? width : nil, height: nil)
    let headerSize = measuredSize(for: 0, subviews: subviews, proposal: fittedProposal)
    let contentSize = measuredSize(for: 1, subviews: subviews, proposal: fittedProposal)
    let naturalHeight =
      topInset + headerSize.height + headerSpacing + contentSize.height + bottomInset
    return CGSize(
      width: width > 0 ? width : max(headerSize.width, contentSize.width),
      height: proposal.height ?? naturalHeight
    )
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal _: ProposedViewSize,
    subviews: Subviews,
    cache _: inout ()
  ) {
    let fittedProposal = ProposedViewSize(width: bounds.width, height: nil)
    let headerSize = measuredSize(for: 0, subviews: subviews, proposal: fittedProposal)
    let contentSize = measuredSize(for: 1, subviews: subviews, proposal: fittedProposal)
    let contentAreaTop = bounds.minY + topInset
    let contentAreaHeight = max(bounds.height - topInset - bottomInset, contentSize.height)
    let contentTop = contentAreaTop + max((contentAreaHeight - contentSize.height) / 2, 0)
    let headerTop = max(bounds.minY + topInset, contentTop - headerSpacing - headerSize.height)
    let placementProposal = ProposedViewSize(width: bounds.width, height: nil)

    subviews[0].place(
      at: CGPoint(x: bounds.minX, y: headerTop),
      anchor: .topLeading,
      proposal: placementProposal
    )
    subviews[1].place(
      at: CGPoint(x: bounds.minX, y: contentTop),
      anchor: .topLeading,
      proposal: placementProposal
    )
  }

  private func measuredSize(
    for index: Int,
    subviews: Subviews,
    proposal: ProposedViewSize
  ) -> CGSize {
    guard subviews.indices.contains(index) else {
      return .zero
    }
    return subviews[index].sizeThatFits(proposal)
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
    .accessibilityFrameMarker(
      "\(HarnessMonitorAccessibility.openRecentSessionRow(item.session.sessionId)).frame"
    )
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

enum OpenRecentCloseAfterPickMotionPolicy {
  static let animatedDismissDuration: Double = 0.16

  static func animation(reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : .easeOut(duration: animatedDismissDuration)
  }

  static func transition(reduceMotion: Bool) -> AnyTransition {
    reduceMotion ? .identity : .opacity
  }

  static func dismissDelay(reduceMotion: Bool) -> Duration {
    reduceMotion ? .zero : .milliseconds(Int(animatedDismissDuration * 1000))
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
