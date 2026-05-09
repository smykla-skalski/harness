import HarnessMonitorKit
import SwiftUI

struct SessionSidebarRow<DragHandle: View>: View {
  let title: String
  let systemImage: String
  var severityShape: SessionSidebarSeverityShape = .none
  var severityTint: Color = .gray
  var showsDragHandle = false
  var isDropTargeted = false
  var isMultiSelect = false
  var isSelected = false
  var toggleSelection: (() -> Void)?
  let dragHandle: (SessionSidebarRowMetrics) -> DragHandle
  @Environment(\.fontScale)
  private var fontScale
  @State private var isHoveringDragHandle = false

  init(
    title: String,
    systemImage: String,
    severityShape: SessionSidebarSeverityShape = .none,
    severityTint: Color = .gray,
    isDropTargeted: Bool = false,
    isMultiSelect: Bool = false,
    isSelected: Bool = false,
    toggleSelection: (() -> Void)? = nil,
    @ViewBuilder dragHandle: @escaping (SessionSidebarRowMetrics) -> DragHandle
  ) {
    self.title = title
    self.systemImage = systemImage
    self.severityShape = severityShape
    self.severityTint = severityTint
    showsDragHandle = true
    self.isDropTargeted = isDropTargeted
    self.isMultiSelect = isMultiSelect
    self.isSelected = isSelected
    self.toggleSelection = toggleSelection
    self.dragHandle = dragHandle
  }

  private var metrics: SessionSidebarRowMetrics {
    SessionSidebarRowMetrics(fontScale: fontScale)
  }

  var body: some View {
    HStack(spacing: metrics.spacing) {
      if isMultiSelect {
        Button {
          toggleSelection?()
        } label: {
          Image(systemName: isSelected ? "checkmark.square.fill" : "square")
            .imageScale(.small)
            .scaledFont(.body)
        }
        .buttonStyle(.borderless)
        .frame(
          width: metrics.multiSelectControlSize,
          height: metrics.multiSelectControlSize
        )
        .contentShape(Rectangle())
        .accessibilityLabel(isSelected ? "Deselect \(title)" : "Select \(title)")
      }

      Image(systemName: systemImage)
        .scaledFont(.body)
        .foregroundStyle(.secondary)
        .frame(width: metrics.iconColumnWidth)
        .accessibilityHidden(true)
        .overlay(alignment: .topTrailing) {
          severityIndicator
            .frame(
              width: metrics.severityIndicatorSize,
              height: metrics.severityIndicatorSize
            )
            .offset(x: metrics.severityIndicatorOffset, y: -metrics.severityIndicatorOffset)
        }

      Text(title)
        .scaledFont(.body)
        .lineLimit(1)
      Spacer(minLength: 0)
    }
    .padding(.vertical, metrics.verticalPadding)
    .padding(.trailing, showsDragHandle ? metrics.dragHandleHitTarget : 0)
    .frame(maxWidth: .infinity, minHeight: metrics.minHeight, alignment: .leading)
    .padding(.horizontal, isDropTargeted ? 4 : 0)
    .background {
      if isDropTargeted {
        RoundedRectangle(cornerRadius: metrics.dropCornerRadius)
          .strokeBorder(.tint, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
      }
    }
    .overlay(alignment: .trailing) {
      if showsDragHandle {
        dragHandleColumn
      }
    }
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityLabel(title)
    .onHover { isHovering in
      guard showsDragHandle else { return }
      isHoveringDragHandle = isHovering
    }
  }

  @ViewBuilder private var dragHandleColumn: some View {
    dragHandle(metrics)
      .opacity(isHoveringDragHandle ? 1 : 0)
      .accessibilityHidden(true)
  }

  @ViewBuilder private var severityIndicator: some View {
    switch severityShape {
    case .none:
      EmptyView()
    case .dot:
      Circle().fill(severityTint)
    case .ring:
      Circle().strokeBorder(severityTint, lineWidth: 1.5)
    case .alert:
      Image(systemName: "exclamationmark")
        .font(.system(size: metrics.severityAlertFontSize, weight: .heavy))
        .foregroundStyle(severityTint)
    }
  }
}

struct SessionSidebarRowMetrics: Equatable {
  let spacing: CGFloat
  let minHeight: CGFloat
  let verticalPadding: CGFloat
  let iconColumnWidth: CGFloat
  let multiSelectControlSize: CGFloat
  let dragHandleHitTarget: CGFloat
  let severityIndicatorSize: CGFloat
  let severityIndicatorOffset: CGFloat
  let severityAlertFontSize: CGFloat
  let dropCornerRadius: CGFloat

