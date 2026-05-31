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
  let editingCanvasId: String?
  @Binding var isAutomationPolicySheetPresented: Bool
  let createCanvas: @MainActor () -> Void
  let selectCanvas: @MainActor (TaskBoardPolicyCanvasSummary) -> Void
  let duplicateCanvasFromTab: @MainActor (TaskBoardPolicyCanvasSummary) -> Void
  let renameCanvasFromTab: @MainActor (TaskBoardPolicyCanvasSummary) -> Void
  let submitRenameCanvasFromTab: @MainActor (TaskBoardPolicyCanvasSummary, String) -> Void
  let cancelRenameCanvasFromTab: @MainActor () -> Void
  let deleteCanvasFromTab: @MainActor (TaskBoardPolicyCanvasSummary) -> Void
  let onExport: (@MainActor () -> Void)?
  let onImport: (@MainActor () -> Void)?

  var body: some View {
    VStack(spacing: 0) {
      Divider()

      HStack(spacing: 0) {
        tabStrip
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

        DashboardPolicyCanvasFooterToolsMenuButton(
          workspace: workspace,
          viewModel: policyCanvasViewModel,
          automationPolicyCenter: automationPolicyCenter,
          isAutomationPolicySheetPresented: $isAutomationPolicySheetPresented,
          onExport: onExport,
          onImport: onImport
        )
      }
      .padding(.leading, HarnessMonitorTheme.spacingMD)
      .frame(height: footerBarHeight)
    }
    .background(.background)
    .accessibilityElement(children: .contain)
    .onChange(of: isCanvasMutationDisabled) { _, disabled in
      if disabled, editingCanvasId != nil {
        cancelRenameCanvasFromTab()
      }
    }
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
                isEditing: canvas.canvasId == editingCanvasId,
                canRename: !isCanvasMutationDisabled,
                showsLeadingSeparator: index > 0,
                select: { selectCanvas(canvas) },
                beginRename: { renameCanvasFromTab(canvas) },
                submitRename: { submitRenameCanvasFromTab(canvas, $0) },
                cancelRename: cancelRenameCanvasFromTab
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

  let workspace: TaskBoardPolicyCanvasWorkspace?
  let viewModel: PolicyCanvasViewModel
  let automationPolicyCenter: AutomationPolicyCenter
  @Binding var isAutomationPolicySheetPresented: Bool
  let onExport: (@MainActor () -> Void)?
  let onImport: (@MainActor () -> Void)?

  @Environment(\.fontScale)
  private var fontScale
  @State private var isHovering = false

  var body: some View {
    Menu {
      PolicyCanvasToolsMenuContent(
        workspace: workspace,
        viewModel: viewModel,
        automationPolicyCenter: automationPolicyCenter,
        isAutomationPolicySheetPresented: $isAutomationPolicySheetPresented,
        onExport: onExport,
        onImport: onImport
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
      isHovering = hovering
    }
    .onDisappear {
      isHovering = false
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
      isHovering = hovering && !isDisabled
    }
    .onChange(of: isDisabled) { _, disabled in
      guard disabled else { return }
      isHovering = false
    }
    .onDisappear {
      isHovering = false
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
  let isEditing: Bool
  let canRename: Bool
  let showsLeadingSeparator: Bool
  let select: @MainActor () -> Void
  let beginRename: @MainActor () -> Void
  let submitRename: @MainActor (String) -> Void
  let cancelRename: @MainActor () -> Void

  @State private var isHovering = false

  var body: some View {
    tabContent
      .frame(maxHeight: .infinity)
      .foregroundStyle(.primary)
      .help(helpText)
      .onHover { hovering in
        isHovering = hovering && !isEditing
      }
      .onChange(of: isEditing) { _, editing in
        if editing {
          isHovering = false
        }
      }
      .onDisappear {
        isHovering = false
      }
  }

  @ViewBuilder private var tabContent: some View {
    if isEditing {
      DashboardPolicyCanvasFooterTabTitleEditor(
        title: canvas.title,
        maxWidth: tabMaxWidth,
        horizontalPadding: tabHorizontalPadding,
        accessibilityIdentifier: HarnessMonitorAccessibility.dashboardPolicyCanvasFooterRenameField(
          canvas.canvasId
        ),
        submit: submitRename,
        cancel: cancelRename
      )
      .dashboardPolicyCanvasFooterTabChrome(
        isSelected: isSelected,
        isHovering: false,
        isPressed: false,
        showsLeadingSeparator: showsLeadingSeparator && isSelected
      )
    } else {
      titleButton
    }
  }

  private var titleButton: some View {
    Text(canvas.title)
      .font(.callout.weight(.medium))
      .lineLimit(1)
      .truncationMode(.tail)
      .padding(.horizontal, tabHorizontalPadding)
      .frame(maxWidth: tabMaxWidth, alignment: .leading)
      .frame(maxHeight: .infinity, alignment: .leading)
      .contentShape(Rectangle())
      .dashboardPolicyCanvasFooterTabChrome(
        isSelected: isSelected,
        isHovering: isHovering,
        isPressed: false,
        showsLeadingSeparator: showsLeadingSeparator && isSelected
      )
      .overlay {
        DashboardPolicyCanvasFooterTabClickTarget(
          onHover: { hovering in
            isHovering = hovering
          },
          singleClick: select,
          doubleClick: {
            guard canRename else { return }
            beginRename()
          }
        )
        .accessibilityHidden(true)
      }
      .accessibilityLabel(canvas.title)
      .accessibilityValue(accessibilityValue)
      .accessibilityAddTraits(.isButton)
      .accessibilityAction {
        select()
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

}

private struct DashboardPolicyCanvasFooterTabButtonStyle: ButtonStyle {
  let isSelected: Bool
  let isHovering: Bool
  var showsLeadingSeparator = false
  var showsTrailingSeparator = true

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .dashboardPolicyCanvasFooterTabChrome(
        isSelected: isSelected,
        isHovering: isHovering,
        isPressed: configuration.isPressed,
        showsLeadingSeparator: showsLeadingSeparator,
        showsTrailingSeparator: showsTrailingSeparator
      )
  }
}
