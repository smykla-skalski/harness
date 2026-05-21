import HarnessMonitorKit
import SwiftUI

struct SessionTimelineCards: View {
  let rows: [SessionTimelineRow]
  let actionHandler: any DecisionActionHandler
  let onSignalTap: ((String) -> Void)?
  @Environment(\.fontScale)
  var fontScale

  var body: some View {
    LazyVStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
      ForEach(rows) { row in
        SessionTimelineNodeCluster(
          row: row,
          actionHandler: actionHandler,
          onSignalTap: onSignalTap,
          fontScale: fontScale
        )
        .equatable()
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .coordinateSpace(.named(SessionTimelineRailCoordinateSpace.name))
    .background(alignment: .topLeading) {
      if !rows.isEmpty {
        SessionTimelineRailBackground()
      }
    }
  }
}

struct SessionTimelineNodeCluster: View {
  let row: SessionTimelineRow
  let actionHandler: any DecisionActionHandler
  let onSignalTap: ((String) -> Void)?
  let fontScale: CGFloat

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
      if let label = row.dayDividerLabel {
        SessionTimelineDayDivider(label: label)
      }
      SessionTimelineNodeRow(
        row: row,
        actionHandler: actionHandler,
        onSignalTap: onSignalTap,
        fontScale: fontScale
      )
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

// Cells rebuild this cluster on every reconfigure even when the row
// payload is unchanged. Skip the per-cell VStack + child body work via
// a structural compare on the inputs (closure presence as a Bool so a
// fresh-but-equivalent closure identity does not invalidate the cell).
extension SessionTimelineNodeCluster: @MainActor Equatable {
  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.row == rhs.row
      && lhs.fontScale == rhs.fontScale
      && ObjectIdentifier(lhs.actionHandler as AnyObject)
        == ObjectIdentifier(rhs.actionHandler as AnyObject)
      && (lhs.onSignalTap == nil) == (rhs.onSignalTap == nil)
  }
}

struct SessionTimelineNodeRow: View {
  let row: SessionTimelineRow
  let actionHandler: any DecisionActionHandler
  let onSignalTap: ((String) -> Void)?
  let statusBadges: [SessionTimelineStatusBadge]
  let fontScale: CGFloat
  let timestampFont: Font
  let titleFont: Font
  let sourceFont: Font
  let detailFont: Font
  let compactSourceFont: Font

  init(
    row: SessionTimelineRow,
    actionHandler: any DecisionActionHandler,
    onSignalTap: ((String) -> Void)? = nil,
    fontScale: CGFloat
  ) {
    self.row = row
    self.actionHandler = actionHandler
    self.onSignalTap = onSignalTap
    self.fontScale = fontScale
    statusBadges = Self.makeStatusBadges(for: row.node)
    timestampFont = HarnessMonitorTextSize.scaledFont(
      .caption.monospaced(),
      by: fontScale
    )
    titleFont = HarnessMonitorTextSize.scaledFont(
      .system(.body, design: .rounded, weight: .semibold),
      by: fontScale
    )
    sourceFont = HarnessMonitorTextSize.scaledFont(
      .callout.monospaced(),
      by: fontScale
    )
    detailFont = HarnessMonitorTextSize.scaledFont(.callout, by: fontScale)
    compactSourceFont = HarnessMonitorTextSize.scaledFont(
      .caption.monospaced(),
      by: fontScale
    )
  }

  var node: SessionTimelineNode {
    row.node
  }

  var usesSimpleWideLayout: Bool {
    SessionTimelineCardLayout.usesSimpleWideLayout(for: row)
  }

  // Per-cell modifier-chain depth dominated `swift_conformsToProtocol`
  // (87.7% of main-thread CPU during a 10s scroll). Each `.scaledFont(_:)`
  // call expanded to `modifier(ScaledFontModifier)` plus a nested `.font(_:)`
  // inside its body — two ModifiedContent layers per text label. Direct
  // `.font(precomputedFont)` is one layer and skips the `@Environment(\.fontScale)`
  // dependency edge that AG would otherwise wire from every label back to the
  // row root.
  var body: some View {
    HStack(alignment: .sessionTimelineMarkerCenter, spacing: HarnessMonitorTheme.itemSpacing) {
      Text(verbatim: row.timestampLabel)
        .font(timestampFont)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .lineLimit(1)
        .multilineTextAlignment(.leading)
        .frame(width: SessionTimelineLayout.timeColumnWidth, alignment: .leading)
        .accessibilityHidden(true)

      SessionTimelineDot(tint: cardTint)

      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        cardContent
        if !node.actions.isEmpty {
          SessionTimelineActionButtons(actions: node.actions, handler: actionHandler)
            .equatable()
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(
        EdgeInsets(
          top: HarnessMonitorTheme.spacingSM * max(1, fontScale),
          leading: HarnessMonitorTheme.cardPadding,
          bottom: HarnessMonitorTheme.spacingSM * max(1, fontScale),
          trailing: HarnessMonitorTheme.cardPadding
        )
      )
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

  var cardContent: some View {
    Group {
      if SessionTimelineCardLayout.prefersCompactLayout(for: row) {
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

  var wideContent: some View {
    HStack(
      alignment: usesSimpleWideLayout ? .center : .top,
      spacing: HarnessMonitorTheme.spacingMD
    ) {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
        HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingSM) {
          if node.kind != .event {
            kindBadge
          }
          Text(verbatim: node.title)
            .font(titleFont)
            .foregroundStyle(HarnessMonitorTheme.ink)
            .lineLimit(1)
          Text(verbatim: node.sourceLabel)
            .font(sourceFont)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .lineLimit(1)
        }
        .alignmentGuide(.sessionTimelineFirstLineCenter) { dimensions in
          dimensions[VerticalAlignment.center]
        }
        if let detail = node.detail {
          Text(verbatim: detail)
            .font(detailFont)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .lineLimit(1)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      rightBadges
    }
  }

  var compactContent: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingSM) {
        if node.kind != .event {
          kindBadge
        }
        Text(verbatim: node.sourceLabel)
          .font(compactSourceFont)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .lineLimit(1)
        Spacer(minLength: HarnessMonitorTheme.spacingSM)
        rightBadges
      }
      .alignmentGuide(.sessionTimelineFirstLineCenter) { dimensions in
        dimensions[VerticalAlignment.center]
      }

      Text(verbatim: node.title)
        .font(titleFont)
        .foregroundStyle(HarnessMonitorTheme.ink)
        .lineLimit(2)
        .frame(maxWidth: .infinity, alignment: .leading)

      if let detail = node.detail {
        Text(verbatim: detail)
          .font(detailFont)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .lineLimit(2)
      }
    }
  }

  var kindBadge: some View {
    SessionTimelineBadge(label: node.kind.label, tint: typeTint, style: .quiet)
      .equatable()
  }

  var rightBadges: some View {
    SessionTimelineBadgeStrip(badges: statusBadges)
  }

  var typeTint: Color {
    switch node.kind {
    case .event:
      cardTint
    case .decision:
      HarnessMonitorTheme.accent
    case .linkedDecision:
      HarnessMonitorTheme.caution
    }
  }

  var cardTint: Color {
    if let eventTone = node.eventTone {
      return eventTone.color
    }
    return node.decision?.severity.color ?? HarnessMonitorTheme.secondaryInk
  }

  static func makeStatusBadges(
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

struct SessionTimelineBadgeStrip: View {
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

  func badgeView(_ badge: SessionTimelineStatusBadge) -> some View {
    SessionTimelineBadge(label: badge.label, tint: badge.tint, style: .prominent)
      .equatable()
  }
}
