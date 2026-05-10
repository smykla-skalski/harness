import HarnessMonitorKit
import SwiftUI

struct SessionTimelineCards: View {
  let rows: [SessionTimelineRow]
  let placeholderCount: Int
  let shimmerPhase: CGFloat
  let showsShimmer: Bool
  let actionHandler: any DecisionActionHandler
  let onSignalTap: ((String) -> Void)?

  var body: some View {
    LazyVStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
      ForEach(rows) { row in
        SessionTimelineNodeCluster(
          row: row,
          actionHandler: actionHandler,
          onSignalTap: onSignalTap
        )
      }

      ForEach(0..<placeholderCount, id: \.self) { index in
        SessionCockpitTimelinePlaceholderRow(
          seed: index,
          shimmerPhase: shimmerPhase,
          showsShimmer: showsShimmer
        )
      }
    }
    .scrollTargetLayout()
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(alignment: .topLeading) {
      if !rows.isEmpty || placeholderCount > 0 {
        SessionTimelineRailBackground()
      }
    }
  }
}

struct SessionTimelineNodeCluster: View {
  let row: SessionTimelineRow
  let actionHandler: any DecisionActionHandler
  let onSignalTap: ((String) -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
      if let label = row.dayDividerLabel {
        SessionTimelineDayDivider(label: label)
      }
      SessionTimelineNodeRow(
        row: row,
        actionHandler: actionHandler,
        onSignalTap: onSignalTap
      )
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct SessionTimelineNodeRow: View {
  let row: SessionTimelineRow
  let actionHandler: any DecisionActionHandler
  let onSignalTap: ((String) -> Void)?
  private let statusBadges: [SessionTimelineStatusBadge]
  @Environment(\.fontScale)
  private var fontScale

  init(
    row: SessionTimelineRow,
    actionHandler: any DecisionActionHandler,
    onSignalTap: ((String) -> Void)? = nil
  ) {
    self.row = row
    self.actionHandler = actionHandler
    self.onSignalTap = onSignalTap
    statusBadges = Self.makeStatusBadges(for: row.node)
  }

  private var node: SessionTimelineNode {
    row.node
  }

  private var usesSimpleWideLayout: Bool {
    SessionTimelineTableMetrics.usesSimpleWideLayout(for: row)
  }

  var body: some View {
    HStack(alignment: .sessionTimelineMarkerCenter, spacing: HarnessMonitorTheme.itemSpacing) {
      Text(row.timestampLabel)
        .scaledFont(.caption.monospaced())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .lineLimit(1)
        .multilineTextAlignment(.trailing)
        .frame(width: SessionTimelineLayout.timeColumnWidth, alignment: .trailing)
        .accessibilityHidden(true)

      SessionTimelineDot(tint: cardTint)

      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        cardContent
        if !node.actions.isEmpty {
          SessionTimelineActionButtons(actions: node.actions, handler: actionHandler)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, HarnessMonitorTheme.cardPadding)
      .padding(.vertical, HarnessMonitorTheme.spacingSM * max(1, fontScale))
      .background(SessionTimelineCardBackground(tint: cardTint))
      .alignmentGuide(.sessionTimelineMarkerCenter) { dimensions in
        dimensions[.sessionTimelineFirstLineCenter]
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contextMenu {
      Button {
        HarnessMonitorClipboard.copy(node.title)
      } label: {
        Label("Copy Summary", systemImage: "doc.on.doc")
      }
      if !node.contextMenuItems.isEmpty {
        Divider()
        ForEach(node.contextMenuItems, id: \.label) { item in
          Button(item.label, systemImage: item.systemImage) {
            switch item.action {
            case .openSignal(let id): onSignalTap?(id)
            case .copyText(let text): HarnessMonitorClipboard.copy(text)
            }
          }
        }
      }
    }
    .onTapGesture {
      if case .signal(let id) = node.tapTarget { onSignalTap?(id) }
    }
  }

  private var cardContent: some View {
    Group {
      if SessionTimelineTableMetrics.prefersCompactLayout(for: row) {
        compactContent
      } else {
        wideContent
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(row.accessibilityLabel)
    .accessibilityIdentifier(node.accessibilityIdentifier)
  }
  // ViewThatFits removed: combining `ViewThatFits(in: .horizontal)` with the
  // `.fixedSize` badge strip inside a LazyVStack reproduces an AttributeGraph
  // cycle on macOS 26 SwiftUI. The cycle drives `NSHostingView` async-
  // DisplayLink layout to iterate the ForEach off the MainActor, which trips
  // `_swift_task_checkIsolatedSwift` and crashes the app via libdispatch BUG.
  // `prefersCompactLayout(for:)` already encodes the size decision; a
  // deterministic branch is enough.

  private var wideContent: some View {
    HStack(
      alignment: usesSimpleWideLayout ? .center : .top,
      spacing: HarnessMonitorTheme.spacingMD
    ) {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
        HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingSM) {
          if node.kind != .event {
            kindBadge
          }
          Text(node.title)
            .scaledFont(.system(.body, design: .rounded, weight: .semibold))
            .foregroundStyle(HarnessMonitorTheme.ink)
            .lineLimit(1)
          Text(node.sourceLabel)
            .scaledFont(.callout.monospaced())
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .lineLimit(1)
        }
        .alignmentGuide(.sessionTimelineFirstLineCenter) { dimensions in
          dimensions[VerticalAlignment.center]
        }
        if let detail = node.detail {
          Text(detail)
            .scaledFont(.callout)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .lineLimit(1)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      rightBadges
    }
  }

  private var compactContent: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingSM) {
        if node.kind != .event {
          kindBadge
        }
        Text(node.sourceLabel)
          .scaledFont(.caption.monospaced())
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .lineLimit(1)
        Spacer(minLength: HarnessMonitorTheme.spacingSM)
        rightBadges
      }
      .alignmentGuide(.sessionTimelineFirstLineCenter) { dimensions in
        dimensions[VerticalAlignment.center]
      }

      Text(node.title)
        .scaledFont(.system(.body, design: .rounded, weight: .semibold))
        .foregroundStyle(HarnessMonitorTheme.ink)
        .lineLimit(2)
        .frame(maxWidth: .infinity, alignment: .leading)

      if let detail = node.detail {
        Text(detail)
          .scaledFont(.callout)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .lineLimit(2)
      }
    }
  }

  private var kindBadge: some View {
    SessionTimelineBadge(label: node.kind.label, tint: typeTint, style: .quiet)
      .equatable()
  }

  private var rightBadges: some View {
    SessionTimelineBadgeStrip(badges: statusBadges)
  }

  private var typeTint: Color {
    switch node.kind {
    case .event:
      cardTint
    case .decision:
      HarnessMonitorTheme.accent
    case .linkedDecision:
      HarnessMonitorTheme.caution
    }
  }

  private var cardTint: Color {
    if let eventTone = node.eventTone {
      return eventTone.color
    }
    return node.decision?.severity.color ?? HarnessMonitorTheme.secondaryInk
  }

  private static func makeStatusBadges(
    for node: SessionTimelineNode
  ) -> [SessionTimelineStatusBadge] {
    var badges: [SessionTimelineStatusBadge] = []
    if let label = node.statusBadgeLabel {
      let tint = node.eventTone?.color ?? HarnessMonitorTheme.secondaryInk
      badges.append(SessionTimelineStatusBadge(label: label, tint: tint))
    } else if let eventTone = node.eventTone {
      badges.append(SessionTimelineStatusBadge(label: eventTone.badgeLabel, tint: eventTone.color))
    }
    if let decision = node.decision {
      badges.append(
        SessionTimelineStatusBadge(
          label: decision.severity.badgeLabel,
          tint: decision.severity.color
        )
      )
    }
    return badges
  }
}

private struct SessionTimelineBadgeStrip: View {
  let badges: [SessionTimelineStatusBadge]

  var body: some View {
    HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingSM) {
      if badges.indices.contains(0) {
        badgeView(badges[0])
      }
      if badges.indices.contains(1) {
        badgeView(badges[1])
      }
    }
    .textCase(.uppercase)
    .fixedSize(horizontal: true, vertical: false)
  }

  private func badgeView(_ badge: SessionTimelineStatusBadge) -> some View {
    SessionTimelineBadge(label: badge.label, tint: badge.tint, style: .prominent)
      .equatable()
  }
}
