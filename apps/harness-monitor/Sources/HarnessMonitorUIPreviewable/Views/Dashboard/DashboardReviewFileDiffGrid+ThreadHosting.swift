import AppKit
import HarnessMonitorKit
import SwiftUI

@MainActor
extension DashboardReviewFileDiffGridContentView {
  /// Resolve each row's visible threads, measure the hosted card stack at the
  /// current content width, and rebuild `layout` so following rows reserve the
  /// gap. No threads (or visibility `.hidden`) collapses back to a flat grid.
  func rebuildThreadLayout(contentWidth: CGFloat) {
    let rowHeights = rowHeightMap()
    guard !threadsByID.isEmpty, conversationVisibility != .hidden else {
      cardHeightByRowID = [:]
      removeAllCardHosts()
      layout = DashboardReviewFileDiffThreadLayout(
        rowCount: rows.count,
        rowHeight: rowHeight,
        rowHeights: rowHeights
      )
      return
    }
    var heights: [Int: CGFloat] = [:]
    for (index, row) in rows.enumerated() {
      let threads = visibleThreads(forRowID: row.id)
      guard !threads.isEmpty else { continue }
      let measured = measuredCardStackHeight(threads: threads, contentWidth: contentWidth)
      heights[index] = measured
      cardHeightByRowID[row.id] = measured
    }
    layout = DashboardReviewFileDiffThreadLayout(
      rowCount: rows.count,
      rowHeight: rowHeight,
      rowHeights: rowHeights,
      cardHeights: heights
    )
  }

  /// Full threads anchored to a row, filtered by the active visibility mode.
  func visibleThreads(forRowID rowID: Int) -> [DashboardReviewFileThread] {
    let anchors = threadsByRowID[rowID] ?? []
    return
      anchors
      .compactMap { threadsByID[$0.id] }
      .filter { conversationVisibility.shows(isResolved: $0.isResolved) }
  }

  /// Add/update/remove hosted card stacks to match the current layout.
  func layoutThreadCards(contentWidth: CGFloat) {
    var live = Set<Int>()
    for (index, row) in rows.enumerated() {
      let threads = visibleThreads(forRowID: row.id)
      guard !threads.isEmpty, let rect = layout.cardRect(index, width: contentWidth) else {
        continue
      }
      live.insert(row.id)
      let host = cardHostsByRowID[row.id] ?? makeCardHost()
      host.rootView = makeCardStack(threads: threads, rowID: row.id)
      host.frame = rect
      if host.superview == nil {
        addSubview(host)
      }
      cardHostsByRowID[row.id] = host
    }
    for (rowID, host) in cardHostsByRowID where !live.contains(rowID) {
      host.removeFromSuperview()
      cardHostsByRowID[rowID] = nil
    }
  }

  /// SwiftUI re-measured the stack (e.g. a card collapsed): grow/shrink the gap
  /// and slide following rows + card hosts. Gated by a threshold so the
  /// geometry callback can't oscillate.
  func handleCardHeight(rowID: Int, height: CGFloat) {
    let clamped = max(height, 24)
    guard abs((cardHeightByRowID[rowID] ?? 0) - clamped) > 0.5 else { return }
    cardHeightByRowID[rowID] = clamped
    var heights: [Int: CGFloat] = [:]
    for (storedRowID, storedHeight) in cardHeightByRowID {
      if let index = rowIndexByID[storedRowID] {
        heights[index] = storedHeight
      }
    }
    layout = DashboardReviewFileDiffThreadLayout(
      rowCount: rows.count,
      rowHeight: rowHeight,
      rowHeights: rowHeightMap(),
      cardHeights: heights
    )
    let size = CGSize(width: bounds.width, height: ceil(layout.totalHeight))
    if frame.size != size {
      setFrameSize(size)
    }
    repositionCardHosts(contentWidth: bounds.width)
    needsDisplay = true
    notifyPreferredViewportHeightChanged()
  }

  private func repositionCardHosts(contentWidth: CGFloat) {
    for (rowID, host) in cardHostsByRowID {
      guard
        let index = rowIndexByID[rowID],
        let rect = layout.cardRect(index, width: contentWidth)
      else { continue }
      host.frame = rect
    }
  }

  func removeAllCardHosts() {
    for host in cardHostsByRowID.values {
      host.removeFromSuperview()
    }
    cardHostsByRowID = [:]
  }

  private func makeCardHost() -> NSHostingView<DashboardReviewInlineThreadCardStack> {
    let host = NSHostingView(rootView: emptyCardStack())
    host.translatesAutoresizingMaskIntoConstraints = true
    return host
  }

  private func makeCardStack(
    threads: [DashboardReviewFileThread],
    rowID: Int
  ) -> DashboardReviewInlineThreadCardStack {
    DashboardReviewInlineThreadCardStack(
      threads: threads,
      viewerLogin: cardViewerLogin,
      fontScale: cardFontScale,
      leadingInset: cardLeadingInset,
      loadAvatar: cardLoadAvatar,
      onResolveToggle: { [weak self] threadID, desired in
        _ = await self?.cardResolveToggle?(threadID, desired)
      },
      onReply: { [weak self] threadID, body in
        await self?.cardReply?(threadID, body) ?? false
      },
      onHeightChange: { [weak self] height in
        self?.handleCardHeight(rowID: rowID, height: height)
      }
    )
  }

  private func emptyCardStack() -> DashboardReviewInlineThreadCardStack {
    DashboardReviewInlineThreadCardStack(
      threads: [],
      viewerLogin: nil,
      fontScale: cardFontScale,
      leadingInset: cardLeadingInset,
      loadAvatar: nil,
      onResolveToggle: { _, _ in },
      onReply: { _, _ in false },
      onHeightChange: { _ in }
    )
  }

  private var cardLeadingInset: CGFloat {
    switch viewMode {
    case .unified: 120
    case .split: 76
    }
  }

  private func measuredCardStackHeight(
    threads: [DashboardReviewFileThread],
    contentWidth: CGFloat
  ) -> CGFloat {
    let key = cardCacheKey(threads: threads, width: contentWidth)
    if let cached = measuredCardHeightCache[key] {
      return cached
    }
    let host = NSHostingView(
      rootView: DashboardReviewInlineThreadCardStack(
        threads: threads,
        viewerLogin: cardViewerLogin,
        fontScale: cardFontScale,
        leadingInset: cardLeadingInset,
        loadAvatar: nil,
        onResolveToggle: { _, _ in },
        onReply: { _, _ in false },
        onHeightChange: { _ in }
      )
    )
    host.frame = NSRect(x: 0, y: 0, width: max(contentWidth, 1), height: 1)
    host.layoutSubtreeIfNeeded()
    let measured = max(host.fittingSize.height, 44)
    measuredCardHeightCache[key] = measured
    return measured
  }

  private func rowHeightMap() -> [Int: CGFloat] {
    Dictionary(
      uniqueKeysWithValues: rows.enumerated().map { index, _ in
        let lineCount =
          wrappedRowLayouts.indices.contains(index) ? wrappedRowLayouts[index].lineCount : 1
        return (index, CGFloat(max(lineCount, 1)) * rowHeight)
      }
    )
  }

  private func cardCacheKey(threads: [DashboardReviewFileThread], width: CGFloat) -> String {
    let signature =
      threads
      .map { "\($0.id):\($0.isResolved ? 1 : 0):\($0.isCollapsed ? 1 : 0):\($0.comments.count)" }
      .joined(separator: ",")
    return "\(Int(width.rounded()))|\(conversationVisibility.rawValue)|\(signature)"
  }
}
