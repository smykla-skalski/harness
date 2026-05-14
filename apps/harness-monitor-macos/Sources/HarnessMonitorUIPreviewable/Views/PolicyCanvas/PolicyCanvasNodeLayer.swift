import SwiftUI

struct PolicyCanvasNodeLayer: View {
  let viewModel: PolicyCanvasViewModel

  var body: some View {
    let severityMap = viewModel.nodeSeverityMap
    ForEach(viewModel.nodes) { node in
      PolicyCanvasNodeCard(
        node: node,
        isSelected: viewModel.selection == .node(node.id),
        severity: severityMap[node.id],
        viewModel: viewModel
      )
      .position(
        x: node.position.x + PolicyCanvasLayout.nodeSize.width / 2,
        y: node.position.y + PolicyCanvasLayout.nodeSize.height / 2
      )
      .gesture(
        DragGesture(minimumDistance: 3)
          .onChanged { value in
            viewModel.dragNode(node.id, translation: value.translation)
          }
          .onEnded { value in
            viewModel.endNodeDrag(node.id, translation: value.translation)
          }
      )
      .onTapGesture {
        viewModel.select(.node(node.id))
      }
    }
  }
}

struct PolicyCanvasNodeCard: View {
  let node: PolicyCanvasNode
  let isSelected: Bool
  let severity: PolicyCanvasIssueSeverity?
  let viewModel: PolicyCanvasViewModel

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 8)
        .fill(Color(red: 0.10, green: 0.12, blue: 0.16).opacity(0.95))
        .overlay {
          RoundedRectangle(cornerRadius: 8)
            .stroke(strokeColor, lineWidth: severity == nil ? 1.2 : 1.8)
        }
        .shadow(color: .black.opacity(0.34), radius: 12, x: 0, y: 8)

      HStack(alignment: .top, spacing: 10) {
        Image(systemName: node.kind.symbolName)
          .scaledFont(.system(size: 16, weight: .semibold))
          .foregroundStyle(node.kind.accentColor)
          .frame(width: 24, height: 24)
          .background(node.kind.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 6))

        VStack(alignment: .leading, spacing: 5) {
          Text(node.title)
            .scaledFont(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(1)

          Text(node.subtitle)
            .scaledFont(.caption)
            .foregroundStyle(.white.opacity(0.62))
            .lineLimit(1)

          if let groupID = node.groupID, let group = viewModel.group(groupID) {
            Text(group.title)
              .scaledFont(.caption2.weight(.medium))
              .foregroundStyle(group.tone.color.opacity(0.95))
              .lineLimit(1)
          }
        }

        Spacer(minLength: 0)
      }
      .padding(12)

      PolicyCanvasPortColumn(
        node: node,
        ports: node.inputPorts,
        alignment: .leading,
        viewModel: viewModel
      )

      PolicyCanvasPortColumn(
        node: node,
        ports: node.outputPorts,
        alignment: .trailing,
        viewModel: viewModel
      )

      PolicyCanvasPortColumn(
        node: node,
        ports: node.inputPorts,
        alignment: .top,
        viewModel: viewModel,
        isAuxiliary: true
      )

      PolicyCanvasPortColumn(
        node: node,
        ports: node.outputPorts,
        alignment: .bottom,
        viewModel: viewModel,
        isAuxiliary: true
      )

      if let severity {
        severityBadge(for: severity)
      }
    }
    .frame(width: PolicyCanvasLayout.nodeSize.width, height: PolicyCanvasLayout.nodeSize.height)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(viewModel.accessibilityLabel(for: node))
    .accessibilityValue(accessibilityValue)
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasNode(node.id))
  }

  private var strokeColor: Color {
    if let severity {
      return severity.accentColor.opacity(isSelected ? 0.98 : 0.82)
    }
    return node.kind.accentColor.opacity(isSelected ? 0.95 : 0.34)
  }

  private var accessibilityValue: String {
    let base = viewModel.accessibilityValue(for: node)
    guard let severity else {
      return base
    }
    let issues = viewModel.allValidationIssues
      .filter { resolved in
        resolved.issue.nodeId == node.id || resolved.issue.nodeIds.contains(node.id)
      }
      .map { resolved in
        resolved.issue.message
      }
      .joined(separator: "; ")
    let prefix = "invalid: \(severity.displayLabel) - \(issues)"
    return base.isEmpty ? prefix : "\(prefix). \(base)"
  }

  private func severityBadge(for severity: PolicyCanvasIssueSeverity) -> some View {
    VStack {
      HStack {
        Spacer()
        Image(systemName: severity.systemImage)
          .scaledFont(.system(size: 13, weight: .semibold))
          .foregroundStyle(severity.accentColor)
          .padding(4)
          .background(.black.opacity(0.68), in: Circle())
          .overlay {
            Circle()
              .stroke(severity.accentColor.opacity(0.85), lineWidth: 1)
          }
          .offset(x: 8, y: -8)
          .accessibilityHidden(true)
      }
      Spacer()
    }
  }
}
