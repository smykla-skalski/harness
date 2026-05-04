import HarnessMonitorKit
import SwiftUI

struct SessionTimelineCards: View {
  let rows: [SessionTimelineRow]
  let placeholderCount: Int
  let shimmerPhase: CGFloat
  let showsShimmer: Bool
  let actionHandler: any DecisionActionHandler

  var body: some View {
    LazyVStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
      ForEach(rows) { row in
        SessionTimelineNodeCluster(
          row: row,
          actionHandler: actionHandler
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

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
      if let label = row.dayDividerLabel {
        SessionTimelineDayDivider(label: label)
      }
      SessionTimelineNodeRow(
        row: row,
        actionHandler: actionHandler
      )
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct SessionTimelineNodeRow: View {
  let row: SessionTimelineRow
  let actionHandler: any DecisionActionHandler
  private let statusBadges: [SessionTimelineStatusBadge]

  init(
    row: SessionTimelineRow,
    actionHandler: any DecisionActionHandler
  ) {
    self.row = row
    self.actionHandler = actionHandler
    statusBadges = Self.makeStatusBadges(for: row.node)
  }

  private var node: SessionTimelineNode {
    row.node
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
        SessionTimelineActionButtons(actions: node.actions, handler: actionHandler)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, HarnessMonitorTheme.cardPadding)
      .padding(.vertical, HarnessMonitorTheme.spacingSM)
      .background(SessionTimelineCardBackground(tint: cardTint))
      .alignmentGuide(.sessionTimelineMarkerCenter) { _ in
        SessionTimelineLayout.singleLineMarkerCenterY
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contextMenu {
      Button {
        HarnessMonitorClipboard.copy(node.title)
      } label: {
        Label("Copy Summary", systemImage: "doc.on.doc")
      }
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
    HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingMD) {
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
    if let eventTone = node.eventTone {
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
      ForEach(badges) { badge in
        SessionTimelineBadge(label: badge.label, tint: badge.tint, style: .prominent)
      }
    }
    .fixedSize(horizontal: true, vertical: false)
  }
}

enum SessionTimelineLayout {
  static let timeColumnWidth: CGFloat = 92
  static let railWidth: CGFloat = 14
  static let markerDiameter: CGFloat = 19
  static let markerCoreDiameter: CGFloat = 11
  static let singleLineMarkerCenterY = HarnessMonitorTheme.spacingSM + (markerDiameter / 2)
  static let railLineOffset =
    timeColumnWidth + HarnessMonitorTheme.itemSpacing + (railWidth / 2)
}

extension VerticalAlignment {
  fileprivate enum SessionTimelineMarkerCenter: AlignmentID {
    static func defaultValue(in context: ViewDimensions) -> CGFloat {
      context[VerticalAlignment.center]
    }
  }

  fileprivate static let sessionTimelineMarkerCenter = VerticalAlignment(
    SessionTimelineMarkerCenter.self
  )
}

struct SessionTimelineRailBackground: View {
  var body: some View {
    GeometryReader { proxy in
      Rectangle()
        .fill(HarnessMonitorTheme.controlBorder.opacity(0.55))
        .frame(width: 2, height: max(0, proxy.size.height - HarnessMonitorTheme.spacingLG))
        .offset(
          x: SessionTimelineLayout.railLineOffset - 1,
          y: HarnessMonitorTheme.spacingSM
        )
    }
    .accessibilityHidden(true)
    .allowsHitTesting(false)
  }
}

private struct SessionTimelineDot: View {
  let tint: Color

  var body: some View {
    ZStack {
      Circle()
        .fill(.background)
        .frame(
          width: SessionTimelineLayout.markerDiameter,
          height: SessionTimelineLayout.markerDiameter
        )
      Circle()
        .fill(tint)
        .frame(
          width: SessionTimelineLayout.markerCoreDiameter,
          height: SessionTimelineLayout.markerCoreDiameter
        )
    }
    .frame(width: SessionTimelineLayout.railWidth, alignment: .center)
    .shadow(color: tint.opacity(0.4), radius: 8)
    .accessibilityHidden(true)
  }
}

private struct SessionTimelineCardBackground: View {
  let tint: Color

  var body: some View {
    RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
      .fill(tint.opacity(0.08))
      .overlay {
        RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
          .stroke(tint.opacity(0.35), lineWidth: 1)
      }
  }
}
