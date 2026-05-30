import AppKit
import HarnessMonitorKit
import SwiftUI

struct DashboardPolicyCanvasFooterBar: View {
  @ScaledMetric(relativeTo: .callout)
  private var footerBarHeight = 44.0

  let workspace: TaskBoardPolicyCanvasWorkspace?
  let selectedCanvasId: String?
  let policyCanvasViewModel: PolicyCanvasViewModel
  let automationPolicyCenter: AutomationPolicyCenter
  let isCanvasMutationDisabled: Bool
  @Binding var isAutomationPolicySheetPresented: Bool
  let createCanvas: @MainActor () -> Void
  let selectCanvas: @MainActor (TaskBoardPolicyCanvasSummary) -> Void
  let duplicateCanvasFromTab: @MainActor (TaskBoardPolicyCanvasSummary) -> Void
  let renameCanvasFromTab: @MainActor (TaskBoardPolicyCanvasSummary) -> Void
  let deleteCanvasFromTab: @MainActor (TaskBoardPolicyCanvasSummary) -> Void

  var body: some View {
    VStack(spacing: 0) {
      Divider()

      HStack(spacing: 0) {
        tabStrip
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

        DashboardPolicyCanvasFooterToolsMenuButton(
          viewModel: policyCanvasViewModel,
          automationPolicyCenter: automationPolicyCenter,
          isAutomationPolicySheetPresented: $isAutomationPolicySheetPresented
        )
      }
      .padding(.leading, HarnessMonitorTheme.spacingMD)
      .frame(height: footerBarHeight)
    }
    .background(.background)
    .accessibilityElement(children: .contain)
  }

  @ViewBuilder private var tabStrip: some View {
    if let workspace {
      if workspace.canvases.isEmpty {
        footerStatusStrip("No canvases", systemImage: "square.dashed")
      } else {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 0) {
            ForEach(
              Array(workspace.canvases.enumerated()),
              id: \.element.canvasId
            ) { index, canvas in
              DashboardPolicyCanvasFooterTab(
                canvas: canvas,
                isSelected: canvas.canvasId == (selectedCanvasId ?? workspace.activeCanvasId),
                isActive: canvas.canvasId == workspace.activeCanvasId,
                showsLeadingSeparator: index > 0,
                select: { selectCanvas(canvas) }
              )
              .contextMenu {
                Button("Duplicate") {
                  duplicateCanvasFromTab(canvas)
                }
                .disabled(isCanvasMutationDisabled)

                Button("Rename") {
                  renameCanvasFromTab(canvas)
                }
                .disabled(isCanvasMutationDisabled)

                Divider()

                Button("Delete", role: .destructive) {
                  deleteCanvasFromTab(canvas)
                }
                .disabled(isCanvasMutationDisabled)
              }
            }

            createCanvasTab
          }
        }
        .frame(maxHeight: .infinity, alignment: .leading)
        .scrollIndicators(.hidden)
        .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardPolicyCanvasFooterTabs)
      }
    } else {
      Spacer(minLength: 0)
    }
  }

  private var createCanvasTab: some View {
    DashboardPolicyCanvasFooterCreateTab(
      isDisabled: isCanvasMutationDisabled,
      createCanvas: createCanvas
    )
  }

  private func footerStatusStrip(_ title: String, systemImage: String) -> some View {
    HStack(spacing: 0) {
      footerStatusLabel(title, systemImage: systemImage)
      createCanvasTab
    }
  }

  private func footerStatusLabel(_ title: String, systemImage: String) -> some View {
    Label(title, systemImage: systemImage)
      .scaledFont(.callout.weight(.medium))
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
  }
}

private struct DashboardPolicyCanvasFooterToolsMenuButton: View {
  @ScaledMetric(relativeTo: .callout)
  private var buttonHorizontalPadding = 14.0
  @ScaledMetric(relativeTo: .callout)
  private var buttonMinWidth = 44.0

  let viewModel: PolicyCanvasViewModel
  let automationPolicyCenter: AutomationPolicyCenter
  @Binding var isAutomationPolicySheetPresented: Bool

