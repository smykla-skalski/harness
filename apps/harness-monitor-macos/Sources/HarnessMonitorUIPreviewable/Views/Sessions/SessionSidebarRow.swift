import HarnessMonitorKit
import SwiftUI

struct SessionSidebarRow: View {
  let title: String
  let systemImage: String
  let severityShape: SessionSidebarSeverityShape
  let severityTint: Color
  var showsDragHandle = false
  var isDropTargeted = false
  var isMultiSelect = false
  var isSelected = false
  var toggleSelection: (() -> Void)?
  @State private var isHovering = false

  var body: some View {
    HStack(spacing: 8) {
      if isMultiSelect {
        Button {
          toggleSelection?()
        } label: {
          Image(systemName: isSelected ? "checkmark.square.fill" : "square")
            .imageScale(.small)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(isSelected ? "Deselect \(title)" : "Select \(title)")
      }

      Image(systemName: showsDragHandle && isHovering ? "line.3.horizontal" : systemImage)
        .foregroundStyle(.secondary)
        .frame(width: 16)
        .accessibilityHidden(true)
        .overlay(alignment: .topTrailing) {
          severityIndicator
            .frame(width: 8, height: 8)
            .offset(x: 4, y: -4)
        }

      Text(title)
        .lineLimit(1)
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 1)
    .padding(.horizontal, isDropTargeted ? 4 : 0)
    .background {
      if isDropTargeted {
        RoundedRectangle(cornerRadius: 5)
          .strokeBorder(.tint, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
      }
    }
    .onHover { isHovering = $0 }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(title)
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
        .font(.system(size: 6, weight: .heavy))
        .foregroundStyle(severityTint)
    }
  }
}

public enum SessionSidebarSeverityShape: Hashable, Sendable {
  case none
  case dot
  case ring
  case alert
}
