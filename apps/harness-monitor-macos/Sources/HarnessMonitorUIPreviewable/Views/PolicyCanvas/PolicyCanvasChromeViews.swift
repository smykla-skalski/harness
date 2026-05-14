import Observation
import SwiftUI

struct PolicyCanvasTopBar: View {
  @Bindable var viewModel: PolicyCanvasViewModel
  let canPromote: Bool
  let save: @MainActor () -> Void
  let simulate: @MainActor () -> Void
  let promote: @MainActor () -> Void

  var body: some View {
    HStack(spacing: 12) {
      Label("Configurable Policy Canvas", systemImage: "rectangle.3.group.bubble")
        .font(.headline.weight(.semibold))
        .foregroundStyle(.white)

      Picker("Canvas mode", selection: $viewModel.selectedTab) {
        ForEach(PolicyCanvasTab.allCases) { tab in
          Text(tab.title).tag(tab)
        }
      }
      .pickerStyle(.segmented)
      .frame(width: 290)
      .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasTabs)

      Spacer(minLength: 16)

      PolicyCanvasActionButton(
        title: "Save",
        systemImage: "square.and.arrow.down",
        accessibilityIdentifier: HarnessMonitorAccessibility.policyCanvasSaveButton,
        action: {
          viewModel.save()
          save()
        }
      )

      PolicyCanvasActionButton(
        title: "Simulate",
        systemImage: "play.circle",
        accessibilityIdentifier: HarnessMonitorAccessibility.policyCanvasSimulateButton,
        action: {
          viewModel.simulate()
          simulate()
        }
      )

      PolicyCanvasActionButton(
        title: "Promote",
        systemImage: "arrow.up.right.circle",
        tint: Color.green,
        isDisabled: !canPromote,
        disabledReason: viewModel.promoteDisabledReason,
        accessibilityIdentifier: HarnessMonitorAccessibility.policyCanvasPromoteButton,
        action: {
          viewModel.promote()
          promote()
        }
      )
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(Color(red: 0.08, green: 0.09, blue: 0.12).opacity(0.98))
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(.white.opacity(0.08))
        .frame(height: 1)
    }
  }
}

private struct PolicyCanvasActionButton: View {
  let title: String
  let systemImage: String
  var tint = Color.cyan
  var isDisabled = false
  var disabledReason: String?
  let accessibilityIdentifier: String
  let action: @MainActor () -> Void

  var body: some View {
    Button(action: action) {
      Label(title, systemImage: systemImage)
        .font(.callout.weight(.semibold))
        .lineLimit(1)
    }
    .harnessActionButtonStyle(variant: .bordered, tint: tint.opacity(0.85))
    .controlSize(.small)
    .disabled(isDisabled)
    .help(isDisabled ? disabledReason ?? title : title)
    .accessibilityIdentifier(accessibilityIdentifier)
  }
}

struct PolicyCanvasToolRail: View {
  let viewModel: PolicyCanvasViewModel

  var body: some View {
    VStack(spacing: 10) {
      ForEach(PolicyCanvasNodeKind.allCases) { kind in
        Button {
          viewModel.createNode(kind: kind, at: CGPoint(x: 180, y: 180))
        } label: {
          VStack(spacing: 5) {
            Image(systemName: kind.symbolName)
              .font(.system(size: 15, weight: .semibold))
            Text(kind.title)
              .font(.caption2.weight(.semibold))
              .lineLimit(1)
          }
          .foregroundStyle(kind.accentColor)
          .frame(width: 64, height: 52)
          .background(kind.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
          .overlay {
            RoundedRectangle(cornerRadius: 8)
              .stroke(kind.accentColor.opacity(0.38), lineWidth: 1)
          }
        }
        .harnessPlainButtonStyle()
        .draggable(viewModel.palettePayload(for: kind))
        .help("Add \(kind.title)")
        .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasPaletteItem(kind.rawValue))
      }

      Spacer(minLength: 0)
    }
    .padding(.vertical, 14)
    .padding(.horizontal, 8)
    .frame(width: 84)
    .background(Color(red: 0.07, green: 0.08, blue: 0.11))
    .overlay(alignment: .trailing) {
      Rectangle()
        .fill(.white.opacity(0.07))
        .frame(width: 1)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasToolRail)
  }
}

struct PolicyCanvasZoomControls: View {
  let viewModel: PolicyCanvasViewModel

  var body: some View {
    HStack(spacing: 6) {
      Button {
        viewModel.zoomOut()
      } label: {
        Image(systemName: "minus.magnifyingglass")
      }
      .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasZoomOutButton)

      Text("\(Int((viewModel.zoom * 100).rounded()))%")
        .font(.caption.monospacedDigit().weight(.semibold))
        .foregroundStyle(.white.opacity(0.86))
        .frame(width: 46)
        .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasZoomValue)

