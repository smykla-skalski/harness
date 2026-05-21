import HarnessMonitorKit
import SwiftUI

public struct OpenRecentView: View {
  public let store: HarnessMonitorStore
  @Environment(\.openWindow)
  var openWindow
  @Environment(\.dismiss)
  var dismiss
  @Environment(\.harnessDateTimeConfiguration)
  var dateTimeConfiguration
  @Environment(\.fontScale)
  var fontScale
  @Environment(\.accessibilityReduceMotion)
  var reduceMotion
  @AppStorage(OpenRecentCloseAfterPickDefaults.storageKey)
  var closeAfterPick = OpenRecentCloseAfterPickDefaults.defaultValue
  @State private var openFolderActivationCount = 0
  @State private var newSessionActivationCount = 0
  @State private var showsStartPanel = true

  public init(store: HarnessMonitorStore) {
    self.store = store
  }

  var recentSessions: [OpenRecentSessionItem] {
    let bookmarkedSessionIDs = store.sidebarUI.bookmarkedSessionIds
    return store.sessionIndex.catalog.recentSessions.prefix(8).map {
      OpenRecentSessionItem(
        session: $0,
        isBookmarked: bookmarkedSessionIDs.contains($0.sessionId)
      )
    }
  }

  public var body: some View {
    ZStack {
      Color.clear.accessibilityHidden(true)
      Group {
        if showsStartPanel {
          OpenRecentStartPanel(
            recentSessions: recentSessions,
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
    .harnessMonitorBackgroundExtensionEffect()
    .task {
      guard !HarnessMonitorUITestEnvironment.isPerfScenarioActive else {
        return
      }
      await store.prepareOpenRecentSessions()
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.openRecentRoot)
  }

  var layoutScale: CGFloat {
    min(max(fontScale, 0.88), 1.18)
  }

  func openFolderAction() {
    openFolderActivationCount += 1
    HarnessMonitorLogger.swiftui.info("Open Recent open folder action activated")
    store.requestOpenFolder()
  }

  func newSessionAction() {
    newSessionActivationCount += 1
    HarnessMonitorLogger.swiftui.info("Open Recent new session action activated")
    store.presentedSheet = .newSession
  }

  func openSession(_ sessionID: String) {
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
  func dismissCurrentWindow() async {
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

  @ViewBuilder var actionStateMarker: some View {
    if HarnessMonitorUITestEnvironment.accessibilityMarkersEnabled {
      AccessibilityTextMarker(
        identifier: HarnessMonitorAccessibility.openRecentActionState,
        text: "openFolder=\(openFolderActivationCount);newSession=\(newSessionActivationCount)"
      )
    }
  }
}

struct OpenRecentStartPanel: View {
  let recentSessions: [OpenRecentSessionItem]
  let dateTimeConfiguration: HarnessMonitorDateTimeConfiguration
  let openFolder: () -> Void
  let newSession: () -> Void
  let openSession: (String) -> Void
  @Environment(\.fontScale)
  var fontScale

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

  var header: some View {
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

  var content: some View {
    VStack(alignment: .leading, spacing: sectionSpacing) {
      section(title: "Get Started") {
        actionButton(
          "New Session",
          systemImage: "plus.square",
          shortcut: .init(modifiers: [.command], keyEquivalent: "n", keyLabel: "N"),
          accessibilityID: HarnessMonitorAccessibility.openRecentNewSessionButton,
          action: newSession
        )
        actionButton(
          "Open Folder",
          systemImage: "folder",
          shortcut: .init(modifiers: [.command], keyEquivalent: "o", keyLabel: "O"),
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

  func section<Content: View>(
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

  func actionButton(
    _ title: String,
    systemImage: String,
    shortcut: KeyboardShortcutDescriptor,
    accessibilityID: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 10 * layoutScale) {
        Image(systemName: systemImage)
          .frame(width: 16 * layoutScale)
        Text(title)
        Spacer()
        KeyboardShortcutLabel(shortcut: shortcut)
      }
      .padding(.horizontal, 6 * layoutScale)
      .padding(.vertical, 3 * layoutScale)
      .frame(maxWidth: .infinity, minHeight: 28 * layoutScale, alignment: .leading)
      .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    .scaledFont(.body)
    .harnessActionButtonStyle(variant: .borderless)
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

  func keyEquivalent(for title: String) -> KeyEquivalent {
    switch title {
    case "Open Folder": "o"
    case "New Session": "n"
    default: "o"
    }
  }

  var layoutScale: CGFloat {
    min(max(fontScale, 0.88), 1.18)
  }

  var panelWidth: CGFloat {
    500 * layoutScale
  }

  var sectionSpacing: CGFloat {
    22 * layoutScale
  }
}

struct OpenRecentSessionRow: View {
  let item: OpenRecentSessionItem
  let dateTimeConfiguration: HarnessMonitorDateTimeConfiguration
  let openSession: (String) -> Void
  @Environment(\.fontScale)
  var fontScale

  var body: some View {
    Button {
      openSession(item.session.sessionId)
    } label: {
      HStack(alignment: .firstTextBaseline, spacing: 10 * layoutScale) {
        OpenRecentSessionStatusDot(status: item.session.status)
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
    .harnessActionButtonStyle(variant: .borderless)
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

  var metadata: String {
    let timestamp = formatTimestamp(
      item.session.lastActivityAt,
      configuration: dateTimeConfiguration
    )
    return "\(item.session.worktreeDisplayName) - \(timestamp)"
  }

  var layoutScale: CGFloat {
    min(max(fontScale, 0.88), 1.18)
  }
}

struct OpenRecentSessionStatusDot: View {
  let status: SessionStatus
  @Environment(\.fontScale)
  var fontScale

  var body: some View {
    Circle()
      .fill(statusColor(for: status))
      .frame(width: dotSize, height: dotSize)
      .accessibilityHidden(true)
  }

  var dotSize: CGFloat {
    8 * min(max(fontScale, 0.88), 1.18)
  }
}
