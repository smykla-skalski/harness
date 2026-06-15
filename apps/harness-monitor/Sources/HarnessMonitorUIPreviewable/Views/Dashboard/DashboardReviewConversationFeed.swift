import Foundation
import HarnessMonitorKit
import SwiftUI

enum DashboardReviewDetailScrollCoordinateSpace {
  static let name = "dashboard-review-detail-scroll"
}

/// Conversation feed for the Reviews detail pane: chronological
/// timeline with optional inline composer support.
///
/// Resolves the per-PR `ReviewTimelineViewModel` from the
/// store, builds `SessionTimelineNode` rows via the dedicated PR
/// node-builder, and feeds them through the existing
/// `SessionTimelineCards` renderer. Triggers
/// `prepareReviewTimeline` on appear so the cache fills the
/// first page asynchronously without blocking the detail-pane mount.
struct DashboardReviewConversationFeed: View {
  private static let timelineRowBatchSize = 16
  private static let oldestTimelineAnchorCount = 1
  private static let gapScrollCompensationTolerance: CGFloat = 0.25
  private static let gapScrollCompensationMaxPasses = 3

  let item: ReviewItem
  let store: HarnessMonitorStore
  let viewerLogin: String?
  let onSignalTap: ((String) -> Void)?
  let actionHandler: any DecisionActionHandler
  let onGapScrollCompensation: ((CGFloat) -> Void)?
  let showsComposer: Bool
  @Environment(\.harnessDateTimeConfiguration)
  var dateTimeConfiguration
  @Environment(\.fontScale)
  var fontScale
  @AppStorage(DashboardReviewsPreferences.storageKey)
  private var storedPreferences = ""
  // Per-feed @Observable @MainActor row source — owns the built rows
  // + the generation counter + the off-main rebuild task. Extracting
  // into a class lets future flat-LazyVStack restructures hand the
  // same source to a sibling rows-region view without duplicating the
  // build work. See `ReviewConversationRowSource`.
  @State private var rowSource = ReviewConversationRowSource()
  @State private var visibleTimelineRowLimit = Self.timelineRowBatchSize
  @State private var gapScrollAnchorViewportMinY: CGFloat?
  @State private var pendingGapScrollCompensation: PendingGapScrollCompensation?
  @State private var presentedFullContent: DashboardReviewConversationFullContent?
  @State private var fullContentCacheRevision: UInt64?
  @State private var inlineConversationCollapseRevision: UInt64 = 0
  @State private var inlineConversationCollapsedThreadIDs: [String: Bool] = [:]
  @State private var fullContentCache:
    [SessionTimelineNode.Identity: DashboardReviewConversationFullContent] = [:]
  @State private var resolvedPreferences = DashboardReviewsResolvedPreferences(
    storedValue: UserDefaults.standard.string(forKey: DashboardReviewsPreferences.storageKey) ?? ""
  )

  init(
    item: ReviewItem,
    store: HarnessMonitorStore,
    viewerLogin: String? = nil,
    actionHandler: any DecisionActionHandler,
    onSignalTap: ((String) -> Void)? = nil,
    onGapScrollCompensation: ((CGFloat) -> Void)? = nil,
    showsComposer: Bool = true
  ) {
    self.item = item
    self.store = store
    self.viewerLogin = viewerLogin
    self.actionHandler = actionHandler
    self.onSignalTap = onSignalTap
    self.onGapScrollCompensation = onGapScrollCompensation
    self.showsComposer = showsComposer
  }