  init(fontScale: CGFloat) {
    let scale = SessionWindowFontScale.metricsScale(for: fontScale)
    spacing = 8
    minHeight = max(28, 26 * scale)
    verticalPadding = max(1, 1.5 * min(scale, 1.4))
    iconColumnWidth = max(16, 16 * min(scale, 1.35))
    multiSelectControlSize = scale >= 1.45 ? 44 : max(24, 22 * scale)
    dragHandleHitTarget = scale >= 1.45 ? 44 : max(24, 22 * scale)
    severityIndicatorSize = max(8, 8 * min(scale, 1.5))
    severityIndicatorOffset = max(4, 4 * min(scale, 1.35))
    severityAlertFontSize = max(6, 6 * min(scale, 1.5))
    dropCornerRadius = max(5, 5 * min(scale, 1.25))
  }
}

extension SessionSidebarRow where DragHandle == EmptyView {
  init(
    title: String,
    systemImage: String,
    severityShape: SessionSidebarSeverityShape = .none,
    severityTint: Color = .gray,
    isDropTargeted: Bool = false,
    isMultiSelect: Bool = false,
    isSelected: Bool = false,
    toggleSelection: (() -> Void)? = nil
  ) {
    self.title = title
    self.systemImage = systemImage
    self.severityShape = severityShape
    self.severityTint = severityTint
    showsDragHandle = false
    self.isDropTargeted = isDropTargeted
    self.isMultiSelect = isMultiSelect
    self.isSelected = isSelected
    self.toggleSelection = toggleSelection
    dragHandle = { _ in EmptyView() }
  }
}

struct SessionSidebarDragHandle: View {
  let metrics: SessionSidebarRowMetrics

  private var dotSize: CGFloat {
    max(2.8, min(3.6, metrics.dragHandleHitTarget / 7))
  }

  private var columnSpacing: CGFloat {
    max(2.6, dotSize * 1.15)
  }

  private var rowSpacing: CGFloat {
    max(3.2, dotSize * 1.25)
  }

  var body: some View {
    SessionSidebarDragHandleGlyph(
      dotSize: dotSize,
      columnSpacing: columnSpacing,
      rowSpacing: rowSpacing
    )
    .fill(.tertiary)
    .frame(
      width: metrics.dragHandleHitTarget,
      height: metrics.dragHandleHitTarget
    )
  }
}

private struct SessionSidebarDragHandleGlyph: Shape {
  let dotSize: CGFloat
  let columnSpacing: CGFloat
  let rowSpacing: CGFloat

  func path(in rect: CGRect) -> Path {
    let glyphWidth = dotSize * 2 + columnSpacing
    let glyphHeight = dotSize * 3 + rowSpacing * 2
    let originX = rect.midX - glyphWidth / 2
    let originY = rect.midY - glyphHeight / 2
    var path = Path()

    for column in 0..<2 {
      for row in 0..<3 {
        path.addEllipse(
          in: CGRect(
            x: originX + CGFloat(column) * (dotSize + columnSpacing),
            y: originY + CGFloat(row) * (dotSize + rowSpacing),
            width: dotSize,
            height: dotSize
          )
        )
      }
    }

    return path
  }
}

public enum SessionSidebarSeverityShape: Hashable, Sendable {
  case none
  case dot
  case ring
  case alert
}