  @Environment(\.fontScale)
  private var fontScale
  @State private var isHovering = false

  var body: some View {
    Menu {
      PolicyCanvasToolsMenuContent(
        viewModel: viewModel,
        automationPolicyCenter: automationPolicyCenter,
        isAutomationPolicySheetPresented: $isAutomationPolicySheetPresented
      )
    } label: {
      Image(systemName: "gearshape")
        .font(.callout.weight(.medium))
        .padding(.horizontal, buttonHorizontalPadding)
        .frame(minWidth: buttonMinWidth)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
    }
    .buttonStyle(
      DashboardPolicyCanvasFooterTabButtonStyle(
        isSelected: false,
        isHovering: isHovering,
        showsLeadingSeparator: true,
        showsTrailingSeparator: false
      )
    )
    .menuStyle(.button)
    .menuIndicator(.hidden)
    .frame(maxHeight: .infinity)
    .foregroundStyle(.primary)
    .help("Policy tools")
    .accessibilityLabel("Policy tools")
    .accessibilityHint("Open policy tools")
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasToolsButton)
    .environment(
      \.harnessNativeFormControlFont,
      HarnessMonitorTextSize.scaledFont(.callout.weight(.semibold), by: fontScale)
    )
    .environment(\.harnessNativeFormControlSize, .small)
    .harnessNativeFormControl()
    .onHover { hovering in
      updateHoverState(hovering)
    }
    .onDisappear {
      guard isHovering else { return }
      NSCursor.pop()
      isHovering = false
    }
  }

  private func updateHoverState(_ hovering: Bool) {
    guard isHovering != hovering else { return }
    isHovering = hovering
    if hovering {
      NSCursor.pointingHand.push()
    } else {
      NSCursor.pop()
    }
  }
}

private struct DashboardPolicyCanvasFooterCreateTab: View {
  @ScaledMetric(relativeTo: .callout)
  private var tabHorizontalPadding = 14.0
  @ScaledMetric(relativeTo: .callout)
  private var tabMinWidth = 44.0

  let isDisabled: Bool
  let createCanvas: @MainActor () -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: createCanvas) {
      Image(systemName: "plus")
        .font(.callout.weight(.medium))
        .padding(.horizontal, tabHorizontalPadding)
        .frame(minWidth: tabMinWidth)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
    }
    .buttonStyle(
      DashboardPolicyCanvasFooterTabButtonStyle(
        isSelected: false,
        isHovering: isHovering,
        showsTrailingSeparator: false
      )
    )
    .frame(maxHeight: .infinity)
    .foregroundStyle(.primary)
    .disabled(isDisabled)
    .help("Create a new policy canvas")
    .accessibilityLabel("New Canvas")
    .accessibilityHint("Create a new policy canvas")
    .onHover { hovering in
      updateHoverState(hovering && !isDisabled)
    }
    .onChange(of: isDisabled) { _, disabled in
      guard disabled else { return }
      updateHoverState(false)
    }
    .onDisappear {
      guard isHovering else { return }
      NSCursor.pop()
      isHovering = false
    }
  }

  private func updateHoverState(_ hovering: Bool) {
    guard isHovering != hovering else { return }
    isHovering = hovering
    if hovering {
      NSCursor.pointingHand.push()
    } else {
      NSCursor.pop()
    }
  }
}

private struct DashboardPolicyCanvasFooterTab: View {
  @ScaledMetric(relativeTo: .callout)
  private var tabHorizontalPadding = 14.0
  @ScaledMetric(relativeTo: .callout)
  private var tabMaxWidth = 220.0

