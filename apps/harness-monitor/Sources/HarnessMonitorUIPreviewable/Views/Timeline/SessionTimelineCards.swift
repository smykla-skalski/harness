import HarnessMonitorKit
import SwiftUI

struct ReviewActivityInlineConversationRendererContext {
  let viewerLogin: String?
  let collapsedThreadIDs: [String: Bool]
  let collapseRevision: UInt64
  let onSetCollapsed: (String, Bool) -> Void
  let onResolveToggle: (String, Bool) async -> Void
  let onReply: (String, String) async -> Bool
}

struct SessionTimelineCards<Rows: RandomAccessCollection>: View
where Rows.Element == SessionTimelineRow {
  let rows: Rows
  let actionHandler: any DecisionActionHandler
  let onSignalTap: ((String) -> Void)?
  let onOpenFullContent: ((SessionTimelineNode) -> Void)?
  let fullContentRevision: UInt64?
  let reviewInlineConversationContext: ReviewActivityInlineConversationRendererContext?
  let avatarImageLoader: TimelineAvatarImageLoader?
  @Environment(\.fontScale)
  var fontScale

  init(
    rows: Rows,
    actionHandler: any DecisionActionHandler,
    onSignalTap: ((String) -> Void)? = nil,
    onOpenFullContent: ((SessionTimelineNode) -> Void)? = nil,
    fullContentRevision: UInt64? = nil,
    reviewInlineConversationContext: ReviewActivityInlineConversationRendererContext? =
      nil,
    avatarImageLoader: TimelineAvatarImageLoader? = nil
  ) {
    self.rows = rows
    self.actionHandler = actionHandler
    self.onSignalTap = onSignalTap
    self.onOpenFullContent = onOpenFullContent
    self.fullContentRevision = fullContentRevision
    self.reviewInlineConversationContext = reviewInlineConversationContext
    self.avatarImageLoader = avatarImageLoader
  }

  var body: some View {
    let firstRowID = rows.first?.id
    let lastRowID = rows.last?.id
    LazyVStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
      ForEach(rows) { row in
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
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .coordinateSpace(.named(SessionTimelineRailCoordinateSpace.name))
    .backgroundPreferenceValue(SessionTimelineMarkerBoundsPreferenceKey.self) { anchors in
      if !rows.isEmpty {
        SessionTimelineRailDecoration(
          firstRowID: firstRowID,
          lastRowID: lastRowID,
          markerAnchors: anchors
        )
      }
    }
  }
}

struct SessionTimelineNodeCluster: View {
  let row: SessionTimelineRow
  let actionHandler: any DecisionActionHandler
  let onSignalTap: ((String) -> Void)?
  let onOpenFullContent: ((SessionTimelineNode) -> Void)?
  let fullContentRevision: UInt64?
  let reviewInlineConversationContext: ReviewActivityInlineConversationRendererContext?
  let avatarImageLoader: TimelineAvatarImageLoader?
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
        onOpenFullContent: onOpenFullContent,
        reviewInlineConversationContext: reviewInlineConversationContext,
        avatarImageLoader: avatarImageLoader,
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
      && (lhs.onOpenFullContent == nil) == (rhs.onOpenFullContent == nil)
      && lhs.fullContentRevision == rhs.fullContentRevision
      && (lhs.reviewInlineConversationContext == nil)
        == (rhs.reviewInlineConversationContext == nil)
      && lhs.reviewInlineConversationContext?.viewerLogin
        == rhs.reviewInlineConversationContext?.viewerLogin
      && lhs.reviewInlineConversationContext?.collapseRevision
        == rhs.reviewInlineConversationContext?.collapseRevision
      && (lhs.avatarImageLoader == nil) == (rhs.avatarImageLoader == nil)
  }
}

