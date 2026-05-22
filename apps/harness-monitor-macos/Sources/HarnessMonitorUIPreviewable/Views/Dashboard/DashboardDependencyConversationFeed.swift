import HarnessMonitorKit
import SwiftUI

/// Conversation feed for the Dependencies detail pane: chronological
/// timeline + comment composer pinned at the bottom.
///
/// Resolves the per-PR `DependencyUpdateTimelineViewModel` from the
/// store, builds `SessionTimelineNode` rows via the dedicated PR
/// node-builder, and feeds them through the existing
/// `SessionTimelineCards` renderer. Triggers
/// `prepareDependencyUpdateTimeline` on appear so the cache fills the
/// first page asynchronously without blocking the detail-pane mount.
///
/// This is the constrained-scope wiring landing while the plan's
/// full detail-pane restructure (§5) is blocked on the parallel
/// agent's `DashboardDependencyFilesSection` — Phase D-strict comes
/// later when that file lands on main.
struct DashboardDependencyConversationFeed: View {
  let item: DependencyUpdateItem
  let store: HarnessMonitorStore
  let onSignalTap: ((String) -> Void)?
  let actionHandler: any DecisionActionHandler
  let showsComposer: Bool
  @Environment(\.harnessDateTimeConfiguration) private var dateTimeConfiguration
  @Environment(\.fontScale) private var fontScale
  @AppStorage(DashboardDependenciesPreferences.storageKey)
  private var storedPreferences = ""
  @State private var rows: [SessionTimelineRow] = []
  @State private var generation: UInt64 = 0

  init(
    item: DependencyUpdateItem,
    store: HarnessMonitorStore,
    actionHandler: any DecisionActionHandler,
    onSignalTap: ((String) -> Void)? = nil,
    showsComposer: Bool = true
  ) {
    self.item = item
    self.store = store
    self.actionHandler = actionHandler
    self.onSignalTap = onSignalTap
    self.showsComposer = showsComposer
  }

  var body: some View {
    let preferences = decodedPreferences()
    let viewModel = store.dependencyUpdateTimelineViewModel(for: item.pullRequestID)

    VStack(alignment: .leading, spacing: 8) {
      if preferences.showActivityTimeline {
        statusStrip(viewModel)
        content(viewModel)
      }
      if showsComposer {
        composer(viewModel)
      }
    }
    .task(id: item.pullRequestID) {
      guard preferences.showActivityTimeline else { return }
      await store.prepareDependencyUpdateTimeline(for: item)
    }
    .task(id: rebuildKey(viewModel, preferences: preferences)) {
      guard preferences.showActivityTimeline else {
        rows = []
        return
      }
      await rebuildRows(for: viewModel, preferences: preferences)
    }
  }

  private func decodedPreferences() -> DashboardDependenciesPreferences {
    DashboardDependenciesStorageCodec.decode(
      DashboardDependenciesPreferences.self,
      from: storedPreferences
    ) ?? DashboardDependenciesPreferences()
  }

  // The detail view wraps this feed in a
  // `DashboardDependencyDetailSection(title: "Conversation")` so the
  // section header already provides the label. Emit only the status
  // indicators here (loading spinner during refresh, error chip on
  // failure); the empty/initial loading + empty-state copy lives in
  // `content(_:)` below.
  @ViewBuilder
  private func statusStrip(_ viewModel: DependencyUpdateTimelineViewModel) -> some View {
    if viewModel.loadState == .refreshing {
      HStack(spacing: 8) {
        HarnessMonitorSpinner(size: 12)
        Text("Refreshing…").font(.caption).foregroundStyle(.secondary)
        Spacer()
      }
    } else if let error = viewModel.lastError {
      Label(error, systemImage: "exclamationmark.triangle")
        .foregroundStyle(.orange)
        .font(.caption)
    }
  }

  @ViewBuilder
  private func content(_ viewModel: DependencyUpdateTimelineViewModel) -> some View {
    if rows.isEmpty && viewModel.loadState == .loadingInitial {
      ProgressView().controlSize(.small)
    } else if rows.isEmpty {
      Text("No activity yet on this PR.")
        .foregroundStyle(.secondary)
        .font(.subheadline)
    } else {
      SessionTimelineCards(
        rows: rows,
        actionHandler: actionHandler,
        onSignalTap: onSignalTap
      )
      if viewModel.hasOlder {
        Button("Load older") {
          Task { await store.loadOlderDependencyUpdateTimeline(for: item) }
        }
        .buttonStyle(.borderless)
        .disabled(viewModel.loadState == .loadingOlder)
      }
    }
  }

  @ViewBuilder
  private func composer(_ viewModel: DependencyUpdateTimelineViewModel) -> some View {
    DashboardDependencyCommentComposer(
      pullRequestID: item.pullRequestID,
      initialDraft: store.dependencyUpdateCommentDraft(for: item.pullRequestID),
      viewerCanComment: viewModel.viewerCanComment,
      onDraftChange: { draft in
        store.scheduleDependencyUpdateDraftWrite(item.pullRequestID, draft: draft)
      },
      onSend: { body in
        await store.postDependencyUpdateComment(for: item, body: body)
      }
    )
  }

  private func rebuildKey(
    _ viewModel: DependencyUpdateTimelineViewModel,
    preferences: DashboardDependenciesPreferences
  ) -> String {
    let zone = dateTimeConfiguration.customTimeZoneIdentifier
    let cursor = viewModel.startCursor ?? ""
    return "\(viewModel.entries.count):\(cursor):\(zone):\(preferences.timelineHiddenKindsRaw)"
  }

  private func rebuildRows(
    for viewModel: DependencyUpdateTimelineViewModel,
    preferences: DashboardDependenciesPreferences
  ) async {
    generation &+= 1
    let snapshot = generation
    let entries = viewModel.entries
    let configuration = dateTimeConfiguration
    let hiddenKinds = preferences.timelineHiddenKinds
    let nodes = await Task.detached(priority: .userInitiated) { () -> [SessionTimelineNode] in
      DependencyPullRequestTimelineNodeBuilder().buildNodes(
        for: entries,
        pullRequestID: "",
        hiddenKinds: hiddenKinds,
        configuration: configuration
      )
    }.value
    guard !Task.isCancelled, generation == snapshot else { return }
    let computed = SessionTimelineRow.rows(for: nodes, configuration: configuration)
    rows = computed
  }
}