  let canvas: TaskBoardPolicyCanvasSummary
  let isSelected: Bool
  let isActive: Bool
  let showsLeadingSeparator: Bool
  let select: @MainActor () -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: select) {
      Text(canvas.title)
        .font(.callout.weight(.medium))
        .lineLimit(1)
        .truncationMode(.tail)
        .padding(.horizontal, tabHorizontalPadding)
        .frame(maxWidth: tabMaxWidth, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
    .buttonStyle(
      DashboardPolicyCanvasFooterTabButtonStyle(
        isSelected: isSelected,
        isHovering: isHovering,
        showsLeadingSeparator: showsLeadingSeparator && isSelected
      )
    )
    .frame(maxHeight: .infinity)
    .foregroundStyle(.primary)
    .help(helpText)
    .accessibilityLabel(canvas.title)
    .accessibilityValue(accessibilityValue)
    .onHover { hovering in
      updateHoverState(hovering)
    }
    .onDisappear {
      guard isHovering else { return }
      NSCursor.pop()
      isHovering = false
    }
  }

  private var helpText: String {
    "\(canvas.title) - \(metadataText)"
  }

  private var accessibilityValue: String {
    var parts: [String] = []
    if isActive {
      parts.append("Active")
    }
    if isSelected {
      parts.append("Selected")
    }
    parts.append(metadataText)
    return parts.joined(separator: ", ")
  }

  private var metadataText: String {
    var parts = [
      "revision \(canvas.revision)",
      "\(canvas.nodeCount) nodes",
      "\(canvas.groupCount) groups",
    ]
    if let latestSimulationSucceeded = canvas.latestSimulationSucceeded {
      if latestSimulationSucceeded {
        parts.append("latest simulation passed")
      } else {
        parts.append("latest simulation found issues")
      }
    }
    return parts.joined(separator: ", ")
  }

  private func updateHoverState(_ hovering: Bool) {
    guard isHovering != hovering else { return }
    isHovering = hovering
    if hovering {
      NSCursor.pointingHand.push()
    } else {
      NSCursor.pop()
    }
  }
}

private struct DashboardPolicyCanvasFooterTabButtonStyle: ButtonStyle {
  let isSelected: Bool
  let isHovering: Bool
  var showsLeadingSeparator = false
  var showsTrailingSeparator = true

  @Environment(\.colorSchemeContrast)
  private var colorSchemeContrast
  @Environment(\.isEnabled)
  private var isEnabled

  private var borderWidth: CGFloat {
    colorSchemeContrast == .increased ? 2 : 1
  }

  private func selectedChromeColor(isPressed: Bool) -> Color {
    guard isEnabled else {
      return .clear
    }
    return Color.accentColor.opacity(isPressed ? 0.22 : (isHovering ? 0.18 : 0.14))
  }

  private func separatorColor(isPressed: Bool) -> Color {
    guard isEnabled else {
      return HarnessMonitorTheme.controlBorder.opacity(
        colorSchemeContrast == .increased ? 0.48 : 0.32
      )
    }
    if isSelected {
      return selectedChromeColor(isPressed: isPressed)
    }
    return HarnessMonitorTheme.controlBorder.opacity(
      colorSchemeContrast == .increased ? 0.96 : 0.76
    )
  }

  private func backgroundColor(isPressed: Bool) -> Color {
    guard isEnabled else {
      return .clear
    }
    if isSelected {
      return selectedChromeColor(isPressed: isPressed)
    }
    if isHovering {
      return HarnessMonitorTheme.secondaryInk.opacity(isPressed ? 0.12 : 0.08)
    }
    if isPressed {
      return HarnessMonitorTheme.secondaryInk.opacity(0.06)
    }
    return .clear
  }

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .frame(maxHeight: .infinity, alignment: .leading)
      .background {
        Rectangle()
          .fill(backgroundColor(isPressed: configuration.isPressed))
      }
      .overlay(alignment: .leading) {
        Rectangle()
          .fill(selectedChromeColor(isPressed: configuration.isPressed))
          .frame(width: showsLeadingSeparator ? borderWidth : 0)
          .opacity(showsLeadingSeparator ? 1 : 0)
      }
      .overlay(alignment: .trailing) {
        Rectangle()
          .fill(separatorColor(isPressed: configuration.isPressed))
          .frame(width: showsTrailingSeparator ? borderWidth : 0)
          .opacity(showsTrailingSeparator ? 1 : 0)
      }
      .contentShape(Rectangle())
      .opacity(isEnabled ? (configuration.isPressed ? 0.97 : 1) : 0.56)
  }
}