struct SessionTimelineNodeRow: View {
  let row: SessionTimelineRow
  let actionHandler: any DecisionActionHandler
  let onSignalTap: ((String) -> Void)?
  let onOpenFullContent: ((SessionTimelineNode) -> Void)?
  let reviewInlineConversationContext: ReviewActivityInlineConversationRendererContext?
  let avatarImageLoader: TimelineAvatarImageLoader?
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
    onOpenFullContent: ((SessionTimelineNode) -> Void)? = nil,
    reviewInlineConversationContext: ReviewActivityInlineConversationRendererContext? =
      nil,
    avatarImageLoader: TimelineAvatarImageLoader? = nil,
    fontScale: CGFloat
  ) {
    self.row = row
    self.actionHandler = actionHandler
    self.onSignalTap = onSignalTap
    self.onOpenFullContent = onOpenFullContent
    self.reviewInlineConversationContext = reviewInlineConversationContext
    self.avatarImageLoader = avatarImageLoader
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

  var supportsFullContentSheet: Bool {
    node.canOpenFullContent && onOpenFullContent != nil && node.actions.isEmpty
  }

  var hasCustomInlineConversation: Bool {
    node.reviewInlineConversation != nil && reviewInlineConversationContext != nil
  }

  var cardInsets: EdgeInsets {
    EdgeInsets(
      top: HarnessMonitorTheme.spacingSM * max(1, fontScale),
      leading: HarnessMonitorTheme.cardPadding,
      bottom: HarnessMonitorTheme.spacingSM * max(1, fontScale),
      trailing: HarnessMonitorTheme.cardPadding
    )
  }

  // Per-cell modifier-chain depth dominated `swift_conformsToProtocol`
  // (87.7% of main-thread CPU during a 10s scroll). Each `.scaledFont(_:)`
  // call expanded to `modifier(ScaledFontModifier)` plus a nested `.font(_:)`
  // inside its body — two ModifiedContent layers per text label. Direct
  // `.font(precomputedFont)` is one layer and skips the `@Environment(\.fontScale)`
  // view-graph edge that AG would otherwise wire from every label back to the
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

      rowMarker
        .anchorPreference(
          key: SessionTimelineMarkerBoundsPreferenceKey.self,
          value: .bounds
        ) { anchor in
          [row.id: anchor]
        }

      cardArea
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
      guard !supportsFullContentSheet else { return }
      if case .signal(let id) = node.tapTarget { onSignalTap?(id) }
    }
  }

  @ViewBuilder var rowMarker: some View {
    if let login = node.actorLogin {
      AvatarImageView(
        login: login,
        avatarURL: node.actorAvatarURL,
        size: 18,
        loadImage: avatarImageLoader
      )
      .frame(width: SessionTimelineLayout.railWidth, alignment: .center)
    } else {
      SessionTimelineDot(tint: cardTint)
    }
  }

  @ViewBuilder var cardArea: some View {
    if supportsFullContentSheet {
      Button {
        onOpenFullContent?(node)
      } label: {
        cardContainer
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(row.accessibilityLabel)
      }
      .sessionTimelineInteractiveCardButtonStyle(tint: cardTint)
      .help("Open full content")
      .accessibilityHint("Opens full activity content")
      .accessibilityIdentifier(node.accessibilityIdentifier)
    } else {
      cardContainer
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityIdentifier(node.accessibilityIdentifier)
    }
  }

}

private struct SessionTimelineInteractiveCardButtonModifier: ViewModifier {
  let tint: Color
  @State private var isHovered = false

  func body(content: Content) -> some View {
    content
      .buttonStyle(
        SessionTimelineImmediateCardButtonStyle(
          cornerRadius: HarnessMonitorTheme.cornerRadiusMD,
          tint: tint,
          isHovered: isHovered
        )
      )
      .onHover { hovering in
        guard isHovered != hovering else { return }
        isHovered = hovering
      }
      .contentShape(
        RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
      )
      .frame(maxWidth: .infinity, alignment: .leading)
      .transaction { transaction in
        transaction.animation = nil
      }
      .pointerStyle(.link)
  }
}

private struct SessionTimelineImmediateCardButtonStyle: ButtonStyle {
  let cornerRadius: CGFloat
  let tint: Color
  let isHovered: Bool
  @Environment(\.isEnabled)
  private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    let fillOpacity = configuration.isPressed ? 0.12 : isHovered ? 0.08 : 0.04
    configuration.label
      .background {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .fill(tint.opacity(fillOpacity))
      }
      .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
      .opacity(isEnabled ? (configuration.isPressed ? 0.92 : 1) : 0.4)
  }
}

extension View {
  fileprivate func sessionTimelineInteractiveCardButtonStyle(tint: Color) -> some View {
    modifier(SessionTimelineInteractiveCardButtonModifier(tint: tint))
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