  var body: some View {
    let preferences = resolvedPreferences.preferences
    let viewModel = store.reviewTimelineViewModel(for: item.pullRequestID)

    VStack(alignment: .leading, spacing: 8) {
      if preferences.showActivityTimeline {
        DashboardReviewConversationStatusBar(
          loadState: viewModel.loadState,
          countSummary: .init(
            visibleRowsCount: rowSource.rows.count,
            totalRowsCount: rowSource.rows.count,
            hasOlder: viewModel.hasOlder
          ),
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
        showActivityInlineComments: preferences.showActivityInlineComments,
        autoCollapseHeavyReviewThreads: preferences.timelineAutoCollapseHeavyReviewThreads,
        configuration: dateTimeConfiguration
      )
    }
    .onChange(of: item.pullRequestID, initial: true) { _, _ in
      visibleTimelineRowLimit = Self.timelineRowBatchSize
      gapScrollAnchorViewportMinY = nil
      pendingGapScrollCompensation = nil
      presentedFullContent = nil
      fullContentCacheRevision = nil
      inlineConversationCollapseRevision = 0
      inlineConversationCollapsedThreadIDs = [:]
      fullContentCache = [:]
      rowSource.clear()
    }
    .onChange(of: storedPreferences, initial: true) { _, newValue in
      let nextPreferences = DashboardReviewsResolvedPreferences(storedValue: newValue)
      guard nextPreferences != resolvedPreferences else { return }
      resolvedPreferences = nextPreferences
    }
    .sheet(item: $presentedFullContent) { fullContent in
      DashboardReviewConversationFullContentSheet(content: fullContent, fontScale: fontScale)
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
  func content(
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
      let window = DashboardReviewConversationVisibilityWindow(
        totalRowsCount: rowSource.rows.count,
        leadingVisibleRowsLimit: visibleTimelineRowLimit,
        batchSize: Self.timelineRowBatchSize,
        trailingAnchorCount: Self.oldestTimelineAnchorCount
      )
      let collapsedWindow = DashboardReviewConversationVisibilityWindow(
        totalRowsCount: rowSource.rows.count,
        leadingVisibleRowsLimit: Self.timelineRowBatchSize,
        batchSize: Self.timelineRowBatchSize,
        trailingAnchorCount: Self.oldestTimelineAnchorCount
      )
      let visibleTimelineHeadRows = rowSource.rows.prefix(window.leadingVisibleRowsCount)
      let visibleTimelineTailRows = rowSource.rows.suffix(window.trailingVisibleRowsCount)
      let expandedTimelineHeadRows = rowSource.rows.prefix(
        max(rowSource.rows.count - collapsedWindow.trailingVisibleRowsCount, 0)
      )
      let expandedTimelineTailRows = rowSource.rows.suffix(collapsedWindow.trailingVisibleRowsCount)
      let avatarImageLoader: TimelineAvatarImageLoader = { login, avatarURL, targetPixel in
        await store.reviewAvatarImage(
          login: login,
          avatarURL: avatarURL,
          targetPixel: targetPixel
        )
      }
      let openFullContent: (SessionTimelineNode) -> Void = { node in
        presentFullContent(for: node, entries: viewModel.entries, revision: viewModel.revision)
      }
      let region = TimelineRowsRegion(
        window: window,
        collapsedWindow: collapsedWindow,
        canHideRevealedRows: visibleTimelineRowLimit > Self.timelineRowBatchSize,
        visibleHeadRows: visibleTimelineHeadRows,
        visibleTailRows: visibleTimelineTailRows,
        expandedHeadRows: expandedTimelineHeadRows,
        expandedTailRows: expandedTimelineTailRows,
        revision: viewModel.revision,
        hasOlder: viewModel.hasOlder,
        isLoadingOlder: viewModel.loadState == .loadingOlder,
        avatarImageLoader: avatarImageLoader,
        openFullContent: openFullContent,
        inlineConversationContext: makeInlineConversationContext(viewModel: viewModel)
      )
      timelineRowsRegion(region: region, preferences: preferences)
      DashboardReviewConversationPositionFooter(
        countSummary: .init(
          visibleRowsCount: window.visibleRowsCount,
          totalRowsCount: rowSource.rows.count,
          hasOlder: viewModel.hasOlder
        ),
        fontScale: fontScale
      )
      .equatable()
    }
  }

  private func makeInlineConversationContext(
    viewModel: ReviewTimelineViewModel
  ) -> ReviewActivityInlineConversationRendererContext {
    ReviewActivityInlineConversationRendererContext(
      viewerLogin: viewerLogin,
      collapsedThreadIDs: inlineConversationCollapsedThreadIDs,
      collapseRevision: inlineConversationCollapseRevision,
      onSetCollapsed: setInlineConversationCollapsed(threadID:collapsed:),
      onResolveToggle: { threadID, desired in
        let outcome = await store.setReviewThreadResolved(
          threadID: threadID,
          pullRequestID: item.pullRequestID,
          desired: desired
        )
        if case .failed(let reason) = outcome {
          store.presentFailureFeedback(reason)
        }
      },
      onReply: { threadID, body in
        await store.postReviewThreadReply(
          pullRequestID: item.pullRequestID,
          repository: item.repository,
          threadID: threadID,
          body: body,
          viewerLogin: viewerLogin
        )
      }
    )
  }

  @ViewBuilder
  private func timelineRowsRegion(
    region: TimelineRowsRegion,
    preferences: DashboardReviewsPreferences
  ) -> some View {
    let window = region.window
    let collapsedWindow = region.collapsedWindow
    if window.hiddenMiddleRowCount > 0 {
      DashboardReviewConversationSegmentedTimelineRows(
        headRows: region.visibleHeadRows,
        tailRows: region.visibleTailRows,
        gapAction: .show(window.nextExpansionCount),
        gapScrollAnchorID: gapScrollAnchorID,
        onGapAnchorMinYChange: updateGapScrollAnchorViewportMinY,
        actionHandler: actionHandler,
        onSignalTap: onSignalTap,
        onOpenFullContent: region.openFullContent,
        fullContentRevision: region.revision,
        reviewInlineConversationContext: region.inlineConversationContext,
        avatarImageLoader: region.avatarImageLoader,
        fontScale: fontScale
      ) {
        handleGapToggle {
          visibleTimelineRowLimit += Self.timelineRowBatchSize
        }
      }
    } else {
      if region.canHideRevealedRows, collapsedWindow.hiddenMiddleRowCount > 0 {
        DashboardReviewConversationSegmentedTimelineRows(
          headRows: region.expandedHeadRows,
          tailRows: region.expandedTailRows,
          gapAction: .hide(collapsedWindow.hiddenMiddleRowCount),
          gapScrollAnchorID: gapScrollAnchorID,
          onGapAnchorMinYChange: updateGapScrollAnchorViewportMinY,
          actionHandler: actionHandler,
          onSignalTap: onSignalTap,
          onOpenFullContent: region.openFullContent,
          fullContentRevision: region.revision,
          reviewInlineConversationContext: region.inlineConversationContext,
          avatarImageLoader: region.avatarImageLoader,
          fontScale: fontScale
        ) {
          handleGapToggle {
            visibleTimelineRowLimit = Self.timelineRowBatchSize
          }
        }
      } else {
        SessionTimelineCards(
          rows: region.visibleHeadRows,
          actionHandler: actionHandler,
          onSignalTap: onSignalTap,
          onOpenFullContent: region.openFullContent,
          fullContentRevision: region.revision,
          reviewInlineConversationContext: region.inlineConversationContext,
          avatarImageLoader: region.avatarImageLoader
        )
      }
      if region.hasOlder {
        Button("Load older") {
          Task {
            await store.loadOlderReviewTimeline(
              for: item,
              pageSize: preferences.normalizedTimelineLoadOlderBatchSize
            )
          }
        }
        .buttonStyle(.borderless)
        .disabled(region.isLoadingOlder)
      }
    }
  }

  private func presentFullContent(
    for node: SessionTimelineNode,
    entries: [ReviewTimelineEntry],
    revision: UInt64
  ) {
    guard node.canOpenFullContent else { return }
    if fullContentCacheRevision != revision {
      fullContentCache = [:]
      fullContentCacheRevision = revision
    }
    if let cached = fullContentCache[node.identity] {
      presentedFullContent = cached
      return
    }
    guard
      let resolved = DashboardReviewConversationFullContentResolver.resolve(
        node: node,
        entries: entries
      )
    else {
      return
    }
    fullContentCache[node.identity] = resolved
    presentedFullContent = resolved
  }

  private func setInlineConversationCollapsed(threadID: String, collapsed: Bool) {
    let previous = inlineConversationCollapsedThreadIDs[threadID]
    guard previous != collapsed else { return }
    inlineConversationCollapsedThreadIDs[threadID] = collapsed
    inlineConversationCollapseRevision &+= 1
  }

  private func handleGapToggle(_ action: () -> Void) {
    guard let currentMinY = gapScrollAnchorViewportMinY else {
      action()
      return
    }
    pendingGapScrollCompensation = .init(targetMinY: currentMinY)
    action()
  }

  private func updateGapScrollAnchorViewportMinY(_ minY: CGFloat) {
    guard minY.isFinite else { return }
    let previousMinY = gapScrollAnchorViewportMinY
    if previousMinY == nil
      || abs(minY - (previousMinY ?? minY)) > Self.gapScrollCompensationTolerance
      || pendingGapScrollCompensation != nil
    {
      gapScrollAnchorViewportMinY = minY
    }
    guard var pendingGapScrollCompensation else { return }
    let deltaY = minY - pendingGapScrollCompensation.targetMinY
    guard abs(deltaY) > Self.gapScrollCompensationTolerance else { return }
    if let lastEmittedDeltaY = pendingGapScrollCompensation.lastEmittedDeltaY {
      let movedCloserToTarget =
        abs(deltaY) + Self.gapScrollCompensationTolerance < abs(lastEmittedDeltaY)
      guard movedCloserToTarget else { return }
    }
    guard pendingGapScrollCompensation.remainingPasses > 0 else {
      self.pendingGapScrollCompensation = nil
      return
    }
    pendingGapScrollCompensation.lastEmittedDeltaY = deltaY
    pendingGapScrollCompensation.remainingPasses -= 1
    self.pendingGapScrollCompensation = pendingGapScrollCompensation
    onGapScrollCompensation?(deltaY)
  }

  struct PendingGapScrollCompensation: Equatable {
    let targetMinY: CGFloat
    var lastEmittedDeltaY: CGFloat?
    var remainingPasses: Int

    init(targetMinY: CGFloat) {
      self.targetMinY = targetMinY
      lastEmittedDeltaY = nil
      remainingPasses = 3
    }
  }
}
