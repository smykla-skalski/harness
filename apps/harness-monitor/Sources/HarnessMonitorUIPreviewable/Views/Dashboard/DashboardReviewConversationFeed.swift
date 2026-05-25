import Foundation
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
  private static let timelineRowBatchSize = 16

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
  @State private var visibleTimelineRowLimit = Self.timelineRowBatchSize
  @State private var resolvedPreferences = DashboardReviewsResolvedPreferences(
    storedValue: UserDefaults.standard.string(forKey: DashboardReviewsPreferences.storageKey) ?? ""
  )

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
    let preferences = resolvedPreferences.preferences
    let viewModel = store.reviewTimelineViewModel(for: item.pullRequestID)

    VStack(alignment: .leading, spacing: 8) {
      if preferences.showActivityTimeline {
        DashboardReviewConversationStatusBar(
          loadState: viewModel.loadState,
          entriesCount: viewModel.entries.count,
          fontScale: fontScale,
          onRefresh: { Task { await refresh() } }
        )
        .equatable()
        errorStrip(viewModel)
        content(viewModel: viewModel, rowSource: rowSource, preferences: preferences)
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
    .onChange(of: item.pullRequestID, initial: true) { _, _ in
      visibleTimelineRowLimit = Self.timelineRowBatchSize
      rowSource.clear()
    }
    .onChange(of: storedPreferences, initial: true) { _, newValue in
      let nextPreferences = DashboardReviewsResolvedPreferences(storedValue: newValue)
      guard nextPreferences != resolvedPreferences else { return }
      resolvedPreferences = nextPreferences
    }
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
        .font(captionFont)
    }
  }

  private func refresh() async {
    await store.prepareReviewTimeline(for: item, forceRefresh: true)
  }

  @ViewBuilder
  private func content(
    viewModel: ReviewTimelineViewModel,
    rowSource: ReviewConversationRowSource,
    preferences: DashboardReviewsPreferences
  ) -> some View {
    if rowSource.rows.isEmpty && viewModel.loadState == .loadingInitial {
      ProgressView().controlSize(.small)
    } else if rowSource.rows.isEmpty {
      Text("No activity yet on this PR.")
        .foregroundStyle(.secondary)
        .font(subheadlineFont)
    } else {
      let visibleRows = rowSource.rows.prefix(visibleTimelineRowLimit)
      SessionTimelineCards(
        rows: visibleRows,
        actionHandler: actionHandler,
        onSignalTap: onSignalTap,
        avatarImageLoader: { login, avatarURL, targetPixel in
          await store.reviewAvatarImage(
            login: login,
            avatarURL: avatarURL,
            targetPixel: targetPixel
          )
        }
      )
      if hiddenTimelineRowCount > 0 {
        Button("Show \(min(Self.timelineRowBatchSize, hiddenTimelineRowCount)) more events") {
          visibleTimelineRowLimit += Self.timelineRowBatchSize
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .help("Render the next batch of review activity")
      } else if viewModel.hasOlder {
        Button("Load older") {
          Task {
            await store.loadOlderReviewTimeline(
              for: item,
              pageSize: preferences.normalizedTimelineLoadOlderBatchSize
            )
          }
        }
        .buttonStyle(.borderless)
        .disabled(viewModel.loadState == .loadingOlder)
      }
      DashboardReviewConversationPositionFooter(
        entriesCount: viewModel.entries.count,
        visibleRowsCount: visibleRows.count,
        totalRowsCount: rowSource.rows.count,
        hasOlder: viewModel.hasOlder,
        fontScale: fontScale
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
      fontScale: fontScale,
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
    let showsActivity = preferences.showActivityTimeline.description
    let collapsesHeavyThreads = preferences.timelineAutoCollapseHeavyReviewThreads.description
    return "\(viewModel.revision):\(cursor):\(zone):\(preferences.timelineHiddenKindsRaw):"
      + "\(showsActivity):\(collapsesHeavyThreads)"
  }

  private func loadKey(_ preferences: DashboardReviewsPreferences) -> ReviewTimelineTaskKey {
    ReviewTimelineTaskKey(
      item: item,
      isDaemonOnline: store.connectionState == .online,
      pageSize: preferences.normalizedTimelineInitialPageSize,
      isActive: preferences.showActivityTimeline
    )
  }

  private var hiddenTimelineRowCount: Int {
    max(rowSource.rows.count - visibleTimelineRowLimit, 0)
  }

  private var captionFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption, by: fontScale)
  }

  private var subheadlineFont: Font {
    HarnessMonitorTextSize.scaledFont(.subheadline, by: fontScale)
  }
}
