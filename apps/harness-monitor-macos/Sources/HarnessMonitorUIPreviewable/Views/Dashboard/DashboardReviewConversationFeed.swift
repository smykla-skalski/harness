import HarnessMonitorKit
import SwiftUI

/// Conversation feed for the Reviews detail pane: chronological
/// timeline + comment composer pinned at the bottom.
///
/// Resolves the per-PR `ReviewTimelineViewModel` from the
/// store, builds `SessionTimelineNode` rows via the dedicated PR
/// node-builder, and feeds them through the existing
/// `SessionTimelineCards` renderer. Triggers
/// `prepareReviewTimeline` on appear so the cache fills the
/// first page asynchronously without blocking the detail-pane mount.
///
/// This is the constrained-scope wiring landing while the plan's
/// full detail-pane restructure (§5) is blocked on the parallel
/// agent's `DashboardReviewFilesSection` — Phase D-strict comes
/// later when that file lands on main.
struct DashboardReviewConversationFeed: View {
  let item: ReviewItem
  let store: HarnessMonitorStore
  let onSignalTap: ((String) -> Void)?
  let actionHandler: any DecisionActionHandler
  let showsComposer: Bool
  @Environment(\.harnessDateTimeConfiguration)
  private var dateTimeConfiguration
  @Environment(\.fontScale)
  private var fontScale
  @AppStorage(DashboardReviewsPreferences.storageKey)
  private var storedPreferences = ""
  // Per-feed @Observable @MainActor row source — owns the built rows
  // + the generation counter + the off-main rebuild task. Extracting
  // into a class lets future flat-LazyVStack restructures hand the
  // same source to a sibling rows-region view without duplicating the
  // build work. See `ReviewConversationRowSource`.
  @State private var rowSource = ReviewConversationRowSource()

  init(
    item: ReviewItem,
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
    let viewModel = store.reviewTimelineViewModel(for: item.pullRequestID)

    VStack(alignment: .leading, spacing: 8) {
      if preferences.showActivityTimeline {
        DashboardReviewConversationStatusBar(
          loadState: viewModel.loadState,
          entriesCount: viewModel.entries.count,
          onRefresh: { Task { await refresh() } }
        )
        .equatable()
        errorStrip(viewModel)
        content(viewModel: viewModel, rowSource: rowSource)
      }
      if showsComposer {
        composer(viewModel)
      }
    }
    .task(id: loadKey(preferences)) {
      guard preferences.showActivityTimeline else { return }
      await store.prepareReviewTimeline(
        for: item,
        pageSize: preferences.normalizedTimelineInitialPageSize
      )
    }
    .task(id: rebuildKey(viewModel, preferences: preferences)) {
      guard preferences.showActivityTimeline else {
        rowSource.clear()
        return
      }
      await rowSource.refresh(
        entries: viewModel.entries,
        hiddenKinds: preferences.timelineHiddenKinds,
        autoCollapseHeavyReviewThreads: preferences.timelineAutoCollapseHeavyReviewThreads,
        configuration: dateTimeConfiguration
      )
    }
  }

  private func decodedPreferences() -> DashboardReviewsPreferences {
    DashboardReviewsStorageCodec.decode(
      DashboardReviewsPreferences.self,
      from: storedPreferences
    ) ?? DashboardReviewsPreferences()
  }

  // The status bar above owns "Refreshing…" and the refresh button;
  // this strip only surfaces transient load errors (e.g. a daemon
  // timeout). Composer-side errors render via
  // `DashboardReviewCommentRetryStrip`.
  @ViewBuilder
  private func errorStrip(_ viewModel: ReviewTimelineViewModel) -> some View {
    if let error = viewModel.lastError {
      Label(error, systemImage: "exclamationmark.triangle")
        .foregroundStyle(.orange)
        .font(.caption)
    }
  }

  private func refresh() async {
    await store.prepareReviewTimeline(for: item, forceRefresh: true)
  }

  @ViewBuilder
  private func content(
    viewModel: ReviewTimelineViewModel,
    rowSource: ReviewConversationRowSource
  ) -> some View {
    if rowSource.rows.isEmpty && viewModel.loadState == .loadingInitial {
      ProgressView().controlSize(.small)
    } else if rowSource.rows.isEmpty {
      Text("No activity yet on this PR.")
        .foregroundStyle(.secondary)
        .font(.subheadline)
    } else {
      SessionTimelineCards(
        rows: rowSource.rows,
        actionHandler: actionHandler,
        onSignalTap: onSignalTap
      )
      if viewModel.hasOlder {
        Button("Load older") {
          Task {
            await store.loadOlderReviewTimeline(
              for: item,
              pageSize: decodedPreferences().normalizedTimelineLoadOlderBatchSize
            )
          }
        }
        .buttonStyle(.borderless)
        .disabled(viewModel.loadState == .loadingOlder)
      }
      DashboardReviewConversationPositionFooter(
        entriesCount: viewModel.entries.count,
        hasOlder: viewModel.hasOlder
      )
      .equatable()
    }
  }

  @ViewBuilder
  private func composer(_ viewModel: ReviewTimelineViewModel) -> some View {
    DashboardReviewCommentComposer(
      pullRequestID: item.pullRequestID,
      initialDraft: store.reviewCommentDraft(for: item.pullRequestID),
      viewerCanComment: viewModel.viewerCanComment,
      onDraftChange: { draft in
        store.scheduleReviewDraftWrite(item.pullRequestID, draft: draft)
      },
      onSend: { body in
        await store.postReviewComment(for: item, body: body)
      }
    )
  }

  private func rebuildKey(
    _ viewModel: ReviewTimelineViewModel,
    preferences: DashboardReviewsPreferences
  ) -> String {
    let zone = dateTimeConfiguration.customTimeZoneIdentifier
    let cursor = viewModel.startCursor ?? ""
    return [
      "\(viewModel.revision)",
      cursor,
      zone,
      preferences.timelineHiddenKindsRaw,
      preferences.showActivityTimeline.description,
      preferences.timelineAutoCollapseHeavyReviewThreads.description,
    ].joined(separator: ":")
  }

  private func loadKey(_ preferences: DashboardReviewsPreferences) -> String {
    [
      item.pullRequestID,
      preferences.showActivityTimeline.description,
      "\(preferences.normalizedTimelineInitialPageSize)",
    ].joined(separator: ":")
  }

}