      Button {
        viewModel.zoomIn()
      } label: {
        Image(systemName: "plus.magnifyingglass")
      }
      .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasZoomInButton)

      Button {
        viewModel.resetZoom()
      } label: {
        Image(systemName: "arrow.counterclockwise")
      }
      .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasZoomResetButton)
    }
    .harnessActionButtonStyle(variant: .borderless)
    .controlSize(.small)
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 8))
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .stroke(.white.opacity(0.12), lineWidth: 1)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasZoomControls)
  }
}

struct PolicyCanvasInspector: View {
  let viewModel: PolicyCanvasViewModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        header
        selectionDetails
        canvasMetrics
      }
      .padding(16)
    }
    .background(Color(red: 0.08, green: 0.09, blue: 0.12))
    .overlay(alignment: .leading) {
      Rectangle()
        .fill(.white.opacity(0.08))
        .frame(width: 1)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasInspector)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text("Inspector")
        .font(.headline.weight(.semibold))
        .foregroundStyle(.white)

      Text(viewModel.lastActionSummary)
        .font(.caption)
        .foregroundStyle(.white.opacity(0.62))
        .lineLimit(1)
    }
  }

  @ViewBuilder private var selectionDetails: some View {
    if let node = viewModel.selectedNode {
      PolicyCanvasInspectorSection(title: "Node") {
        PolicyCanvasInspectorRow(label: "Name", value: node.title)
        PolicyCanvasInspectorRow(label: "Kind", value: node.kind.title)
        PolicyCanvasInspectorRow(
          label: "Position",
          value: "\(Int(node.position.x)), \(Int(node.position.y))"
        )
        PolicyCanvasInspectorRow(
          label: "Group",
          value: node.groupID.flatMap { viewModel.group($0)?.title } ?? "None"
        )
      }
    } else if let group = viewModel.selectedGroup {
      PolicyCanvasInspectorSection(title: "Group") {
        PolicyCanvasInspectorRow(label: "Name", value: group.title)
        PolicyCanvasInspectorRow(label: "Nodes", value: "\(viewModel.nodes(in: group.id).count)")
        PolicyCanvasInspectorRow(
          label: "Frame",
          value: "\(Int(group.frame.width)) x \(Int(group.frame.height))"
        )
      }
    } else if let edge = viewModel.selectedEdge {
      PolicyCanvasInspectorSection(title: "Edge") {
        PolicyCanvasInspectorRow(label: "Label", value: edge.label)
        PolicyCanvasInspectorRow(label: "Source", value: edge.source.nodeID)
        PolicyCanvasInspectorRow(label: "Target", value: edge.target.nodeID)
      }
    } else {
      PolicyCanvasInspectorSection(title: "Canvas") {
        PolicyCanvasInspectorRow(label: "Selection", value: "None")
        PolicyCanvasInspectorRow(label: "Mode", value: viewModel.selectedTab.title)
      }
    }
  }

  private var canvasMetrics: some View {
    PolicyCanvasInspectorSection(title: "Policy") {
      PolicyCanvasInspectorRow(label: "Summary", value: viewModel.policySummary)
      PolicyCanvasInspectorRow(
        label: "Zoom",
        value: "\(Int((viewModel.zoom * 100).rounded()))%"
      )
      PolicyCanvasInspectorRow(
        label: "Promote",
        value: viewModel.promoteDisabledReason ?? "Ready"
      )
      if let validation = viewModel.latestSimulation?.validation {
        PolicyCanvasInspectorRow(
          label: "Validation",
          value: validation.issues.first?.code ?? "OK"
        )
      }
    }
  }
}

private struct PolicyCanvasInspectorSection<Content: View>: View {
  let title: String
  let content: Content

  init(title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title)
        .font(.caption.weight(.bold))
        .foregroundStyle(.white.opacity(0.54))
        .textCase(.uppercase)

      VStack(alignment: .leading, spacing: 8) {
        content
      }
      .padding(10)
      .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .stroke(.white.opacity(0.08), lineWidth: 1)
      }
    }
  }
}

private struct PolicyCanvasInspectorRow: View {
  let label: String
  let value: String

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text(label)
        .font(.caption)
        .foregroundStyle(.white.opacity(0.48))
        .frame(width: 68, alignment: .leading)

      Text(value)
        .font(.caption.weight(.medium))
        .foregroundStyle(.white.opacity(0.86))
        .lineLimit(2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}
