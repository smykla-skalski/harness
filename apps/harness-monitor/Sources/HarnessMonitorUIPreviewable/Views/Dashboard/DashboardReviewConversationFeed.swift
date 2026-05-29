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
  @State private var gapScrollAnchorViewportMinY: CGFloat?
  @State private var pendingGapScrollCompensation: PendingGapScrollCompensation?
  @State private var presentedFullContent: DashboardReviewConversationFullContent?
  @State private var fullContentCacheRevision: UInt64?
  @State private var inlineConversationCollapseRevision: UInt64 = 0
  @State private var inlineConversationCollapsedThreadIDs: [String: Bool] = [:]
  @State
  private var fullContentCache: [SessionTimelineNode.Identity: DashboardReviewConversationFullContent] =
    [:]
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
      let canHideRevealedRows = visibleTimelineRowLimit > Self.timelineRowBatchSize
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
      let inlineConversationContext = DashboardReviewActivityInlineConversationRendererContext(
        viewerLogin: viewerLogin,
        collapsedThreadIDs: inlineConversationCollapsedThreadIDs,
        collapseRevision: inlineConversationCollapseRevision,
        onSetCollapsed: setInlineConversationCollapsed(threadID:collapsed:),
        onResolveToggle: { threadID, desired in
          _ = await store.setReviewThreadResolved(
            threadID: threadID,
            pullRequestID: item.pullRequestID,
            desired: desired
          )
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
      if window.hiddenMiddleRowCount > 0 {
        DashboardReviewConversationSegmentedTimelineRows(
          headRows: visibleTimelineHeadRows,
          tailRows: visibleTimelineTailRows,
          gapAction: .show(window.nextExpansionCount),
          gapScrollAnchorID: gapScrollAnchorID,
          onGapAnchorMinYChange: updateGapScrollAnchorViewportMinY,
          actionHandler: actionHandler,
          onSignalTap: onSignalTap,
          onOpenFullContent: openFullContent,
          fullContentRevision: viewModel.revision,
          reviewInlineConversationContext: inlineConversationContext,
          avatarImageLoader: avatarImageLoader,
          fontScale: fontScale
        ) {
          handleGapToggle {
            visibleTimelineRowLimit += Self.timelineRowBatchSize
          }
        }
      } else {
        if canHideRevealedRows, collapsedWindow.hiddenMiddleRowCount > 0 {
          DashboardReviewConversationSegmentedTimelineRows(
            headRows: expandedTimelineHeadRows,
            tailRows: expandedTimelineTailRows,
            gapAction: .hide(collapsedWindow.hiddenMiddleRowCount),
            gapScrollAnchorID: gapScrollAnchorID,
            onGapAnchorMinYChange: updateGapScrollAnchorViewportMinY,
            actionHandler: actionHandler,
            onSignalTap: onSignalTap,
            onOpenFullContent: openFullContent,
            fullContentRevision: viewModel.revision,
            reviewInlineConversationContext: inlineConversationContext,
            avatarImageLoader: avatarImageLoader,
            fontScale: fontScale
          ) {
            handleGapToggle {
              visibleTimelineRowLimit = Self.timelineRowBatchSize
            }
          }
        } else {
          SessionTimelineCards(
            rows: visibleTimelineHeadRows,
            actionHandler: actionHandler,
            onSignalTap: onSignalTap,
            onOpenFullContent: openFullContent,
            fullContentRevision: viewModel.revision,
            reviewInlineConversationContext: inlineConversationContext,
            avatarImageLoader: avatarImageLoader
          )
        }
        if viewModel.hasOlder {
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
      }
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
    guard let resolved = DashboardReviewConversationFullContentResolver.resolve(
      node: node,
      entries: entries
    ) else {
      return
    }
    fullContentCache[node.identity] = resolved
    presentedFullContent = resolved
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

  private var captionFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption, by: fontScale)
  }

  private var subheadlineFont: Font {
    HarnessMonitorTextSize.scaledFont(.subheadline, by: fontScale)
  }

  private var gapScrollAnchorID: String {
    "dashboard.review.timeline.gap-anchor.\(item.pullRequestID)"
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
    if previousMinY == nil || abs(minY - (previousMinY ?? minY)) > Self.gapScrollCompensationTolerance
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

  private struct PendingGapScrollCompensation: Equatable {
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

/// Computes the locally visible rows for the Reviews activity timeline when the
/// middle is collapsed: keep the current leading window visible, preserve a
/// single oldest anchor event at the far edge, and hide only the rows between
/// them.
struct DashboardReviewConversationVisibilityWindow: Equatable {
  let leadingVisibleRowsCount: Int
  let trailingVisibleRowsCount: Int
  let hiddenMiddleRowCount: Int
  let nextExpansionCount: Int

  var visibleRowsCount: Int {
    leadingVisibleRowsCount + trailingVisibleRowsCount
  }

  init(
    totalRowsCount: Int,
    leadingVisibleRowsLimit: Int,
    batchSize: Int,
    trailingAnchorCount: Int
  ) {
    let clampedTotalRowsCount = max(totalRowsCount, 0)
    let clampedLeadingVisibleRowsLimit = min(
      max(leadingVisibleRowsLimit, 0),
      clampedTotalRowsCount
    )
    let clampedTrailingAnchorCount = min(
      max(trailingAnchorCount, 0),
      max(clampedTotalRowsCount - clampedLeadingVisibleRowsLimit, 0)
    )
    let hiddenMiddleRowCount = max(
      clampedTotalRowsCount - clampedLeadingVisibleRowsLimit - clampedTrailingAnchorCount,
      0
    )

    if hiddenMiddleRowCount == 0 {
      leadingVisibleRowsCount = clampedTotalRowsCount
      trailingVisibleRowsCount = 0
    } else {
      leadingVisibleRowsCount = clampedLeadingVisibleRowsLimit
      trailingVisibleRowsCount = clampedTrailingAnchorCount
    }

    self.hiddenMiddleRowCount = hiddenMiddleRowCount
    nextExpansionCount = min(max(batchSize, 0), hiddenMiddleRowCount)
  }
}

enum DashboardReviewConversationCollapsedGapAction: Equatable {
  case show(Int)
  case hide(Int)

  var title: String {
    switch self {
    case .show(let hiddenRowCount):
      "Show \(hiddenRowCount) more events"
    case .hide(let hiddenRowCount):
      "Hide \(hiddenRowCount) events"
    }
  }

  var helpText: String {
    switch self {
    case .show:
      "Render the next batch of hidden review activity"
    case .hide:
      "Hide the events revealed from the collapsed middle"
    }
  }
}

private struct DashboardReviewConversationSegmentedTimelineRows<
  HeadRows: RandomAccessCollection,
  TailRows: RandomAccessCollection
>: View where HeadRows.Element == SessionTimelineRow, TailRows.Element == SessionTimelineRow {
  let headRows: HeadRows
  let tailRows: TailRows
  let gapAction: DashboardReviewConversationCollapsedGapAction
  let gapScrollAnchorID: String
  let onGapAnchorMinYChange: (CGFloat) -> Void
  let actionHandler: any DecisionActionHandler
  let onSignalTap: ((String) -> Void)?
  let onOpenFullContent: ((SessionTimelineNode) -> Void)?
  let fullContentRevision: UInt64?
  let reviewInlineConversationContext: DashboardReviewActivityInlineConversationRendererContext?
  let avatarImageLoader: TimelineAvatarImageLoader?
  let fontScale: CGFloat
  let onGapActivate: () -> Void

  var body: some View {
    let firstRowID = headRows.first?.id ?? tailRows.first?.id
    let lastHeadRowID = headRows.last?.id
    let firstTailRowID = tailRows.first?.id
    let lastTailRowID = tailRows.last?.id
    let lastRowID = tailRows.last?.id ?? headRows.last?.id
    LazyVStack(alignment: .leading, spacing: 0) {
      ForEach(headRows) { row in
        SessionTimelineNodeCluster(
          row: row,
          actionHandler: actionHandler,
          onSignalTap: onSignalTap,
          onOpenFullContent: onOpenFullContent,
          fullContentRevision: fullContentRevision,
          reviewInlineConversationContext: reviewInlineConversationContext,
          avatarImageLoader: avatarImageLoader,
          fontScale: fontScale
        )
        .equatable()
        .padding(.bottom, HarnessMonitorTheme.itemSpacing)
      }
      DashboardReviewConversationCollapsedGapDivider(
        action: gapAction,
        anchorID: gapScrollAnchorID,
        onAnchorMinYChange: onGapAnchorMinYChange,
        fontScale: fontScale,
        onExpand: onGapActivate
      )
      .padding(.bottom, HarnessMonitorTheme.itemSpacing)
      ForEach(tailRows) { row in
        SessionTimelineNodeCluster(
          row: row,
          actionHandler: actionHandler,
          onSignalTap: onSignalTap,
          onOpenFullContent: onOpenFullContent,
          fullContentRevision: fullContentRevision,
          reviewInlineConversationContext: reviewInlineConversationContext,
          avatarImageLoader: avatarImageLoader,
          fontScale: fontScale
        )
        .equatable()
        .padding(.bottom, row.id == lastTailRowID ? 0 : HarnessMonitorTheme.itemSpacing)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .coordinateSpace(.named(SessionTimelineRailCoordinateSpace.name))
    .backgroundPreferenceValue(SessionTimelineMarkerBoundsPreferenceKey.self) { anchors in
      if firstRowID != nil, lastRowID != nil {
        ZStack {
          SessionTimelineRailDecoration(
            firstRowID: firstRowID,
            lastRowID: lastRowID,
            markerAnchors: anchors
          )
          DashboardReviewConversationCollapsedGapRailOverlay(
            startRowID: lastHeadRowID,
            endRowID: firstTailRowID,
            markerAnchors: anchors
          )
        }
      }
    }
  }
}

struct DashboardReviewConversationFullContent: Identifiable, Equatable, Sendable {
  let id: SessionTimelineNode.Identity
  let title: String
  let sourceLabel: String
  let markdown: String
}

enum DashboardReviewConversationFullContentResolver {
  static func resolve(
    node: SessionTimelineNode,
    entries: [ReviewTimelineEntry]
  ) -> DashboardReviewConversationFullContent? {
    guard node.canOpenFullContent else { return nil }
    guard let markdown = markdown(for: node.identity, entries: entries) else {
      return nil
    }
    return DashboardReviewConversationFullContent(
      id: node.identity,
      title: node.title,
      sourceLabel: node.sourceLabel,
      markdown: markdown
    )
  }

  private static func markdown(
    for identity: SessionTimelineNode.Identity,
    entries: [ReviewTimelineEntry]
  ) -> String? {
    guard case .entry(let entryID) = identity else { return nil }
    for entry in entries {
      switch entry {
      case .issueComment(let payload) where payload.id == entryID:
        return payload.isMinimized ? nil : trimmed(payload.body)
      case .review(let payload) where payload.id == entryID:
        return trimmed(payload.body)
      case .review(let payload):
        if let markdown = inlineCommentMarkdown(for: entryID, review: payload) {
          return markdown
        }
      case .reviewThread(let payload):
        if let markdown = threadCommentMarkdown(for: entryID, thread: payload) {
          return markdown
        }
      case .commit(let payload) where payload.id == entryID:
        return trimmed(payload.messageHeadline)
      default:
        continue
      }
    }
    return nil
  }

  private static func inlineCommentMarkdown(
    for entryID: String,
    review: ReviewPayload
  ) -> String? {
    for inlineComment in review.inlineComments where "\(review.id):\(inlineComment.id)" == entryID {
      return trimmed(inlineComment.body)
    }
    return nil
  }

  private static func threadCommentMarkdown(
    for entryID: String,
    thread: ReviewThreadPayload
  ) -> String? {
    for comment in thread.comments where "\(thread.id):\(comment.id)" == entryID {
      return trimmed(comment.body)
    }
    return nil
  }

  private static func trimmed(_ markdown: String?) -> String? {
    let trimmedMarkdown = (markdown ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedMarkdown.isEmpty else { return nil }
    return trimmedMarkdown
  }
}

private struct DashboardReviewConversationFullContentSheet: View {
  let content: DashboardReviewConversationFullContent
  let fontScale: CGFloat

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
          Text(verbatim: content.title)
            .font(HarnessMonitorTextSize.scaledFont(.title3.weight(.semibold), by: fontScale))
            .foregroundStyle(HarnessMonitorTheme.ink)
            .accessibilityAddTraits(.isHeader)
          Text(verbatim: content.sourceLabel)
            .font(HarnessMonitorTextSize.scaledFont(.subheadline, by: fontScale))
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        }
        Divider()
        HarnessMonitorMarkdownText(content.markdown, textSelection: .enabled)
      }
      .frame(maxWidth: 760, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(24)
    }
    .frame(minWidth: 620, minHeight: 420)
    .background(Color(nsColor: .windowBackgroundColor))
  }
}

private struct DashboardReviewConversationCollapsedGapRailOverlay: View {
  let startRowID: String?
  let endRowID: String?
  let markerAnchors: [String: Anchor<CGRect>]

  var body: some View {
    GeometryReader { proxy in
      let markerFrames = markerAnchors.mapValues { proxy[$0] }
      if
        let startRowID,
        let endRowID,
        let startFrame = markerFrames[startRowID],
        let endFrame = markerFrames[endRowID]
      {
        let top = min(startFrame.midY, endFrame.midY)
        let bottom = max(startFrame.midY, endFrame.midY)
        let height = max(bottom - top, 1)
        Rectangle()
          .fill(Color(nsColor: .windowBackgroundColor))
          .frame(width: SessionTimelineLayout.railWidth, height: height)
          .overlay {
            Path { path in
              let x = SessionTimelineLayout.railWidth / 2
              path.move(to: CGPoint(x: x, y: 0))
              path.addLine(to: CGPoint(x: x, y: height))
            }
            .stroke(
              HarnessMonitorTheme.controlBorder.opacity(0.55),
              style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [1, 5])
            )
            .frame(width: SessionTimelineLayout.railWidth, height: height)
          }
          .offset(
            x: SessionTimelineLayout.railLineOffset - (SessionTimelineLayout.railWidth / 2),
            y: top
          )
      }
    }
    .accessibilityHidden(true)
    .allowsHitTesting(false)
  }
}

private struct DashboardReviewConversationCollapsedGapDivider: View {
  let action: DashboardReviewConversationCollapsedGapAction
  let anchorID: String
  let onAnchorMinYChange: (CGFloat) -> Void
  let fontScale: CGFloat
  let onExpand: () -> Void
  @State private var isHovered = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Color.clear
        .frame(height: 1)
        .frame(maxWidth: .infinity)
        .id(anchorID)
        .onGeometryChange(for: CGFloat.self) { proxy in
          proxy.frame(in: .named(DashboardReviewDetailScrollCoordinateSpace.name)).minY
        } action: { _, minY in
          onAnchorMinYChange(minY)
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
      HStack(alignment: .center, spacing: HarnessMonitorTheme.itemSpacing) {
        Color.clear
          .frame(width: SessionTimelineLayout.timeColumnWidth)
        Button(action: onExpand) {
          HStack(alignment: .center, spacing: HarnessMonitorTheme.itemSpacing) {
            railSpacer
           DashboardReviewConversationCollapsedGapDividerLabel(
             title: action.title,
             fontScale: fontScale
           )
         }
         .frame(maxWidth: .infinity, alignment: .leading)
         .padding(.vertical, HarnessMonitorTheme.spacingXS)
       }
       .buttonStyle(DashboardReviewConversationCollapsedGapDividerButtonStyle(isHovered: isHovered))
       .onHover { hovering in
         isHovered = hovering
       }
       .pointerStyle(.link)
       .help(action.helpText)
       .accessibilityLabel(action.title)
     }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var railSpacer: some View {
    Color.clear
      .frame(width: SessionTimelineLayout.railWidth)
      .accessibilityHidden(true)
  }
}

private enum DashboardReviewConversationCollapsedGapDividerInteractionState {
  case resting
  case hovered
  case pressed

  var textColor: Color {
    switch self {
    case .resting:
      HarnessMonitorTheme.accent
    case .hovered:
      HarnessMonitorTheme.warmAccent.opacity(0.92)
    case .pressed:
      HarnessMonitorTheme.warmAccent
    }
  }

  var lineColor: Color {
    switch self {
    case .resting:
      HarnessMonitorTheme.controlBorder.opacity(0.42)
    case .hovered:
      HarnessMonitorTheme.warmAccent.opacity(0.92)
    case .pressed:
      HarnessMonitorTheme.warmAccent
    }
  }
}

private extension EnvironmentValues {
  @Entry var dashboardReviewConversationCollapsedGapDividerInteractionState:
    DashboardReviewConversationCollapsedGapDividerInteractionState = .resting
}

private struct DashboardReviewConversationCollapsedGapDividerLabel: View {
  let title: String
  let fontScale: CGFloat
  @Environment(\.dashboardReviewConversationCollapsedGapDividerInteractionState)
  private var interactionState

  var body: some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      dottedLine
      Text(title)
        .font(
          HarnessMonitorTextSize.scaledFont(
            .caption.monospaced().weight(.medium),
            by: fontScale
          )
        )
        .foregroundStyle(interactionState.textColor)
      dottedLine
    }
    .frame(maxWidth: .infinity, alignment: .center)
  }

  private var dottedLine: some View {
    Rectangle()
      .stroke(
        interactionState.lineColor,
        style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [1, 4])
      )
      .frame(height: 1)
      .accessibilityHidden(true)
  }
}

private struct DashboardReviewConversationCollapsedGapDividerButtonStyle: ButtonStyle {
  let isHovered: Bool

  func makeBody(configuration: Configuration) -> some View {
    let interactionState: DashboardReviewConversationCollapsedGapDividerInteractionState =
      if configuration.isPressed {
        .pressed
      } else if isHovered {
        .hovered
      } else {
        .resting
      }
    configuration.label
      .environment(
        \.dashboardReviewConversationCollapsedGapDividerInteractionState,
        interactionState
      )
      .contentShape(
        RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM, style: .continuous)
      )
      .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
      .animation(.easeOut(duration: 0.12), value: isHovered)
  }
}
